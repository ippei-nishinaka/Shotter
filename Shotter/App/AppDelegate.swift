import AppKit
import ImageIO

/// Finder の「このアプリで開く」や `open -a Shotter <path>` で渡された画像を読み込めなかった場合のエラー。
enum FileOpenError: LocalizedError {
    case unreadableImage(URL)

    var errorDescription: String? {
        switch self {
        case .unreadableImage(let url):
            return "\(url.lastPathComponent) を画像として読み込めませんでした。"
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement アプリでも ⌘Z / ⌘C / ⌘W を効かせるためにメインメニューを設定する。
        NSApp.mainMenu = MainMenu.build()
        let failedHotKeys = CaptureCoordinator.shared.registerStoredHotKeys()
        #if DEBUG
        DebugSupport.log(
            "ホットキー登録  範囲: \(Preferences.hotKey.displayString)"
                + "  ウィンドウ: \(Preferences.windowHotKey.displayString)"
                + "  文字認識: \(Preferences.textRecognitionHotKey.displayString)"
                + (failedHotKeys.isEmpty ? " → すべて成功" : " → 失敗: \(failedHotKeys.map(\.title))")
        )
        #endif
        statusItemController = StatusItemController()

        // 保持期間を過ぎた履歴をファイルごと削除する。
        let purged = HistoryStore.shared.purgeExpired()
        #if DEBUG
        if purged > 0 { DebugSupport.log("期限切れの履歴を \(purged) 件削除しました") }
        #endif
        OnboardingWindowController.showIfNeeded()

        #if DEBUG
        if DebugSupport.shouldOpenEditorOnLaunch {
            DebugSupport.openEditorWithSampleImage()
        }
        if DebugSupport.shouldOpenSettings {
            DebugSupport.openSettingsAndDump()
        }
        if DebugSupport.shouldOpenAbout {
            DebugSupport.openAboutAndDump()
        }
        if DebugSupport.shouldOpenOnboarding {
            DebugSupport.openOnboardingAndDump()
        }
        if CommandLine.arguments.contains("--debug-loginitem") {
            DebugSupport.dumpLoginItemStatusAndQuit()
        }
        if CommandLine.arguments.contains("--debug-ocr") {
            DebugSupport.runOCRCheckAndQuit()
            return
        }
        if CommandLine.arguments.contains("--debug-history-window") {
            DebugSupport.dumpHistoryWindowAndQuit()
            return
        }
        if CommandLine.arguments.contains("--debug-apply-check") {
            DebugSupport.runApplyCheckAndQuit()
            return
        }
        if CommandLine.arguments.contains("--debug-history") {
            DebugSupport.testHistoryPurgeAndQuit()
            return
        }
        if CommandLine.arguments.contains("--debug-window-capture") {
            DebugSupport.dumpWindowCaptureAndQuit()
            return
        }
        if CommandLine.arguments.contains("--debug-corner-probe") {
            DebugSupport.probeWindowCornerRadiusAndQuit()
            return
        }
        if CommandLine.arguments.contains("--debug-rounded") {
            DebugSupport.dumpRoundedCornerSampleAndQuit()
            return
        }
        if CommandLine.arguments.contains("--debug-capture-timing") {
            DebugSupport.measureCaptureTimingAndQuit()
            return
        }
        if CommandLine.arguments.contains("--debug-overlay-frames") {
            DebugSupport.dumpOverlayFramesAndQuit()
            return
        }
        if CommandLine.arguments.contains("--debug-windows") {
            DebugSupport.dumpWindowListAndQuit()
        }
        if DebugSupport.shouldShowThumbnail {
            DebugSupport.showThumbnailAndDump()
        }
        #endif
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// `open -a Shotter <path>` や Finder の「このアプリで開く」から渡された画像を注釈エディタで開く。
    /// BTT などから「ファイルへ保存 → このアプリで開く」を叩く連携を想定している。
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            openInEditor(fileAt: url)
        }
    }

    private func openInEditor(fileAt url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            AlertPresenter.showError(FileOpenError.unreadableImage(url), title: "開けませんでした")
            return
        }

        // 通常の撮影と同じく、注釈を付ける前の状態を履歴に残す。
        let historyURL = HistoryStore.shared.save(image)

        // ウィンドウが実際に開く画面のスケールに合わせないと、キャンバスが引き伸ばされてぼやける。
        let scale = EditorWindowController.screenUnderMouse()?.backingScaleFactor ?? 2
        EditorWindowController.present(
            image: image,
            pointSize: CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale),
            historyURL: historyURL
        )
    }
}
