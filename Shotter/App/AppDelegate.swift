import AppKit

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
}
