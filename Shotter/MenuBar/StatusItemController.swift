import AppKit

/// メニューバー(NSStatusBar)に常駐するアイコンとそのメニューを管理する。
@MainActor
final class StatusItemController: NSObject {

    private let statusItem: NSStatusItem

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        configureButton()
        statusItem.menu = makeMenu()
    }

    // MARK: - Setup

    private func configureButton() {
        guard let button = statusItem.button else { return }

        let image = NSImage(
            systemSymbolName: "camera",
            accessibilityDescription: "Shotter"
        )
        // テンプレート画像にすることでライト/ダークモードに追従して着色される。
        image?.isTemplate = true
        button.image = image
        button.toolTip = "Shotter"
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let capture = NSMenuItem(
            title: "範囲を選択してキャプチャ",
            action: #selector(captureArea),
            keyEquivalent: ""
        )
        capture.target = self
        capture.toolTip = shortcutTooltip(for: .areaCapture)
        menu.addItem(capture)

        let captureWindow = NSMenuItem(
            title: "ウィンドウを選択してキャプチャ",
            action: #selector(captureWindow),
            keyEquivalent: ""
        )
        captureWindow.target = self
        captureWindow.toolTip = [
            shortcutTooltip(for: .windowCapture),
            "選択中に Space キーで範囲選択と切り替えられます",
        ].compactMap { $0 }.joined(separator: "\n")
        menu.addItem(captureWindow)

        let recognizeText = NSMenuItem(
            title: "文字を読み取ってコピー",
            action: #selector(captureTextRecognition),
            keyEquivalent: ""
        )
        recognizeText.target = self
        recognizeText.toolTip = [
            shortcutTooltip(for: .textRecognition),
            "選んだ範囲の日本語・英語の文字をテキストにしてコピーします",
        ].compactMap { $0 }.joined(separator: "\n")
        menu.addItem(recognizeText)

        menu.addItem(.separator())

        let history = NSMenuItem(
            title: "履歴…",
            action: #selector(openHistory),
            keyEquivalent: ""
        )
        history.target = self
        history.toolTip = "撮影した画像を後から取り出せます"
        menu.addItem(history)

        menu.addItem(.separator())

        let permission = NSMenuItem(
            title: "画面収録の権限…",
            action: #selector(openPermissionGuide),
            keyEquivalent: ""
        )
        permission.target = self
        menu.addItem(permission)

        let preferences = NSMenuItem(
            title: "設定…",
            action: #selector(openPreferences),
            keyEquivalent: ","
        )
        preferences.target = self
        menu.addItem(preferences)

        menu.addItem(.separator())

        let relaunch = NSMenuItem(
            title: "Shotter を再起動",
            action: #selector(relaunch),
            keyEquivalent: ""
        )
        relaunch.target = self
        menu.addItem(relaunch)

        let quit = NSMenuItem(
            title: "Shotter を終了",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        return menu
    }

    private func shortcutTooltip(for action: HotKeyAction) -> String? {
        guard let combo = HotKeyManager.shared.registeredCombos[action] else { return nil }
        return "ショートカット: \(combo.displayString)"
    }

    // MARK: - Actions

    @objc private func captureArea() {
        CaptureCoordinator.shared.startAreaCapture()
    }

    @objc private func captureWindow() {
        CaptureCoordinator.shared.startWindowCapture()
    }

    @objc private func captureTextRecognition() {
        CaptureCoordinator.shared.startTextRecognitionCapture()
    }

    @objc private func openPreferences() {
        SettingsWindowController.show()
    }

    @objc private func openHistory() {
        HistoryWindowController.show()
    }

    @objc private func openPermissionGuide() {
        OnboardingWindowController.show()
    }

    /// 新しいプロセスを立ち上げてから自分を終了する。
    @objc private func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in }
        NSApp.terminate(nil)
    }
}
