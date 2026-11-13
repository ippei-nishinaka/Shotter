import AVFoundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// 書き出し形式。
enum VideoExportFormat: String, CaseIterable, Identifiable {
    case mp4
    case mov
    case gif

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mp4: return "MP4（H.264・どこでも再生できる）"
        case .mov: return "MOV（HEVC・高画質で小さめ）"
        case .gif: return "GIF（アニメーション・音声なし）"
        }
    }

    /// 動画として書き出す場合のコンテナ。GIF は動画ではないので nil。
    var fileType: AVFileType? {
        switch self {
        case .mp4: return .mp4
        case .mov: return .mov
        case .gif: return nil
        }
    }

    var fileExtension: String { rawValue }

    var contentType: UTType {
        switch self {
        case .mp4: return .mpeg4Movie
        case .mov: return .quickTimeMovie
        case .gif: return .gif
        }
    }

    var codec: AVVideoCodecType {
        switch self {
        case .mp4, .gif: return .h264
        case .mov:       return RecordingWriter.supportsHEVC ? .hevc : .h264
        }
    }
}

/// GIF の書き出し設定。
struct GIFExportOptions: Equatable {
    /// 横幅の上限（ピクセル）。0 なら元の大きさのまま。
    var maxWidth: Int = 800
    var framesPerSecond: Int = 15

    static let widthChoices = [480, 640, 800, 1024, 1280, 0]
    static let frameRateChoices = [10, 15, 20, 30]

    static func widthTitle(_ width: Int) -> String {
        width == 0 ? "元の大きさ" : "\(width) px"
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
        var gifOptions = GIFExportOptions()
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
            if job.format == .gif {
                try await makeGIF(progress: progress)
            } else {
                try await transcode(progress: progress)
            }
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

        guard let fileType = job.format.fileType else { throw VideoExportError.failed("動画の形式ではありません") }
        let writer = try AVAssetWriter(outputURL: job.outputURL, fileType: fileType)
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

extension VideoExporter {

    /// 注釈を焼き込んだ GIF アニメーションを書き出す。
    ///
    /// 動画を頭から 1 コマずつ読み、指定した fps の間隔ごとに 1 枚ずつ拾って、縮小してから足していく。
    /// GIF は 1 コマごとに画像を丸ごと持つので、長い範囲や大きな幅だとファイルが大きくなる。
    private func makeGIF(progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: job.sourceURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoEditorError.noVideoTrack
        }
        let size = try await videoTrack.load(.naturalSize)

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: job.trimStart, preferredTimescale: 600),
            end: CMTime(seconds: job.trimEnd, preferredTimescale: 600)
        )
        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw VideoExportError.failed(reader.error?.localizedDescription ?? "読み込みを開始できません")
        }

        let options = job.gifOptions
        let interval = 1 / Double(options.framesPerSecond)
        let total = max(job.trimEnd - job.trimStart, 0.001)
        let frameCount = max(1, Int((total / interval).rounded(.up)))
        let scale = options.maxWidth > 0 ? min(1, CGFloat(options.maxWidth) / size.width) : 1

        guard let destination = CGImageDestinationCreateWithURL(
            job.outputURL as CFURL, UTType.gif.identifier as CFString, frameCount, nil
        ) else {
            throw VideoExportError.failed("GIF ファイルを作れませんでした")
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)

        // 収録は画面が変わらない間はコマを足さないので、1 枚ごとの表示時間は
        // 「次の 1 枚までの時間」にする。そうしないと止まっていた場面だけ早送りになる。
        // GIF の表示時間は 1/100 秒単位でしか持てない（15fps の 0.0667 秒は 0.07 秒になる）。
        // 1 枚ずつ丸めると誤差が積もって遅くなるので、通算の時刻を丸めてから差を取る。
        var pending: (image: CGImage, time: Double)?
        var writtenUntil = 0.0
        func flush(until nextTime: Double) {
            guard let current = pending else { return }
            let end = max(current.time + interval, nextTime) - job.trimStart
            let delay = max(0.02, (end * 100).rounded() / 100 - writtenUntil)
            writtenUntil += delay
            CGImageDestinationAddImage(destination, current.image, [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delay,
                    kCGImagePropertyGIFUnclampedDelayTime: delay,
                ],
            ] as CFDictionary)
        }

        let overlay = AnnotationOverlay(
            annotations: job.annotations,
            ranges: job.ranges,
            duration: job.duration,
            imageSize: size,
            counterStartNumber: job.counterStartNumber
        )
        let context = CIContext()
        var nextTime = job.trimStart
        var added = 0

        while let sample = output.copyNextSampleBuffer() {
            if cancelled {
                reader.cancelReading()
                throw VideoExportError.cancelled
            }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            // 次に拾う時刻に届いていないコマは飛ばす（元が 30fps なら 15fps では 2 コマに 1 枚）。
            guard time + 0.001 >= nextTime, let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }

            overlay.draw(at: time, onto: pixelBuffer)
            let image = CIImage(cvPixelBuffer: pixelBuffer)
                .applyingFilter("CILanczosScaleTransform", parameters: [
                    kCIInputScaleKey: scale,
                    kCIInputAspectRatioKey: 1,
                ])
            guard let frame = context.createCGImage(image, from: image.extent.integral) else { continue }
            flush(until: time)
            pending = (frame, time)
            added += 1

            // 元のコマの間隔が広い（画面に変化がなかった）ところでは、その分だけ時刻を進める。
            while nextTime <= time + 0.001 { nextTime += interval }
            progress(min(1, (time - job.trimStart) / total))
        }

        if reader.status == .failed {
            throw VideoExportError.failed(reader.error?.localizedDescription ?? "読み込みに失敗しました")
        }
        flush(until: job.trimEnd)
        guard added > 0, CGImageDestinationFinalize(destination) else {
            throw VideoExportError.failed("GIF を書き出せませんでした")
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
final class AnnotationOverlay {

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
