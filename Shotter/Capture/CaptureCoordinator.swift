import AppKit

/// 「範囲を選択してキャプチャ」の一連の流れをまとめる。
///
/// 1. 全ディスプレイを撮影して画面をフリーズさせる
/// 2. オーバーレイで範囲選択させる
/// 3. フリーズ画像から選択範囲を切り出す
/// 4. 設定に応じて注釈編集ウィンドウを開く／クリップボードへコピーする
@MainActor
final class CaptureCoordinator {

    static let shared = CaptureCoordinator()

    private let captureService = ScreenCaptureService()
    private let selectionController = AreaSelectionController()
    private var isBusy = false

    /// 直近のキャプチャ結果。ステップ3の注釈ウィンドウで利用する予定。
    private(set) var lastCapturedImage: CGImage?

    private init() {}

    /// 保存済みのホットキーをまとめて登録する。起動時に呼ぶ。
    /// - Returns: 登録に失敗した操作の一覧。
    @discardableResult
    func registerStoredHotKeys() -> [HotKeyAction] {
        var failed: [HotKeyAction] = []
        if !applyHotKey(Preferences.hotKey, for: .areaCapture) { failed.append(.areaCapture) }
        if !applyHotKey(Preferences.windowHotKey, for: .windowCapture) { failed.append(.windowCapture) }
        if !applyHotKey(Preferences.textRecognitionHotKey, for: .textRecognition) {
            failed.append(.textRecognition)
        }
        return failed
    }

    /// - Parameter combo: nil ならそのホットキーを解除する。
    /// - Returns: 登録できたら true。
    @discardableResult
    func applyHotKey(_ combo: KeyCombo?, for action: HotKeyAction) -> Bool {
        guard let combo else {
            HotKeyManager.shared.unregister(action)
            return true
        }

        return HotKeyManager.shared.register(combo, for: action) {
            switch action {
            case .areaCapture:     CaptureCoordinator.shared.startAreaCapture()
            case .windowCapture:   CaptureCoordinator.shared.startWindowCapture()
            case .textRecognition: CaptureCoordinator.shared.startTextRecognitionCapture()
            }
        }
    }

    func startAreaCapture() {
        startCapture(mode: .area)
    }

    func startWindowCapture() {
        startCapture(mode: .window)
    }

    /// 範囲を選んで、その中の文字を読み取ってクリップボードへ入れる。
    func startTextRecognitionCapture() {
        startCapture(mode: .area, purpose: .textRecognition)
    }

    private func startCapture(mode: CaptureMode, purpose: CapturePurpose = .screenshot) {
        guard !isBusy else { return }

        guard captureService.hasScreenRecordingPermission else {
            // 初回はシステム標準のダイアログを出しつつ、手順の案内ウィンドウを開く。
            captureService.requestScreenRecordingPermission()
            OnboardingWindowController.show()
            return
        }

        isBusy = true
        Task { [weak self] in
            guard let self else { return }
            await self.runCaptureFlow(mode: mode, purpose: purpose)
            self.isBusy = false
        }
    }

    // MARK: - Private

    private func runCaptureFlow(mode: CaptureMode, purpose: CapturePurpose) async {
        let snapshots: [DisplaySnapshot]
        do {
            snapshots = try await captureService.captureAllDisplays()
        } catch {
            AlertPresenter.showError(error)
            return
        }

        guard let selection = await selectRegion(in: snapshots, mode: mode) else { return }

        guard var image = SnapshotCompositor.crop(snapshots, to: selection.rect) else {
            AlertPresenter.showError(ScreenCaptureError.captureFailed("選択範囲を切り出せませんでした"))
            return
        }

        // ウィンドウを撮った場合、四隅には背景が写り込んでいる。
        if let windowID = selection.windowID {
            let scale = snapshots.first { $0.frame.intersects(selection.rect) }?.scale ?? 2
            image = await maskToWindowShape(image, windowID: windowID, scale: scale)
        }

        lastCapturedImage = image

        guard purpose == .screenshot else {
            await recognizeText(in: image)
            return
        }

        switch Preferences.afterCaptureAction {
        case .openEditor:
            EditorWindowController.present(image: image, pointSize: selection.rect.size)

        case .thumbnail:
            copyOrReportFailure(image)
            NSApp.deactivate()
            CaptureThumbnailPresenter.show(image: image, pointSize: selection.rect.size) {
                EditorWindowController.present(image: image, pointSize: selection.rect.size)
            }

        case .copyOnly:
            copyOrReportFailure(image)
            HUDPresenter.show("クリップボードにコピーしました", symbolName: "checkmark.circle.fill")
            NSApp.deactivate()
        }
    }

    /// 選択範囲の文字を読み取ってクリップボードへ入れる。
    private func recognizeText(in image: CGImage) async {
        NSApp.deactivate()

        do {
            let result = try await TextRecognizer.recognize(in: image)
            guard !result.isEmpty else {
                HUDPresenter.show("文字を検出できませんでした", symbolName: "exclamationmark.triangle.fill")
                return
            }

            Pasteboard.copy(text: result.joined)
            HUDPresenter.show(
                "文字をコピーしました（\(result.lines.count) 行）",
                symbolName: "text.viewfinder"
            )
        } catch {
            AlertPresenter.showError(error)
        }
    }

    /// ウィンドウの実際の形で切り抜く。
    /// 形が取れなければ、OS に応じた角丸の近似にフォールバックする。
    func maskToWindowShape(
        _ image: CGImage,
        windowID: CGWindowID,
        scale: CGFloat
    ) async -> CGImage {
        let pixelSize = CGSize(width: image.width, height: image.height)

        if let mask = await captureService.windowShapeMask(windowID: windowID, pixelSize: pixelSize),
           let masked = ImageMask.applying(alphaMask: mask, to: image) {
            return masked
        }

        let radius = ImageMask.fallbackWindowCornerRadius * scale
        return ImageMask.roundedCorners(image, radius: radius) ?? image
    }

    private func copyOrReportFailure(_ image: CGImage) {
        guard !Pasteboard.copy(image) else { return }
        AlertPresenter.showError(ScreenCaptureError.captureFailed("クリップボードへコピーできませんでした"))
    }

    private func selectRegion(
        in snapshots: [DisplaySnapshot],
        mode: CaptureMode
    ) async -> SelectionResult? {
        await withCheckedContinuation { continuation in
            selectionController.begin(snapshots: snapshots, mode: mode) { result in
                continuation.resume(returning: result)
            }
        }
    }

}

/// 撮影した画像をどう使うか。
enum CapturePurpose {
    case screenshot
    case textRecognition
}
