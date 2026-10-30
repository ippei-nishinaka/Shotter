import AVFoundation
import CoreGraphics
import UniformTypeIdentifiers

/// 動画の書き出し形式。
enum VideoExportFormat: String, CaseIterable, Identifiable {
    case mp4
    case mov

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mp4: return "MP4（H.264・どこでも再生できる）"
        case .mov: return "MOV（HEVC・高画質で小さめ）"
        }
    }

    var fileType: AVFileType {
        switch self {
        case .mp4: return .mp4
        case .mov: return .mov
        }
    }

    var fileExtension: String { rawValue }

    var contentType: UTType {
        switch self {
        case .mp4: return .mpeg4Movie
        case .mov: return .quickTimeMovie
        }
    }

    var codec: AVVideoCodecType {
        switch self {
        case .mp4: return .h264
        case .mov: return RecordingWriter.supportsHEVC ? .hevc : .h264
        }
    }
}

enum VideoExportError: LocalizedError {
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:           return "書き出しを中止しました。"
        case .failed(let reason):  return "動画を書き出せませんでした: \(reason)"
        }
    }
}

/// 注釈を焼き込んだ動画を書き出す。
///
/// AVAssetReader で 1 コマずつ読み、その時刻に表示する注釈を描いてから AVAssetWriter へ渡す。
/// 注釈が何も無い区間はそのまま通す。音声は（システム音声とマイクの 2 トラックあっても）
/// 1 トラックにミックスする。MP4 では 2 つめ以降の音声トラックを再生しないプレイヤーが多いため。
final class VideoExporter: @unchecked Sendable {

    struct Job {
        var sourceURL: URL
        var outputURL: URL
        var format: VideoExportFormat
        /// 書き出し専用の複製（編集中のものとは別のインスタンス）。
        var annotations: [Annotation]
        var ranges: [UUID: AnnotationTimeRange]
        var trimStart: Double
        var trimEnd: Double
        var duration: Double
        var counterStartNumber: Int
    }

    private let job: Job
    private let lock = NSLock()
    private var isCancelled = false

    init(job: Job) {
        self.job = job
    }

    func cancel() {
        lock.withLock { isCancelled = true }
    }

    private var cancelled: Bool {
        lock.withLock { isCancelled }
    }

    func run(progress: @escaping @Sendable (Double) -> Void) async throws {
        try? FileManager.default.removeItem(at: job.outputURL)

        // 手を加えるところが無ければ、ファイルをそのままコピーするだけで済む。
        if job.format == .mov, !hasVisibleAnnotations, !isTrimmed {
            do {
                try FileManager.default.copyItem(at: job.sourceURL, to: job.outputURL)
                progress(1)
                return
            } catch {
                throw VideoExportError.failed(error.localizedDescription)
            }
        }

        do {
            try await transcode(progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: job.outputURL)
            throw cancelled ? VideoExportError.cancelled : error
        }
    }

    private var isTrimmed: Bool {
        job.trimStart > 0.001 || job.trimEnd < job.duration - 0.001
    }

    /// 書き出す範囲に、表示される注釈が 1 つでもあるか。
    private var hasVisibleAnnotations: Bool {
        job.annotations.contains { annotation in
            guard let range = job.ranges[annotation.id] else { return false }
            return range.end > job.trimStart && range.start < job.trimEnd
        }
    }

    // MARK: - 読み書き

    private func transcode(progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: job.sourceURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoEditorError.noVideoTrack
        }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let size = try await videoTrack.load(.naturalSize)
        let sourceBitRate = Double(try await videoTrack.load(.estimatedDataRate))

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: job.trimStart, preferredTimescale: 600),
            end: CMTime(seconds: job.trimEnd, preferredTimescale: 600)
        )

        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ])
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
            reader.add(output)
            audioOutput = output
        }

        let writer = try AVAssetWriter(outputURL: job.outputURL, fileType: job.format.fileType)
        writer.shouldOptimizeForNetworkUse = job.format == .mp4

        // 元と同じくらいの画質を保つ。H.264 は HEVC より効率が落ちるので多めに割り当てる。
        let factor = job.format.codec == .h264 ? 1.6 : 1.1
        let bitRate = min(max(sourceBitRate * factor, 1_500_000), 40_000_000)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: job.format.codec,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(bitRate),
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 160_000,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
        }

        guard reader.startReading() else {
            throw VideoExportError.failed(reader.error?.localizedDescription ?? "読み込みを開始できません")
        }
        guard writer.startWriting() else {
            throw VideoExportError.failed(writer.error?.localizedDescription ?? "書き込みを開始できません")
        }
        writer.startSession(atSourceTime: reader.timeRange.start)

        let overlay = AnnotationOverlay(
            annotations: job.annotations,
            ranges: job.ranges,
            duration: job.duration,
            imageSize: size,
            counterStartNumber: job.counterStartNumber
        )
        let total = max(job.trimEnd - job.trimStart, 0.001)
        let group = DispatchGroup()

        let video = ExportChannel(input: videoInput, output: videoOutput, overlay: overlay)
        group.enter()
        let videoQueue = DispatchQueue(label: "com.ippei.Shotter.VideoExporter.video")
        var lastReported = -1.0
        videoInput.requestMediaDataWhenReady(on: videoQueue) { [self] in
            while video.input.isReadyForMoreMediaData {
                guard !cancelled, let sample = video.output.copyNextSampleBuffer() else {
                    video.input.markAsFinished()
                    group.leave()
                    return
                }

                let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                if let pixelBuffer = CMSampleBufferGetImageBuffer(sample) {
                    video.overlay?.draw(at: time, onto: pixelBuffer)
                }
                video.input.append(sample)

                let fraction = min(1, max(0, (time - job.trimStart) / total))
                if fraction - lastReported >= 0.005 {
                    lastReported = fraction
                    progress(fraction)
                }
            }
        }

        if let audioInput, let audioOutput {
            let audio = ExportChannel(input: audioInput, output: audioOutput, overlay: nil)
            group.enter()
            let audioQueue = DispatchQueue(label: "com.ippei.Shotter.VideoExporter.audio")
            audioInput.requestMediaDataWhenReady(on: audioQueue) { [self] in
                while audio.input.isReadyForMoreMediaData {
                    guard !cancelled, let sample = audio.output.copyNextSampleBuffer() else {
                        audio.input.markAsFinished()
                        group.leave()
                        return
                    }
                    audio.input.append(sample)
                }
            }
        }

        await withCheckedContinuation { continuation in
            group.notify(queue: .global()) { continuation.resume() }
        }

        if cancelled {
            reader.cancelReading()
            writer.cancelWriting()
            throw VideoExportError.cancelled
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw VideoExportError.failed(reader.error?.localizedDescription ?? "読み込みに失敗しました")
        }

        await writer.finishWriting()
        guard writer.status == .completed else {
            throw VideoExportError.failed(writer.error?.localizedDescription ?? "書き込みに失敗しました")
        }
        progress(1)
    }
}

