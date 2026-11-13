import AVFoundation

/// マイク 1 つ分の情報。設定画面の選択肢に使う。
struct MicrophoneDevice: Identifiable, Hashable {
    let id: String
    let name: String
}

/// マイクの音を拾って CMSampleBuffer として渡す。
///
/// ScreenCaptureKit でマイクを録れるのは macOS 15 からなので、
/// macOS 13〜14 でも同じ経路で動くよう AVCaptureSession を使う。
final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let handler: (CMSampleBuffer) -> Void

    /// - Parameters:
    ///   - deviceID: nil ならシステムの既定のマイク。見つからなければ既定にフォールバックする。
    ///   - queue: サンプルを受け取るキュー。映像と同じキューにすると書き込み側でロックが要らない。
    init(deviceID: String?, queue: DispatchQueue, handler: @escaping (CMSampleBuffer) -> Void) throws {
        self.handler = handler
        super.init()

        let device = deviceID.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .audio)
        guard let device else { throw MicrophoneError.noDevice }

        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw MicrophoneError.noDevice
        }
        session.addInput(input)
        // 書き込み側の AAC エンコーダに合わせて、48kHz・モノラルの PCM で受け取る。
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)
        session.commitConfiguration()
    }

    func start() {
        session.startRunning()
    }

    func stop() {
        session.stopRunning()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // 画面収録のサンプルはホストの時計で時刻が付いている。マイク側の時計が違う場合は揃える。
        let clock = session.synchronizationClock ?? CMClockGetHostTimeClock()
        guard !CFEqual(clock, CMClockGetHostTimeClock()) else {
            handler(sampleBuffer)
            return
        }

        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let hostTime = CMSyncConvertTime(time, from: clock, to: CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: hostTime,
            decodeTimeStamp: .invalid
        )
        var retimed: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &retimed
        )
        if let retimed { handler(retimed) }
    }

    // MARK: - 権限とデバイス

    static var authorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// 未確認なら許可ダイアログを出す。
    /// - Returns: 使ってよければ true。
    static func requestAccessIfNeeded() async -> Bool {
        switch authorizationStatus {
        case .authorized:    return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default:             return false
        }
    }

    static func availableDevices() -> [MicrophoneDevice] {
        let types: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            types = [.microphone, .external]
        } else {
            types = [.builtInMicrophone, .externalUnknown]
        }
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .audio, position: .unspecified)
            .devices
            .map { MicrophoneDevice(id: $0.uniqueID, name: $0.localizedName) }
    }
}

enum MicrophoneError: LocalizedError {
    case noDevice

    var errorDescription: String? {
        "使えるマイクが見つかりませんでした。"
    }
}
