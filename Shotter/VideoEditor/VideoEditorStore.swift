import AVFoundation
import Combine
import CoreImage

/// 動画エディタ 1 つ分の状態。
///
/// 注釈そのもの（描く・選ぶ・動かす・アンドゥ）は静止画と同じ `AnnotationStore` に任せ、
/// ここでは再生位置・注釈ごとの表示時間・トリム・書き出しを受け持つ。
/// 再生位置が表示時間の外にある注釈は `hiddenAnnotationIDs` に入れて、キャンバスから隠す。
@MainActor
final class VideoEditorStore: ObservableObject {

    /// 新しく描いた注釈を表示する長さの初期値（秒）。
    static let defaultAnnotationDuration: Double = 5
    /// 表示時間・トリムの最短の長さ（秒）。
    static let minimumRangeDuration: Double = 0.1
    /// ← / → で動く秒数。
    static let skipInterval: Double = 3
    /// 選べる再生速度。0.25 倍きざみで 3 倍まで。
    static let playbackRates: [Float] = stride(from: 0.25, through: 3.0, by: 0.25).map { Float($0) }

    /// 「0.25 倍」「1.5 倍」「2.0 倍」のように、要るぶんの桁だけで書く。
    static func rateLabel(_ rate: Float) -> String {
        let needsTwoDigits = (rate * 4).truncatingRemainder(dividingBy: 2) != 0
        return String(format: needsTwoDigits ? "%.2f 倍" : "%.1f 倍", rate)
    }

    let videoURL: URL
    let annotationStore: AnnotationStore
    let player: AVPlayer
    let duration: Double
    let pixelSize: CGSize
    let frameRate: Double

    @Published private(set) var currentTime: Double = 0
    @Published private(set) var isPlaying = false

    /// 再生速度。再生中に変えたらその場で反映する。
    @Published var playbackRate: Float = 1 {
        didSet {
            guard playbackRate != oldValue else { return }
            player.defaultRate = playbackRate
            if isPlaying || player.rate != 0 { player.rate = playbackRate }
        }
    }
    @Published private(set) var ranges: [UUID: AnnotationTimeRange] = [:]
    @Published private(set) var trimStart: Double
    @Published private(set) var trimEnd: Double

    /// 書き出しの進み具合（0〜1）。書き出していないときは nil。
    @Published private(set) var exportProgress: Double?

    private let asset: AVURLAsset
    private let videoOutput: AVPlayerItemVideoOutput
    private let imageGenerator: AVAssetImageGenerator
    private let ciContext = CIContext()
    private var timeObserver: Any?
    private var cancellables: Set<AnyCancellable> = []
    private var frameRequest: Task<Void, Never>?
    private var saveWorkItem: DispatchWorkItem?
    private var thumbnailWorkItem: DispatchWorkItem?
    private var exporter: VideoExporter?

    // MARK: - 読み込み

    /// 動画を開いて、エディタに必要な情報（長さ・大きさ・最初のコマ）を揃える。
    static func load(url: URL) async throws -> VideoEditorStore {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoEditorError.noVideoTrack
        }
        let naturalSize = try await track.load(.naturalSize)
        let frameRate = Double(try await track.load(.nominalFrameRate))

        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let firstFrame = try await generator.image(at: .zero).image