/// 読み出し口と書き込み口の組。どちらも Sendable ではないが、
/// requestMediaDataWhenReady に渡したキューの上でしか触らないのでまとめて渡す。
private struct ExportChannel: @unchecked Sendable {
    let input: AVAssetWriterInput
    let output: AVAssetReaderOutput
    let overlay: AnnotationOverlay?
}

/// 書き出し中、各コマにその時刻の注釈を描く。
///
/// モザイクを含まない組み合わせは、注釈だけを描いた透明な画像を 1 回作って使い回す。
/// 注釈の組み合わせが変わる瞬間はまれなので、長い動画でもほとんど描き直さずに済む。
private final class AnnotationOverlay {

    private let annotations: [Annotation]
    private let ranges: [UUID: AnnotationTimeRange]
    private let duration: Double
    private let imageSize: CGSize
    private let counterStartNumber: Int
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    private var cachedKey: [UUID] = []
    private var cachedImage: CGImage?
    /// モザイクを含まないときの下地の代わり（使われないが、型の都合で何か渡す必要がある）。
    private lazy var placeholder: CGImage? = {
        CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
    }()

    init(
        annotations: [Annotation],
        ranges: [UUID: AnnotationTimeRange],
        duration: Double,
        imageSize: CGSize,
        counterStartNumber: Int
    ) {
        self.annotations = annotations
        self.ranges = ranges
        self.duration = duration
        self.imageSize = imageSize
        self.counterStartNumber = counterStartNumber
    }

    func draw(at time: Double, onto pixelBuffer: CVPixelBuffer) {
        let visible = annotations.filter { annotation in
            guard let range = ranges[annotation.id] else { return false }
            return range.contains(time) || (range.end >= duration && time >= duration && range.start <= time)
        }
        guard !visible.isEmpty else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }

        context.interpolationQuality = .high
        AnnotationRenderer.flipToTopLeftOrigin(context, height: CGFloat(height))

        if visible.contains(where: { $0 is PixelateAnnotation }) {
            // モザイクはそのコマの中身が要るので、毎コマ描く。
            guard let frame = context.makeImage() else { return }
            AnnotationRenderer.drawAnnotations(
                visible,
                in: context,
                environment: environment(sourceImage: frame),
                numberingFrom: annotations
            )
            return
        }

        let key = visible.map(\.id)
        if key != cachedKey || cachedImage == nil {
            cachedImage = renderOverlay(visible)
            cachedKey = key
        }
        if let cachedImage {
            AnnotationRenderer.drawImage(
                cachedImage,
                in: CGRect(x: 0, y: 0, width: width, height: height),
                context: context
            )
        }
    }

    private func renderOverlay(_ visible: [Annotation]) -> CGImage? {
        guard let placeholder,
              let context = CGContext(
                data: nil,
                width: Int(imageSize.width),
                height: Int(imageSize.height),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        context.interpolationQuality = .high
        AnnotationRenderer.flipToTopLeftOrigin(context, height: imageSize.height)
        AnnotationRenderer.drawAnnotations(
            visible,
            in: context,
            environment: environment(sourceImage: placeholder),
            numberingFrom: annotations
        )
        return context.makeImage()
    }

    private func environment(sourceImage: CGImage) -> AnnotationRenderEnvironment {
        AnnotationRenderEnvironment(
            sourceImage: sourceImage,
            imageSize: imageSize,
            counterStartNumber: counterStartNumber
        )
    }
}

/// 動画の 1 コマに注釈を焼き込んだ静止画を作る。
enum VideoFrameRenderer {

    static func render(
        frame: CGImage,
        annotations: [Annotation],
        numberingFrom allAnnotations: [Annotation],
        counterStartNumber: Int
    ) -> CGImage? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: frame.width,
                height: frame.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        let size = CGSize(width: frame.width, height: frame.height)
        context.interpolationQuality = .high
        context.draw(frame, in: CGRect(origin: .zero, size: size))
        AnnotationRenderer.flipToTopLeftOrigin(context, height: size.height)
        AnnotationRenderer.drawAnnotations(
            annotations,
            in: context,
            environment: AnnotationRenderEnvironment(
                sourceImage: frame,
                imageSize: size,
                counterStartNumber: counterStartNumber
            ),
            numberingFrom: allAnnotations
        )
        return context.makeImage()
    }
}
