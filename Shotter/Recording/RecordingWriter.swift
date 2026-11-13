import AVFoundation
import CoreImage
import CoreMedia

/// 書き込む音声トラックの種類。
enum RecordingAudioTrack {
    case system
    case microphone
}

/// RecordingWriter の設定。
struct RecordingWriterSettings {
    var pixelSize: CGSize
    var quality: RecordingQuality
    var recordsSystemAudio: Bool
    var recordsMicrophone: Bool
    /// 画面収録はリアルタイムに届くので true。合成フレームで検証するときは false にする。
    var isRealTime = true
}

/// 書き終えたファイルの情報。
struct RecordingWriterResult {
    let url: URL
    let duration: TimeInterval
    let pixelSize: CGSize
    /// 最初のフレーム。履歴やサムネイルの見た目に使う。
    let poster: CGImage?
    let videoFrameCount: Int
}

enum RecordingWriterError: LocalizedError {
    case cannotCreateWriter(String)
    case noFrames
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .cannotCreateWriter(let reason): return "収録ファイルを作れませんでした: \(reason)"
        case .noFrames:                       return "映像を 1 フレームも受け取れませんでした。"
        case .writeFailed(let reason):        return "収録ファイルの書き込みに失敗しました: \(reason)"
        }
    }
}

/// 受け取った映像・音声のサンプルを AVAssetWriter で .mov に書き込む。
///
/// - 落ちても途中までは再生できるよう、10 秒ごとにフラグメントとして書き出す。
/// - 映像の最初のフレームの時刻でセッションを始め、それより前の音声は捨てる。
/// - スレッドセーフではない。呼び出しはすべて同じシリアルキューから行うこと。
final class RecordingWriter {

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let systemAudioInput: AVAssetWriterInput?
    private let microphoneInput: AVAssetWriterInput?
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let settings: RecordingWriterSettings

    private var firstVideoTime: CMTime?
    private var lastVideoTime: CMTime = .invalid
    private var frameCount = 0
    private var poster: CGImage?

    /// HEVC のハードウェアエンコーダがあるか。無い Mac では H.264 にする。
    static var supportsHEVC: Bool {
        AVAssetExportSession.allExportPresets().contains(AVAssetExportPresetHEVCHighestQuality)
    }

    init(url: URL, settings: RecordingWriterSettings) throws {
        self.settings = settings

        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        } catch {
            throw RecordingWriterError.cannotCreateWriter(error.localizedDescription)
        }
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
        writer.shouldOptimizeForNetworkUse = false

        let quality = settings.quality
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: Self.supportsHEVC ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: Int(settings.pixelSize.width),
            AVVideoHeightKey: Int(settings.pixelSize.height),
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: quality.videoBitRate,
                AVVideoExpectedSourceFrameRateKey: quality.framesPerSecond,
                // 後でエディタからシークしやすいよう、キーフレームは 2 秒おきに入れる。
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
            ],
        ]
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw RecordingWriterError.cannotCreateWriter("映像の設定が使えません")
        }
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = settings.isRealTime
        writer.add(videoInput)

        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: nil
        )

        if settings.recordsSystemAudio {
            let input = Self.makeAudioInput(channels: 2, bitRate: quality.systemAudioBitRate, realTime: settings.isRealTime)
            writer.add(input)
            systemAudioInput = input
        } else {
            systemAudioInput = nil
        }

        if settings.recordsMicrophone {
            let input = Self.makeAudioInput(channels: 1, bitRate: quality.microphoneBitRate, realTime: settings.isRealTime)
            writer.add(input)
            microphoneInput = input
        } else {
            microphoneInput = nil
        }

        guard writer.startWriting() else {
            throw RecordingWriterError.cannotCreateWriter(writer.error?.localizedDescription ?? "不明なエラー")
        }
    }

    private static func makeAudioInput(channels: Int, bitRate: Int, realTime: Bool) -> AVAssetWriterInput {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: bitRate,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = realTime
        return input
    }

    // MARK: - 書き込み

    /// 画面収録から届いた映像サンプルを書き込む。
    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        appendVideo(pixelBuffer, at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    func appendVideo(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        guard writer.status == .writing, time.isValid else { return }

        if firstVideoTime == nil {
            firstVideoTime = time
            writer.startSession(atSourceTime: time)
            poster = Self.makeImage(from: pixelBuffer)
        }

        // 時刻が戻ったフレームは書けないので捨てる。
        guard !lastVideoTime.isValid || time > lastVideoTime else { return }

        if settings.isRealTime {
            // 追いつかないときは古いフレームを待たずに捨てる（音ズレを防ぐ）。
            guard videoInput.isReadyForMoreMediaData else { return }
        } else {
            while !videoInput.isReadyForMoreMediaData { usleep(1000) }
        }

        if adaptor.append(pixelBuffer, withPresentationTime: time) {
            lastVideoTime = time
            frameCount += 1
        }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer, track: RecordingAudioTrack) {
        guard writer.status == .writing, let firstVideoTime else { return }
        guard CMSampleBufferGetPresentationTimeStamp(sampleBuffer) >= firstVideoTime else { return }

        let input: AVAssetWriterInput?
        switch track {
        case .system:     input = systemAudioInput
        case .microphone: input = microphoneInput
        }
        guard let input, input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }

    /// 書き込みが途中で失敗したか（ディスクがいっぱい、保存先のディスクが外れた、など）。
    var hasFailed: Bool { writer.status == .failed }

    /// 書き込みを終えてファイルを閉じる。
    func finish() async throws -> RecordingWriterResult {
        // 途中で失敗している場合は、閉じる操作をせずにそのまま知らせる
        // （失敗した writer に markAsFinished などを呼ぶと例外で落ちる）。
        // 書けたところまではフラグメントとしてファイルに残っている。
        guard writer.status == .writing else {
            throw RecordingWriterError.writeFailed(writer.error?.localizedDescription ?? "不明なエラー")
        }

        guard let firstVideoTime, frameCount > 0 else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: writer.outputURL)
            throw RecordingWriterError.noFrames
        }

        // 最後のフレームも 1 コマ分は表示されるよう、終了時刻を少し後ろにする。
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(settings.quality.framesPerSecond))
        let endTime = lastVideoTime + frameDuration

        videoInput.markAsFinished()
        systemAudioInput?.markAsFinished()
        microphoneInput?.markAsFinished()
        writer.endSession(atSourceTime: endTime)

        await writer.finishWriting()

        guard writer.status == .completed else {
            throw RecordingWriterError.writeFailed(writer.error?.localizedDescription ?? "不明なエラー")
        }

        return RecordingWriterResult(
            url: writer.outputURL,
            duration: (endTime - firstVideoTime).seconds,
            pixelSize: settings.pixelSize,
            poster: poster,
            videoFrameCount: frameCount
        )
    }

    /// 途中でやめるとき（エラーなど）に書きかけのファイルを消す。
    func cancel() {
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: writer.outputURL)
    }

    private static func makeImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        return CIContext().createCGImage(image, from: image.extent)
    }
}