        let info = HistoryStore.shared.recordingInfo(for: url)
        return VideoEditorStore(
            url: url,
            asset: asset,
            generator: generator,
            duration: duration,
            pixelSize: naturalSize,
            frameRate: frameRate > 0 ? frameRate : 30,
            firstFrame: firstFrame,
            pointScale: CGFloat(info?.pointScale ?? 1),
            document: HistoryStore.shared.loadVideoDocument(for: url)
        )
    }

    private init(
        url: URL,
        asset: AVURLAsset,
        generator: AVAssetImageGenerator,
        duration: Double,
        pixelSize: CGSize,
        frameRate: Double,
        firstFrame: CGImage,
        pointScale: CGFloat,
        document: VideoDocument?
    ) {
        self.videoURL = url
        self.asset = asset
        self.imageGenerator = generator
        self.duration = duration
        self.pixelSize = pixelSize
        self.frameRate = frameRate
        self.trimStart = document?.trimStart ?? 0
        self.trimEnd = min(document?.trimEnd ?? duration, duration)

        let pointSize = CGSize(width: pixelSize.width / pointScale, height: pixelSize.height / pointScale)
        annotationStore = AnnotationStore(
            image: firstFrame,
            pointSize: pointSize,
            document: document.map {
                AnnotationDocument(
                    annotations: $0.annotations.map(\.annotation),
                    hasShadow: false,
                    shadowStrength: 1,
                    hasRoundedCorners: false,
                    cornerRoundness: 0,
                    counterStartNumber: $0.counterStartNumber
                )
            }
        )

        let item = AVPlayerItem(asset: asset)
        videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        item.add(videoOutput)
        player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause

        // 影や角丸は静止画の書き出し向けの見た目なので、動画では使わない。
        annotationStore.hasShadow = false
        annotationStore.hasRoundedCorners = false

        for timed in document?.annotations ?? [] {
            ranges[timed.annotation.id] = timed.range
        }

        observe()
        updateVisibility()
    }

    /// アンドゥで一緒に戻す、タイムライン側の状態。
    private struct TimelineUndoState {
        var ranges: [UUID: AnnotationTimeRange]
        var trimStart: Double
        var trimEnd: Double
    }

    /// タイムラインのバーやトリムをドラッグしている間か。ドラッグ 1 回でアンドゥ 1 手にまとめる。
    private var isDraggingTimeline = false
    private var didRecordUndoForDrag = false

    private func observe() {
        // 表示時間とトリムを、注釈と同じアンドゥ履歴に載せる。
        annotationStore.captureExtraUndoState = { [weak self] in
            guard let self else { return () }
            return TimelineUndoState(ranges: self.ranges, trimStart: self.trimStart, trimEnd: self.trimEnd)
        }
        annotationStore.restoreExtraUndoState = { [weak self] value in
            guard let self, let state = value as? TimelineUndoState else { return }
            self.ranges = state.ranges
            self.trimStart = state.trimStart
            self.trimEnd = state.trimEnd
            self.updateVisibility()
            self.scheduleSave()
        }

        let interval = CMTime(value: 1, timescale: 30)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.playerDidTick(time.seconds) }
        }

        player.publisher(for: \.timeControlStatus)
            .receive(on: RunLoop.main)
            .sink { [weak self] status in self?.isPlaying = status != .paused }
            .store(in: &cancellables)

        // 描いた注釈には、描いた時点から表示時間を割り当てる。
        annotationStore.$annotations
            .sink { [weak self] annotations in
                DispatchQueue.main.async { self?.assignRanges(to: annotations) }
            }
            .store(in: &cancellables)

        // 動かしたり色を変えたりしたら、履歴へ書き戻す。
        annotationStore.$revision
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleSave() }
            .store(in: &cancellables)
    }

    /// ウィンドウを閉じるときに呼ぶ。
    func tearDown() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        frameRequest?.cancel()
        exporter?.cancel()
        flushSave()
        if thumbnailWorkItem != nil {
            thumbnailWorkItem?.cancel()
            thumbnailWorkItem = nil
            updateHistoryThumbnail()
        }
    }

    // MARK: - 再生

    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        // 終わりまで来ていたら、トリムの頭から再生し直す。
        if currentTime >= trimEnd - 0.05 || currentTime < trimStart {
            seek(to: trimStart)
        }
        player.play()
    }

    func pause() {
        // isPlaying は少し遅れて追従するので、プレイヤー自身の状態も見る。
        guard isPlaying || player.rate != 0 else { return }
        player.pause()
        seek(to: player.currentTime().seconds)
    }

    func seek(to time: Double) {
        let clamped = min(max(time, 0), duration)
        currentTime = clamped
        updateVisibility()

        let target = CMTime(seconds: clamped, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard finished else { return }
            DispatchQueue.main.async { self?.loadFrameForEditing() }
        }
    }

    /// コマ送り。止めてから動かす。
    func step(frames: Int) {
        if isPlaying { player.pause() }
        seek(to: currentTime + Double(frames) / frameRate)
    }

    /// 秒単位で前後へ飛ぶ。再生中なら再生したまま飛ぶ。
    func skip(seconds: Double) {
        let base = isPlaying ? player.currentTime().seconds : currentTime
        seek(to: base + seconds)
    }

    private func playerDidTick(_ time: Double) {
        guard isPlaying else { return }
        currentTime = time
        updateVisibility()

        if time >= trimEnd {
            player.pause()
            seek(to: trimEnd)
            return
        }

        // モザイクは下地のコマが要るので、表示中のものがあるときだけ毎コマ取り出す。
        if annotationStore.visibleAnnotations.contains(where: { $0 is PixelateAnnotation }) {
            pullFrameFromPlayer()
        }
    }

    /// 止まっているときのコマを正確に取り出して、注釈の下地にする（モザイクのプレビューに使う）。
    private func loadFrameForEditing() {
        frameRequest?.cancel()
        let time = CMTime(seconds: currentTime, preferredTimescale: 600)
        frameRequest = Task { [weak self, imageGenerator] in
            guard let image = try? await imageGenerator.image(at: time).image, !Task.isCancelled else { return }
            self?.annotationStore.replaceSourceImage(image)
        }
    }

    private func pullFrameFromPlayer() {
        let itemTime = videoOutput.itemTime(forHostTime: CACurrentMediaTime())
        guard videoOutput.hasNewPixelBuffer(forItemTime: itemTime),
              let buffer = videoOutput.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil)
        else { return }

        let image = CIImage(cvPixelBuffer: buffer)
        if let cgImage = ciContext.createCGImage(image, from: image.extent) {
            annotationStore.replaceSourceImage(cgImage)
        }
    }

    // MARK: - 表示時間

    /// 注釈の表示時間。まだ割り当てていなければ nil。
    func range(for id: UUID) -> AnnotationTimeRange? {
        ranges[id]
    }

    /// その時刻に表示するか。最後まで表示する注釈は、動画の最後のコマでも見えるようにする。
    func isVisible(_ range: AnnotationTimeRange, at time: Double) -> Bool {
        range.contains(time) || (range.end >= duration && time >= duration && range.start <= time)
    }

    func setRange(_ id: UUID, start: Double, end: Double) {
        var start = min(max(start, 0), duration)
        var end = min(max(end, 0), duration)
        if end - start < Self.minimumRangeDuration {
            // どちらを動かしたかに関わらず、最短の長さは確保する。
            if let current = ranges[id], current.start != start {
                start = max(0, end - Self.minimumRangeDuration)
            } else {
                end = min(duration, start + Self.minimumRangeDuration)
            }
        }
        let newRange = AnnotationTimeRange(start: start, end: end)
        guard ranges[id] != newRange else { return }
        recordTimelineUndo()
        ranges[id] = newRange
        updateVisibility()
        scheduleSave()
    }

    /// タイムラインでバーやトリムのつまみを掴んだとき・離したとき。
    func beginTimelineDrag() {
        isDraggingTimeline = true
        didRecordUndoForDrag = false
    }

    func endTimelineDrag() {
        isDraggingTimeline = false
    }

    /// 変える直前の状態をアンドゥ履歴に積む。ドラッグ中は最初の 1 回だけ。
    private func recordTimelineUndo() {
        if isDraggingTimeline {
            guard !didRecordUndoForDrag else { return }
            didRecordUndoForDrag = true
        }
        annotationStore.beginMutation()
    }

    /// 長さを変えずに位置だけずらす。
    func moveRange(_ id: UUID, toStart start: Double) {
        guard let range = ranges[id] else { return }
        let clampedStart = min(max(start, 0), duration - range.duration)
        setRange(id, start: clampedStart, end: clampedStart + range.duration)
    }

    func setStartToCurrentTime(_ id: UUID) {
        guard let range = ranges[id] else { return }
        setRange(id, start: currentTime, end: max(range.end, currentTime + Self.minimumRangeDuration))
    }

    func setEndToCurrentTime(_ id: UUID) {
        guard let range = ranges[id] else { return }
        setRange(id, start: min(range.start, currentTime - Self.minimumRangeDuration), end: currentTime)
    }

    /// タイムラインで注釈を選んだとき。見えていない時刻なら、表示が始まる位置へ移る。
    func selectFromTimeline(_ id: UUID) {
        guard let annotation = annotationStore.annotations.first(where: { $0.id == id }) else { return }
        if isPlaying { player.pause() }
        if let range = ranges[id], !isVisible(range, at: currentTime) {
            seek(to: range.start)
        }
        annotationStore.tool = .select
        annotationStore.select(annotation)
    }

    private func assignRanges(to annotations: [Annotation]) {
        var changed = false
        for annotation in annotations where ranges[annotation.id] == nil {
            var start = currentTime
            // 最後のほうで描いても、すぐ消えてしまわないようにする。
            if duration - start < 1 { start = max(0, duration - Self.defaultAnnotationDuration) }
            ranges[annotation.id] = AnnotationTimeRange(
                start: start,
                end: min(duration, start + Self.defaultAnnotationDuration)
            )
            changed = true
        }
        if changed {
            updateVisibility()
            scheduleSave()
        }
    }

    private func updateVisibility() {
        let hidden = annotationStore.annotations.compactMap { annotation -> UUID? in
            guard let range = ranges[annotation.id] else { return nil }
            return isVisible(range, at: currentTime) ? nil : annotation.id
        }
        annotationStore.hiddenAnnotationIDs = Set(hidden)
    }

    // MARK: - トリム

    func setTrim(start: Double, end: Double) {
        let start = min(max(start, 0), duration - Self.minimumRangeDuration)
        let end = min(max(end, start + Self.minimumRangeDuration), duration)
        guard start != trimStart || end != trimEnd else { return }
        recordTimelineUndo()
        trimStart = start
        trimEnd = end
        scheduleSave()
    }

    var isTrimmed: Bool {
        trimStart > 0.001 || trimEnd < duration - 0.001
    }

    // MARK: - 保存

    var document: VideoDocument {
        VideoDocument(
            annotations: annotationStore.annotations.compactMap { annotation in
                guard let snapshot = AnnotationSnapshot(annotation) else { return nil }
                let range = ranges[annotation.id]
                    ?? AnnotationTimeRange(start: 0, end: min(duration, Self.defaultAnnotationDuration))
                return VideoDocument.TimedAnnotation(annotation: snapshot, range: range)
            },
            trimStart: trimStart,
            trimEnd: trimEnd,
            counterStartNumber: annotationStore.counterStartNumber
        )
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.saveWorkItem = nil
            HistoryStore.shared.saveVideoDocument(self.document, for: self.videoURL)
        }
        saveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
        scheduleThumbnailUpdate()
    }

    // MARK: - 履歴のサムネイル

    /// 注釈を描き換えるたびに作り直すと重いので、手が止まってから作る。
    private func scheduleThumbnailUpdate() {
        thumbnailWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.thumbnailWorkItem = nil
            self?.updateHistoryThumbnail()
        }
        thumbnailWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
    }

    /// 注釈がいちばん多く出ている時刻のコマに注釈を乗せて、履歴のサムネイルにする。
    private func updateHistoryThumbnail() {
        let annotations = annotationStore.annotations.map { $0.copy() }
        guard !annotations.isEmpty, let time = thumbnailTime(for: annotations) else {
            HistoryStore.shared.saveEditedPoster(nil, for: videoURL)
            return
        }

        let visible = annotations.filter { ranges[$0.id].map { isVisible($0, at: time) } ?? false }
        let counterStart = annotationStore.counterStartNumber
        let url = videoURL
        Task { [imageGenerator] in
            guard let frame = try? await imageGenerator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image,
                  let image = VideoFrameRenderer.render(
                    frame: frame,
                    annotations: visible,
                    numberingFrom: annotations,
                    counterStartNumber: counterStart
                  )
            else { return }
            HistoryStore.shared.saveEditedPoster(image, for: url)
        }
    }

    /// 各注釈が出始める瞬間のうち、同時に出ている注釈がいちばん多い時刻（同じなら早いほう）。
    private func thumbnailTime(for annotations: [Annotation]) -> Double? {
        let candidates = annotations.compactMap { ranges[$0.id]?.start }.map { min($0 + 0.05, duration) }.sorted()
        return candidates.max { lhs, rhs in
            let left = annotations.filter { ranges[$0.id].map { isVisible($0, at: lhs) } ?? false }.count
            let right = annotations.filter { ranges[$0.id].map { isVisible($0, at: rhs) } ?? false }.count
            return left < right || (left == right && lhs > rhs)
        }
    }

    func flushSave() {
        guard saveWorkItem != nil else { return }
        saveWorkItem?.cancel()
        saveWorkItem = nil
        HistoryStore.shared.saveVideoDocument(document, for: videoURL)
    }

    // MARK: - 書き出し

    /// 注釈を焼き込んだ動画を書き出す。
    func exportVideo(
        format: VideoExportFormat,
        gifOptions: GIFExportOptions = GIFExportOptions(),
        to outputURL: URL
    ) async throws {
        guard exporter == nil else { return }
        if isPlaying { player.pause() }

        let exporter = VideoExporter(
            job: VideoExporter.Job(
                sourceURL: videoURL,
                outputURL: outputURL,
                format: format,
                annotations: annotationStore.annotations.map { $0.copy() },
                ranges: ranges,
                trimStart: trimStart,
                trimEnd: trimEnd,
                duration: duration,
                counterStartNumber: annotationStore.counterStartNumber,
                gifOptions: gifOptions
            )
        )
        self.exporter = exporter
        exportProgress = 0
        defer {
            self.exporter = nil
            exportProgress = nil
        }

        try await exporter.run { [weak self] progress in
            DispatchQueue.main.async { self?.exportProgress = progress }
        }
    }

    func cancelExport() {
        exporter?.cancel()
    }

    /// 今の再生位置のコマに、表示中の注釈を焼き込んだ静止画。
    func renderStillFrame() async throws -> (frame: CGImage, flattened: CGImage) {
        let frame = try await imageGenerator.image(at: CMTime(seconds: currentTime, preferredTimescale: 600)).image
        let flattened = VideoFrameRenderer.render(
            frame: frame,
            annotations: annotationStore.visibleAnnotations,
            numberingFrom: annotationStore.annotations,
            counterStartNumber: annotationStore.counterStartNumber
        ) ?? frame
        return (frame, flattened)
    }

    /// 静止画エディタで開き直せるよう、表示中の注釈をオブジェクトのまま渡す形にする。
    var visibleAnnotationsDocument: AnnotationDocument {
        AnnotationDocument(
            annotations: annotationStore.visibleAnnotations.compactMap { AnnotationSnapshot($0) },
            hasShadow: false,
            shadowStrength: 1,
            hasRoundedCorners: false,
            cornerRoundness: 0,
            counterStartNumber: annotationStore.counterStartNumber
        )
    }
}

enum VideoEditorError: LocalizedError {
    case noVideoTrack

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "動画の映像が見つかりませんでした。"
        }
    }
}
