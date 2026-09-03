import AppKit
import CoreImage
import CoreMedia
import CoreVideo
import ScreenCaptureKit

/// 1 ディスプレイ分のフリーズ画像。
/// `frame` は AppKit グローバル座標（左下原点・ポイント単位）。
struct DisplaySnapshot {
    let displayID: CGDirectDisplayID
    let frame: CGRect
    let scale: CGFloat
    let image: CGImage
}

enum ScreenCaptureError: LocalizedError {
    case permissionDenied
    case noDisplayFound
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "画面収録の権限が許可されていません。"
        case .noDisplayFound:
            return "キャプチャ可能なディスプレイが見つかりませんでした。"
        case .captureFailed(let reason):
            return "キャプチャに失敗しました: \(reason)"
        }
    }
}

/// ScreenCaptureKit を使って画面を取得するサービス。
///
/// 範囲選択の前に全ディスプレイを 1 度だけ撮影して「画面をフリーズ」させ、
/// 選択後はその画像から切り出す方式にしている。こうすることで
/// オーバーレイ自体が写り込まず、前面アプリのアクティブ状態も変化しない。
final class ScreenCaptureService {

    /// 権限ダイアログを出さずに現在の許可状態だけを調べる。
    var hasScreenRecordingPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// 未許可なら初回だけシステムの権限ダイアログを表示する。
    @discardableResult
    func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// 接続中の全ディスプレイを撮影する。
    func captureAllDisplays() async throws -> [DisplaySnapshot] {
        guard hasScreenRecordingPermission else {
            throw ScreenCaptureError.permissionDenied
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            throw ScreenCaptureError.permissionDenied
        }

        // Shotter 自身のウィンドウ（前回のサムネイルや HUD が消え切っていない場合など）は、
        // 写り込むと紛らわしいので撮影対象から常に除外する。
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == ownPID }

        var snapshots: [DisplaySnapshot] = []
        for screen in NSScreen.screens {
            guard
                let displayID = screen.displayID,
                let display = content.displays.first(where: { $0.displayID == displayID })
            else { continue }

            let scale = screen.backingScaleFactor
            let image = try await captureFullDisplay(display, scale: scale, excludingWindows: ownWindows)
            snapshots.append(
                DisplaySnapshot(
                    displayID: displayID,
                    frame: screen.frame,
                    scale: scale,
                    image: image
                )
            )
        }

        guard !snapshots.isEmpty else { throw ScreenCaptureError.noDisplayFound }
        return snapshots
    }

    /// ウィンドウの形（角丸を含む）をアルファ付きで取得する。
    ///
    /// `SCContentFilter(desktopIndependentWindow:)` はウィンドウ単体を
    /// **背景が透明な状態**で返す。その透明度をマスクとして使えば、
    /// 角丸の半径を推測せずに正確な形で切り抜ける。
    ///
    /// - Returns: 取得できなければ nil（呼び出し側で角丸の近似にフォールバックする）。
    func windowShapeMask(windowID: CGWindowID, pixelSize: CGSize) async -> CGImage? {
        guard #available(macOS 14.0, *) else { return nil }
        guard pixelSize.width >= 1, pixelSize.height >= 1 else { return nil }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                return nil
            }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            configuration.width = Int(pixelSize.width)
            configuration.height = Int(pixelSize.height)
            configuration.showsCursor = false
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            // 影を含めると形が変わってしまうので除外する。
            configuration.ignoreShadowsSingleWindow = true
            configuration.shouldBeOpaque = false
            configuration.captureResolution = .best

            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
        } catch {
            return nil
        }
    }

    // MARK: - Private

    private func captureFullDisplay(_ display: SCDisplay, scale: CGFloat, excludingWindows: [SCWindow]) async throws -> CGImage {
        let filter = SCContentFilter(display: display, excludingWindows: excludingWindows)

        let configuration = SCStreamConfiguration()
        configuration.width = Int(CGFloat(display.width) * scale)
        configuration.height = Int(CGFloat(display.height) * scale)
        configuration.scalesToFit = false
        configuration.showsCursor = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        if #available(macOS 14.0, *) {
            configuration.captureResolution = .best
        }

        if #available(macOS 14.0, *) {
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
        } else {
            // macOS 13 には SCScreenshotManager が無いため、
            // SCStream を 1 フレームだけ回して静止画を得る。
            return try await SingleFrameCapturer().capture(
                filter: filter,
                configuration: configuration
            )
        }
    }
}

// MARK: - macOS 13 用フォールバック

/// SCStream を開始して最初の完全なフレームだけを取り出す。
private final class SingleFrameCapturer: NSObject, SCStreamOutput, @unchecked Sendable {

    private let sampleQueue = DispatchQueue(label: "com.ippei.Shotter.SingleFrameCapturer")
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private var continuation: CheckedContinuation<CGImage, Error>?
    private var stream: SCStream?
    private var isFinished = false

    func capture(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            do {
                let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
                self.stream = stream

                stream.startCapture { [weak self] error in
                    if let error {
                        self?.finish(with: .failure(error))
                    }
                }
            } catch {
                finish(with: .failure(error))
                return
            }

            // フレームが来ない場合に永久に待たないようタイムアウトを入れる。
            sampleQueue.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.finish(with: .failure(ScreenCaptureError.captureFailed("タイムアウトしました")))
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, !isFinished else { return }

        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
            let statusRaw = attachments.first?[.status] as? Int,
            SCFrameStatus(rawValue: statusRaw) == .complete,
            let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }

        finish(with: .success(cgImage))
    }

    private func finish(with result: Result<CGImage, Error>) {
        sampleQueue.async { [self] in
            guard !isFinished, let continuation else { return }
            isFinished = true
            self.continuation = nil

            stream?.stopCapture { _ in }
            stream = nil

            continuation.resume(with: result)
        }
    }
}
