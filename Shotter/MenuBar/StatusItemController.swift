import AppKit
import Combine

/// メニューバー(NSStatusBar)に常駐するアイコンとそのメニューを管理する。
///
/// 収録中はメニューの代わりに「● 経過時間」を出し、クリックで収録を止める。
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {

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

    // MARK: - 収録中・予約中の表示

    /// 収録中だけ出すメニュー。項目は収録の状態に合わせて書き換える。
    private let recordingMenu = NSMenu()
    private let recordingTitleItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let recordingElapsedItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    /// 終了時刻を予約しているときだけ出す。
    private let recordingStopTimeItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private lazy var stopItem = NSMenuItem(title: "停止して保存", action: #selector(stopRecording), keyEquivalent: "")
    private lazy var discardItem = NSMenuItem(title: "保存せずに破棄…", action: #selector(discardRecording), keyEquivalent: "")

    /// 開始時刻を待っている間に出すメニュー。
    private let scheduledMenu = NSMenu()
    private let scheduledTitleItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let scheduledRemainingItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private lazy var startNowItem = NSMenuItem(title: "今すぐ開始", action: #selector(startScheduledNow), keyEquivalent: "")
    private lazy var cancelScheduleItem = NSMenuItem(title: "予約を取り消す…", action: #selector(cancelSchedule), keyEquivalent: "")

    private func observeRecording() {
        for item in [recordingTitleItem, recordingElapsedItem, recordingStopTimeItem, scheduledTitleItem, scheduledRemainingItem] {
            item.isEnabled = false
        }
        stopItem.target = self
        stopItem.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil)
        discardItem.target = self
        recordingMenu.autoenablesItems = false
        recordingMenu.items = [recordingTitleItem, recordingElapsedItem, recordingStopTimeItem, .separator(), stopItem, discardItem]

        startNowItem.target = self
        startNowItem.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)
        cancelScheduleItem.target = self
        scheduledMenu.autoenablesItems = false
        scheduledMenu.items = [scheduledTitleItem, scheduledRemainingItem, .separator(), startNowItem, cancelScheduleItem]

        // 経過時間・残り時間・予約時刻など、どれが変わっても描き直す（変わった直後の値を読む）。
        RecordingCoordinator.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateForRecording() }
            .store(in: &cancellables)
    }

    private func updateForRecording() {
        guard let button = statusItem.button else { return }
        let coordinator = RecordingCoordinator.shared
        let appName = coordinator.targetAppName ?? "ウィンドウ"

        switch coordinator.state {
        case .recording, .finishing:
            let isSaving = coordinator.state == .finishing
            statusItem.length = NSStatusItem.variableLength
            statusItem.menu = recordingMenu

            // 収録中であることがひと目で分かるよう、赤い丸と「収録中」を並べる。
            let image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "収録中")
            button.image = image?.withSymbolConfiguration(.init(paletteColors: [.white, .systemRed]))
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.title = isSaving ? " 保存中…" : " 収録中 " + VideoDurationBadge.format(coordinator.elapsed)
            button.toolTip = "クリックで停止・破棄のメニューを開きます"

            recordingTitleItem.title = "\(appName) のウィンドウを収録中"
            recordingElapsedItem.title = "経過時間 " + VideoDurationBadge.format(coordinator.elapsed)
            if let stopDate = coordinator.scheduledStop {
                recordingStopTimeItem.title = "\(RecordingSchedule.timeText(stopDate)) に自動で終了します"
                recordingStopTimeItem.isHidden = false
            } else {
                recordingStopTimeItem.isHidden = true
            }
            let shortcut = HotKeyManager.shared.registeredCombos[.screenRecording].map { "（\($0.displayString)）" } ?? ""
            stopItem.title = "停止して保存" + shortcut
            stopItem.isEnabled = !isSaving
            discardItem.isEnabled = !isSaving

        case .scheduled:
            statusItem.length = NSStatusItem.variableLength
            statusItem.menu = scheduledMenu

            let start = coordinator.scheduledStart ?? Date()
            let image = NSImage(systemSymbolName: "timer", accessibilityDescription: "収録の予約")
            button.image = image?.withSymbolConfiguration(.init(paletteColors: [.systemOrange]))
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.title = " \(RecordingSchedule.timeText(start)) 開始"
            button.toolTip = "収録を予約しています。クリックで今すぐ開始・取り消しのメニューを開きます"

            var title = "\(appName) のウィンドウを \(RecordingSchedule.timeText(start)) から収録"
            if let stopDate = coordinator.scheduledStop {
                title += "（\(RecordingSchedule.timeText(stopDate, relativeTo: start)) まで）"
            }
            scheduledTitleItem.title = title
            scheduledRemainingItem.title = "開始まで " + VideoDurationBadge.format(coordinator.remainingUntilStart)

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

    @objc private func startScheduledNow() {
        RecordingCoordinator.shared.startScheduledNow()
    }

    @objc private func cancelSchedule() {
        let alert = NSAlert()
        alert.messageText = "収録の予約を取り消しますか？"
        alert.addButton(withTitle: "取り消す")
        alert.addButton(withTitle: "予約したままにする")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        RecordingCoordinator.shared.cancelSchedule()
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

    /// ホットキーで呼べる項目。メニューを開くたびに、今のショートカットを書き直す。
    private var hotKeyItems: [(item: NSMenuItem, action: HotKeyAction, detail: String?)] = []

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let capture = NSMenuItem(
            title: "範囲を選択してキャプチャ",
            action: #selector(captureArea),
            keyEquivalent: ""
        )
        capture.target = self
        menu.addItem(capture)
        hotKeyItems.append((capture, .areaCapture, nil))

        let captureWindow = NSMenuItem(
            title: "ウィンドウを選択してキャプチャ",
            action: #selector(captureWindow),
            keyEquivalent: ""
        )
        captureWindow.target = self
        menu.addItem(captureWindow)
        hotKeyItems.append((captureWindow, .windowCapture, "範囲選択の途中でも、Space キーでカーソル下のウィンドウを撮れます"))

        let recognizeText = NSMenuItem(
            title: "文字を読み取ってコピー",
            action: #selector(captureTextRecognition),
            keyEquivalent: ""
        )
        recognizeText.target = self
        menu.addItem(recognizeText)
        hotKeyItems.append((recognizeText, .textRecognition, "選んだ範囲の日本語・英語の文字をテキストにしてコピーします"))

        menu.addItem(.separator())

        let record = NSMenuItem(
            title: "ウィンドウを収録",
            action: #selector(recordWindow),
            keyEquivalent: ""
        )
        record.target = self
        menu.addItem(record)
        hotKeyItems.append((
            record, .screenRecording,
            "選んだウィンドウを動画で収録します。もう一度ショートカットを押すか、メニューバーの「● 収録中」から止められます"
        ))

        menu.addItem(.separator())

        let history = NSMenuItem(
            title: "履歴…",
            action: #selector(openHistory),
            keyEquivalent: ""
        )
        history.target = self
        history.toolTip = "撮影した画像や収録した動画を後から取り出せます"
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

        refreshShortcuts()
        return menu
    }

    /// 設定でホットキーを変えたあとも正しく出るよう、開く直前に書き直す。
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        refreshShortcuts()
    }

    /// 登録できているホットキーを、項目の右側（出せないキーはツールチップ）に出す。
    private func refreshShortcuts() {
        for entry in hotKeyItems {
            let combo = HotKeyManager.shared.registeredCombos[entry.action]
            if let equivalent = combo?.menuKeyEquivalent {
                entry.item.keyEquivalent = equivalent.key
                entry.item.keyEquivalentModifierMask = equivalent.modifiers
            } else {
                entry.item.keyEquivalent = ""
                entry.item.keyEquivalentModifierMask = []
            }
            entry.item.toolTip = [
                combo.map { "ショートカット: \($0.displayString)" },
                entry.detail,
            ].compactMap { $0 }.joined(separator: "\n")
        }
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
        guard AppDelegate.confirmQuitIfScheduled() else { return }

        Task { @MainActor in
            // 収録中なら先に保存を済ませる。新しいプロセスは起動時に書きかけの収録ファイルを
            // 履歴へ移すので、書いている途中で立ち上げるとファイルを横取りされてしまう。
            await RecordingCoordinator.shared.finishBeforeTermination()

            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in }
            NSApp.terminate(nil)
        }
    }
}
