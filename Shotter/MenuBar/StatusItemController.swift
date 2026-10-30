import AppKit
import Combine

/// メニューバー(NSStatusBar)に常駐するアイコンとそのメニューを管理する。
///
/// 収録中はメニューの代わりに「● 経過時間」を出し、クリックで収録を止める。
@MainActor
final class StatusItemController: NSObject {

    private let statusItem: NSStatusItem
    private var menu: NSMenu?
    private var cancellables: Set<AnyCancellable> = []

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        configureButton()
        menu = makeMenu()
        statusItem.menu = menu
        observeRecording()
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

    // MARK: - 収録中の表示

    /// 収録中だけ出すメニュー。項目は収録の状態に合わせて書き換える。
    private let recordingMenu = NSMenu()
    private let recordingTitleItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let recordingElapsedItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private lazy var stopItem = NSMenuItem(title: "停止して保存", action: #selector(stopRecording), keyEquivalent: "")
    private lazy var discardItem = NSMenuItem(title: "保存せずに破棄…", action: #selector(discardRecording), keyEquivalent: "")

    private func observeRecording() {
        recordingTitleItem.isEnabled = false
        recordingElapsedItem.isEnabled = false
        stopItem.target = self
        stopItem.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil)
        discardItem.target = self
        recordingMenu.autoenablesItems = false
        recordingMenu.items = [recordingTitleItem, recordingElapsedItem, .separator(), stopItem, discardItem]

        let coordinator = RecordingCoordinator.shared
        coordinator.$state
            .combineLatest(coordinator.$elapsed, coordinator.$targetAppName)
            .receive(on: RunLoop.main)
            .sink { [weak self] state, elapsed, appName in
                self?.updateForRecording(state: state, elapsed: elapsed, appName: appName)
            }
            .store(in: &cancellables)
    }

    private func updateForRecording(state: RecordingCoordinator.State, elapsed: TimeInterval, appName: String?) {
        guard let button = statusItem.button else { return }

        switch state {
        case .recording, .finishing:
            let isSaving = state == .finishing
            statusItem.length = NSStatusItem.variableLength
            statusItem.menu = recordingMenu

            // 収録中であることがひと目で分かるよう、赤い丸と「収録中」を並べる。
            let image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "収録中")
            button.image = image?.withSymbolConfiguration(.init(paletteColors: [.white, .systemRed]))
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.title = isSaving ? " 保存中…" : " 収録中 " + VideoDurationBadge.format(elapsed)
            button.toolTip = "クリックで停止・破棄のメニューを開きます"

            recordingTitleItem.title = "\(appName ?? "ウィンドウ") のウィンドウを収録中"
            recordingElapsedItem.title = "経過時間 " + VideoDurationBadge.format(elapsed)
            let shortcut = HotKeyManager.shared.registeredCombos[.screenRecording].map { "（\($0.displayString)）" } ?? ""
            stopItem.title = "停止して保存" + shortcut
            stopItem.isEnabled = !isSaving
            discardItem.isEnabled = !isSaving

        default:
            guard statusItem.menu !== menu else { return }
            statusItem.length = NSStatusItem.squareLength
            button.title = ""
            configureButton()
            statusItem.menu = menu
        }
    }

    @objc private func stopRecording() {
        RecordingCoordinator.shared.stop()
    }

    @objc private func discardRecording() {
        let alert = NSAlert()
        alert.messageText = "収録を破棄しますか？"
        alert.informativeText = "ここまで収録した \(VideoDurationBadge.format(RecordingCoordinator.shared.elapsed)) の動画は保存されません。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "破棄する")
        alert.addButton(withTitle: "収録を続ける")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        RecordingCoordinator.shared.discard()
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

        let record = NSMenuItem(
            title: "ウィンドウを収録",
            action: #selector(recordWindow),
            keyEquivalent: ""
        )
        record.target = self
        record.toolTip = [
            shortcutTooltip(for: .screenRecording),
            "選んだウィンドウを動画で収録します。もう一度ショートカットを押すか、メニューバーの「● 収録中」から止められます",
        ].compactMap { $0 }.joined(separator: "\n")
        menu.addItem(record)

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

    @objc private func recordWindow() {
        RecordingCoordinator.shared.start()
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
