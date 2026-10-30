import AppKit
import CoreMedia
import ScreenCaptureKit

/// システム音声をどこまで拾うか。
///
/// ウィンドウ単位のフィルタで収録すると、ScreenCaptureKit はそのウィンドウのアプリの音しか拾わない。
/// 他のアプリの音も入れたい場合は、音声だけを拾うストリームをディスプレイ単位で別に回す。
enum SystemAudioScope: String, CaseIterable, Identifiable {
    /// 収録するウィンドウのアプリの音だけ（既定）。通知音などが混ざらない。
    case application
    /// Mac 全体の音。
    case entireMac

    static let `default` = SystemAudioScope.application

    var id: String { rawValue }

    var title: String {
        switch self {
        case .application: return "このアプリの音だけ"
        case .entireMac:   return "Mac 全体の音"
        }
    }
}

/// 収録の設定。収録前のバーで決めたものを渡す。
struct RecordingOptions {
    var quality: RecordingQuality
    var recordsSystemAudio: Bool
    var systemAudioScope: SystemAudioScope
    var recordsMicrophone: Bool
    var microphoneDeviceID: String?
    var showsCursor: Bool
}

/// 選んだウィンドウ 1 つを ScreenCaptureKit で収録し、RecordingWriter で .mov に書き込む。
///
/// `desktopIndependentWindow` のフィルタはそのウィンドウだけを撮るので、
/// Shotter 自身のパネル（収録前のバーやカウントダウン）や他のウィンドウは写り込まない。
/// ウィンドウを動かしたり別のディスプレイへ移したりしても追いかけ、
/// 大きさを変えた場合も FrameFitter で動画の枠いっぱいに収め直す。
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    /// ウィンドウが閉じられるなどして、こちらが止める前に収録が止まったとき（メインスレッドで呼ぶ）。
    var onUnexpectedStop: ((Error) -> Void)?

    let pixelSize: CGSize

    /// 1 ポイントあたりのピクセル数（収録したウィンドウの大きさ基準）。
    var pointScale: CGFloat {
        window.frame.width > 0 ? pixelSize.width / window.frame.width : 1
    }

    private let window: SCWindow
    private let options: RecordingOptions
    private let sampleQueue = DispatchQueue(label: "com.ippei.Shotter.ScreenRecorder", qos: .userInitiated)
    private let writer: RecordingWriter
    private let fitter: FrameFitter
    private var stream: SCStream?
    /// Mac 全体の音を拾うときだけ使う、音声専用のストリーム。
    private var audioStream: SCStream?
    private var microphone: MicrophoneCapture?
    private var isStopping = false

    /// - Parameter scale: ウィンドウがあるディスプレイの拡大率。
    init(window: SCWindow, scale: CGFloat, options: RecordingOptions, outputURL: URL) throws {
        self.window = window
        self.options = options
        pixelSize = options.quality.outputPixelSize(forPointSize: window.frame.size, scale: scale)
        fitter = FrameFitter(canvasSize: pixelSize)

        writer = try RecordingWriter(
            url: outputURL,
            settings: RecordingWriterSettings(
                pixelSize: pixelSize,
                quality: options.quality,
                recordsSystemAudio: options.recordsSystemAudio,
                recordsMicrophone: options.recordsMicrophone
            )
        )
        super.init()
    }

    func start() async throws {
        let filter = SCContentFilter(desktopIndependentWindow: window)

        let configuration = SCStreamConfiguration()
        configuration.width = Int(pixelSize.width)
        configuration.height = Int(pixelSize.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.quality.framesPerSecond))
        configuration.showsCursor = options.showsCursor
        // エンコーダがそのまま受け取れる YUV で受ける（BGRA よりメモリも帯域も少ない）。
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.queueDepth = 6
        if #available(macOS 14.0, *) {
            // 途中でウィンドウの大きさを変えられても、縦横比を保ったまま描かせる（引き伸ばさせない）。
            configuration.preservesAspectRatio = true
        }

        let capturesAppAudio = options.recordsSystemAudio && options.systemAudioScope == .application
        if capturesAppAudio {
            Self.configureAudio(configuration)
        }

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        if capturesAppAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        }
        self.stream = stream

        if options.recordsSystemAudio && options.systemAudioScope == .entireMac {
            audioStream = try await makeEntireMacAudioStream()
        }

        if options.recordsMicrophone {
            let microphone = try MicrophoneCapture(deviceID: options.microphoneDeviceID, queue: sampleQueue) { [weak self] buffer in
                self?.writer.appendAudio(buffer, track: .microphone)
            }
            self.microphone = microphone
            microphone.start()
        }

        do {
            try await stream.startCapture()
            try await audioStream?.startCapture()
        } catch {
            try? await stream.stopCapture()
            microphone?.stop()
            sampleQueue.sync { writer.cancel() }
            throw error
        }
    }

    private static func configureAudio(_ configuration: SCStreamConfiguration) {
        configuration.capturesAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true
    }

    /// ディスプレイ全体を対象にした、音声だけを拾うストリーム。
    /// 映像は使わないので 2 × 2 ピクセル・1fps に絞る。
    private func makeEntireMacAudioStream() async throws -> SCStream {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw ScreenCaptureError.noDisplayFound }

        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false
        Self.configureAudio(configuration)

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        // 映像の出力先が無いとフレームごとに警告が出るので、受けるだけ受けて捨てる。
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        return stream
    }

    /// 収録を止めてファイルを閉じる。
    func stop() async throws -> RecordingWriterResult {
        sampleQueue.sync { isStopping = true }
        try? await stream?.stopCapture()
        try? await audioStream?.stopCapture()
        stream = nil
        audioStream = nil
        microphone?.stop()
        microphone = nil

        // キューに残っているサンプルを流し切ってから閉じる。
        // isStopping 以降は新しいサンプルを書かないので、ここから先は writer に触るのはこちらだけ。
        sampleQueue.sync {}
        return try await writer.finish()
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, !isStopping else { return }

        switch type {
        case .screen:
            guard stream !== audioStream else { return }
            // 画面に変化がないときは .idle のフレーム（画像なし）が届くので、完全なものだけ書く。
            guard
                let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]],
                let info = attachments.first,
                let statusRaw = info[.status] as? Int,
                SCFrameStatus(rawValue: statusRaw) == .complete,
                let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
            else { return }

            let fitted = fitter.fit(pixelBuffer, contentRect: Self.contentRect(of: info, buffer: pixelBuffer))
            writer.appendVideo(fitted, at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))

        case .audio:
            writer.appendAudio(sampleBuffer, track: .system)

        default:
            break
        }
    }

    /// バッファの中でウィンドウが描かれている範囲（ピクセル）。
    /// contentRect はポイント単位なので scaleFactor を掛ける。取れなければバッファ全体とみなす。
    private static func contentRect(of info: [SCStreamFrameInfo: Any], buffer: CVPixelBuffer) -> CGRect {
        let whole = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        guard let value = info[.contentRect],
              let rect = CGRect(dictionaryRepresentation: value as! CFDictionary)
        else { return whole }

        let scale = info[.scaleFactor] as? CGFloat ?? 1
        return CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // 音声専用のストリームが止まっても、映像は撮り続ける。
        guard stream !== audioStream else { return }
        sampleQueue.async { [weak self] in
            guard let self, !self.isStopping else { return }
            DispatchQueue.main.async {
                self.onUnexpectedStop?(error)
            }
        }
    }
}
