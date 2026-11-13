import AppKit
import SwiftUI

/// 設定の実体。UserDefaults との読み書きをまとめ、変更をすぐ反映させる。
@MainActor
final class SettingsModel: ObservableObject {

    @Published var areaHotKey: KeyCombo? {
        didSet {
            guard areaHotKey != oldValue else { return }
            Preferences.hotKey = areaHotKey
            areaHotKeyFailed = !CaptureCoordinator.shared.applyHotKey(areaHotKey, for: .areaCapture)
        }
    }

    @Published var windowHotKey: KeyCombo? {
        didSet {
            guard windowHotKey != oldValue else { return }
            Preferences.windowHotKey = windowHotKey
            windowHotKeyFailed = !CaptureCoordinator.shared.applyHotKey(windowHotKey, for: .windowCapture)
        }
    }

    @Published var textHotKey: KeyCombo? {
        didSet {
            guard textHotKey != oldValue else { return }
            Preferences.textRecognitionHotKey = textHotKey
            textHotKeyFailed = !CaptureCoordinator.shared.applyHotKey(textHotKey, for: .textRecognition)
        }
    }

    @Published var recordingHotKey: KeyCombo? {
        didSet {
            guard recordingHotKey != oldValue else { return }
            Preferences.recordingHotKey = recordingHotKey
            recordingHotKeyFailed = !CaptureCoordinator.shared.applyHotKey(recordingHotKey, for: .screenRecording)
        }
    }

    @Published var afterCaptureAction: AfterCaptureAction {
        didSet { Preferences.afterCaptureAction = afterCaptureAction }
    }

    @Published var addsShadowByDefault: Bool {
        didSet { Preferences.addsShadowByDefault = addsShadowByDefault }
    }

    @Published var roundsCornersByDefault: Bool {
        didSet { Preferences.roundsCornersByDefault = roundsCornersByDefault }
    }

    @Published var closesEditorOnCopyOrSave: Bool {
        didSet { Preferences.closesEditorOnCopyOrSave = closesEditorOnCopyOrSave }
    }

    @Published var historyRetention: HistoryRetention {
        didSet {
            guard historyRetention != oldValue else { return }
            Preferences.historyRetention = historyRetention
            // 期間を短くした（または保存しないに変えた）ときは、その場で削除する。
            HistoryStore.shared.purgeExpired()
        }
    }

    @Published var videoHistoryRetention: HistoryRetention {
        didSet {
            guard videoHistoryRetention != oldValue else { return }
            Preferences.videoHistoryRetention = videoHistoryRetention
            HistoryStore.shared.purgeExpired()
        }
    }

    // MARK: 保存先

    /// 実際に使っている保存先（選んだフォルダが見つからなければ既定の場所）。
    @Published private(set) var imageSaveDirectory = HistoryStore.shared.imageDirectory
    @Published private(set) var videoSaveDirectory = HistoryStore.shared.videoDirectory

    func saveDirectory(for kind: HistoryItemKind) -> URL {
        kind == .image ? imageSaveDirectory : videoSaveDirectory
    }

    func usesDefaultSaveDirectory(for kind: HistoryItemKind) -> Bool {
        saveDirectory(for: kind).standardizedFileURL == HistoryStore.shared.defaultDirectory.standardizedFileURL
    }

    /// フォルダを選ばせて保存先を変える。
    func chooseSaveDirectory(for kind: HistoryItemKind) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "ここに保存"
        panel.message = kind == .image ? "画像の保存先を選んでください" : "動画の保存先を選んでください"
        panel.directoryURL = saveDirectory(for: kind)
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        changeSaveDirectory(for: kind, to: url)
    }

    func resetSaveDirectory(for kind: HistoryItemKind) {
        changeSaveDirectory(for: kind, to: nil)
    }

    /// - Parameter url: nil なら既定の場所に戻す。
    private func changeSaveDirectory(for kind: HistoryItemKind, to url: URL?) {
        let store = HistoryStore.shared
        let destination = url ?? store.defaultDirectory
        guard destination.standardizedFileURL != saveDirectory(for: kind).standardizedFileURL else { return }

        // 今あるファイルを持っていくか聞く。持っていかなければ元の場所に残り、履歴には出なくなる。
        let noun = kind == .image ? "画像" : "動画"
        let count = store.itemCount(of: kind)
        var movesExisting = false
        if count > 0 {
            let alert = NSAlert()
            alert.messageText = "今ある\(noun) \(count) 件も新しい保存先へ移動しますか？"
            alert.informativeText = "移動しない場合、それらのファイルは元の場所に残り、履歴には表示されなくなります。"
            alert.addButton(withTitle: "移動する")
            alert.addButton(withTitle: "移動しない")
            alert.addButton(withTitle: "キャンセル")
            switch alert.runModal() {
            case .alertFirstButtonReturn:  movesExisting = true
            case .alertSecondButtonReturn: movesExisting = false
            default:                       return
            }
        }

        Preferences.setSaveDirectory(url, for: kind)
        refreshSaveDirectories()

        guard movesExisting else {
            store.reload()
            return
        }
        HUDPresenter.show("\(noun)を移動しています…", symbolName: "folder.fill")
        Task { @MainActor in
            let result = await store.moveItems(of: kind, to: destination)
            if result.failed > 0 {
                HUDPresenter.show("\(result.moved) 件を移動しました（\(result.failed) 件は移動できませんでした）",
                                  symbolName: "exclamationmark.triangle.fill", duration: 2.4)
            } else {
                HUDPresenter.show("\(result.moved) 件を移動しました", symbolName: "checkmark.circle.fill")
            }
        }
    }

    private func refreshSaveDirectories() {
        imageSaveDirectory = HistoryStore.shared.imageDirectory
        videoSaveDirectory = HistoryStore.shared.videoDirectory
    }

    // MARK: 収録

    @Published var recordingQuality: RecordingQuality {
        didSet { Preferences.recordingQuality = recordingQuality }
    }

    @Published var recordingSound: RecordingSoundChoice {
        didSet { RecordingSoundChoice.current = recordingSound }
    }

    /// MicrophoneChoice の値（使わない／既定／機器の ID）。
    @Published var microphone: String {
        didSet { MicrophoneChoice.current = microphone }
    }

    @Published var showsCursorInRecording: Bool {
        didSet { Preferences.showsCursorInRecording = showsCursorInRecording }
    }

    @Published var recordingCountdown: Bool {
        didSet { Preferences.recordingCountdown = recordingCountdown }
    }

    let microphones = MicrophoneCapture.availableDevices()

    var recordingSizeEstimate: String {
        recordingQuality.sizeEstimateDescription(
            systemAudio: recordingSound != .none,
            microphone: microphone != MicrophoneChoice.off
        )
    }

    @Published var imageFormat: ImageFormat {
        didSet { Preferences.imageFormat = imageFormat }
    }

    @Published var jpegQuality: CGFloat {
        didSet { Preferences.jpegQuality = jpegQuality }
    }

    /// 他のアプリが同じキーを押さえていて登録できなかった場合に true。
    @Published var areaHotKeyFailed = false
    @Published var windowHotKeyFailed = false
    @Published var textHotKeyFailed = false
    @Published var recordingHotKeyFailed = false

    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            do {
                try LoginItemManager.setEnabled(launchAtLogin)
                loginItemMessage = message(for: LoginItemManager.state)
            } catch {
                // 失敗したらトグルを元に戻す。
                launchAtLogin = oldValue
                loginItemMessage = "登録できませんでした: \(error.localizedDescription)"
            }
        }
    }

    @Published var loginItemMessage: String?

    init() {
        launchAtLogin = LoginItemManager.state.isOn
        loginItemMessage = nil
        areaHotKey = Preferences.hotKey
        windowHotKey = Preferences.windowHotKey
        textHotKey = Preferences.textRecognitionHotKey
        recordingHotKey = Preferences.recordingHotKey
        afterCaptureAction = Preferences.afterCaptureAction
        addsShadowByDefault = Preferences.addsShadowByDefault
        roundsCornersByDefault = Preferences.roundsCornersByDefault
        closesEditorOnCopyOrSave = Preferences.closesEditorOnCopyOrSave
        historyRetention = Preferences.historyRetention
        videoHistoryRetention = Preferences.videoHistoryRetention
        recordingQuality = Preferences.recordingQuality
        recordingSound = RecordingSoundChoice.current
        microphone = MicrophoneChoice.current
        showsCursorInRecording = Preferences.showsCursorInRecording
        recordingCountdown = Preferences.recordingCountdown
        imageFormat = Preferences.imageFormat
        jpegQuality = Preferences.jpegQuality
        loginItemMessage = message(for: LoginItemManager.state)
    }

    /// 登録先が今のアプリと食い違っていれば、今の場所に更新する。
    func fixLoginItemPath() {
        try? LoginItemManager.refreshPath()
        loginItemMessage = message(for: LoginItemManager.state)
    }

    var loginItemNeedsPathFix: Bool {
        if case .pathMismatch = LoginItemManager.state { return true }
        return false
    }

    /// この画面にある設定をすべて既定値へ戻す。
    func resetToDefaults() {
        areaHotKey = .defaultAreaCapture
        windowHotKey = .defaultWindowCapture
        textHotKey = .defaultTextRecognition
        recordingHotKey = .defaultScreenRecording
        afterCaptureAction = .thumbnail
        addsShadowByDefault = false
        roundsCornersByDefault = false
        closesEditorOnCopyOrSave = true
        historyRetention = .default
        videoHistoryRetention = .defaultForVideo
        recordingQuality = .default
        recordingSound = .application
        microphone = MicrophoneChoice.off
        showsCursorInRecording = false
        recordingCountdown = true
        imageFormat = .png
        jpegQuality = 0.9
    }

    private func message(for state: LoginItemManager.State) -> String? {
        switch state {
        case .pathMismatch(let registered):
            return "登録されている場所が今のアプリと違います（\(registered)）。"
        case .enabled where !LoginItemManager.isInApplicationsFolder:
            return "アプリを別の場所へ移すと自動起動が外れます。/Applications に置いておくのが確実です。"
        case .enabled, .disabled:
            return nil
        }
    }
}

/// ホットキー録音フィールドを SwiftUI に載せる。
struct HotKeyRecorder: NSViewRepresentable {

    @Binding var combo: KeyCombo?

    func makeNSView(context: Context) -> HotKeyRecorderView {
        let view = HotKeyRecorderView()
        view.combo = combo
        view.onChange = { combo = $0 }
        return view
    }

    func updateNSView(_ nsView: HotKeyRecorderView, context: Context) {
        nsView.combo = combo
        nsView.onChange = { combo = $0 }
    }
}

struct SettingsView: View {

    @ObservedObject var model: SettingsModel

    /// 画面に収まりきらないときの高さ。nil なら中身に合わせて伸ばす（Form は高さを決めるとスクロールする）。
    var height: CGFloat?

    /// LabeledContent にカスタムビューを渡すと、macOS の Form 上ではラベルと中身が
    /// 縦に積まれてしまい行が 2 段になることがある。HStack で明示的に横並びにする。
    @ViewBuilder
    private func hotKeyRow(
        title: String,
        combo: Binding<KeyCombo?>,
        failed: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                HotKeyRecorder(combo: combo)
                    .frame(width: 170, height: 24)
                    .help("クリックしてからキーを押すと変更できます。Delete で割り当てなし、Esc でキャンセル")
            }

            if failed {
                Label(
                    "他の操作や他のアプリが使用中のため登録できませんでした",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
    }

    /// 保存先の 1 行。今の場所（短く省略）と、変更・Finder で表示・既定に戻すボタン。
    private func saveDirectoryRow(title: String, kind: HistoryItemKind) -> some View {
        let url = model.saveDirectory(for: kind)
        return HStack(spacing: 6) {
            Text(title)
            Spacer(minLength: 8)
            Text((url.path as NSString).abbreviatingWithTildeInPath)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(url.path)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Finder で開く")
            Button("変更…") { model.chooseSaveDirectory(for: kind) }
            if !model.usesDefaultSaveDirectory(for: kind) {
                Button("既定に戻す") { model.resetSaveDirectory(for: kind) }
            }
        }
    }

    var body: some View {
        Form {
            Section {
                hotKeyRow(
                    title: HotKeyAction.areaCapture.title,
                    combo: $model.areaHotKey,
                    failed: model.areaHotKeyFailed
                )
                hotKeyRow(
                    title: HotKeyAction.windowCapture.title,
                    combo: $model.windowHotKey,
                    failed: model.windowHotKeyFailed
                )
                hotKeyRow(
                    title: HotKeyAction.textRecognition.title,
                    combo: $model.textHotKey,
                    failed: model.textHotKeyFailed
                )
                hotKeyRow(
                    title: HotKeyAction.screenRecording.title,
                    combo: $model.recordingHotKey,
                    failed: model.recordingHotKeyFailed
                )
            } header: {
                Text("グローバルホットキー")
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("撮影後", selection: $model.afterCaptureAction) {
                        ForEach(AfterCaptureAction.allCases) { action in
                            Text(action.title).tag(action)
                        }
                    }
                    Text(model.afterCaptureAction.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("最初から影を付ける", isOn: $model.addsShadowByDefault)
                    Toggle("最初から角を丸める", isOn: $model.roundsCornersByDefault)
                    Text("どちらもオフのままでも、エディタで S / R キーを押せばその 1 枚だけ切り替えられます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("コピー・保存したらウィンドウを閉じる", isOn: $model.closesEditorOnCopyOrSave)
                    Text("オフにすると、コピーや保存のあともエディタのウィンドウが開いたままになります。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 10)
            } header: {
                Text("撮影")
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("画質", selection: $model.recordingQuality) {
                        ForEach(RecordingQuality.allCases) { quality in
                            Text(quality.title).tag(quality)
                        }
                    }
                    Text("\(model.recordingQuality.detail)\n\(model.recordingSizeEstimate)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Picker("音", selection: $model.recordingSound) {
                        ForEach(RecordingSoundChoice.allCases) { choice in
                            Text(choice.title(appName: nil)).tag(choice)
                        }
                    }
                    Text("Mac のスピーカーから出る音です。「収録するアプリの音だけ」なら、他のアプリの通知音などは入りません。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Picker("マイク", selection: $model.microphone) {
                    MicrophonePickerItems(devices: model.microphones, selection: model.microphone)
                }

                Toggle("マウスポインタを写す", isOn: $model.showsCursorInRecording)

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("開始前に 3 秒カウントダウンする", isOn: $model.recordingCountdown)
                    Text("音・マイク・マウスポインタ・画質は、収録前に出るバーでもその都度切り替えられます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("収録")
            }

            Section {
                Picker("画像の保持期間", selection: $model.historyRetention) {
                    ForEach(HistoryRetention.allCases) { retention in
                        Text(retention.title).tag(retention)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Picker("動画の保持期間", selection: $model.videoHistoryRetention) {
                        ForEach(HistoryRetention.allCases) { retention in
                            Text(retention.title).tag(retention)
                        }
                    }
                    Text("期間を過ぎたものは、自動でディスクから削除されます（起動時・設定変更時と、起動中は 1 時間ごと）。動画を「保存しない」にした場合、収録した動画はムービーフォルダの Shotter に保存されます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                saveDirectoryRow(title: "画像の保存先", kind: .image)
                VStack(alignment: .leading, spacing: 4) {
                    saveDirectoryRow(title: "動画の保存先", kind: .video)
                    Text("選んだフォルダが見つからないとき（外付けディスクを外したときなど）は、既定の場所に保存します。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("履歴")
            }

            Section {
                Toggle("Mac の起動時に Shotter を自動起動する", isOn: $model.launchAtLogin)

                if let loginItemMessage = model.loginItemMessage {
                    HStack(alignment: .top, spacing: 6) {
                        Text(loginItemMessage)
                            .font(.caption)
                            .foregroundStyle(model.loginItemNeedsPathFix ? .orange : .secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if model.loginItemNeedsPathFix {
                            Button("今の場所に更新") { model.fixLoginItemPath() }
                                .buttonStyle(.link)
                                .font(.caption)
                        }
                    }
                }
            } header: {
                Text("起動")
            }

            Section {
                Picker("既定の形式", selection: $model.imageFormat) {
                    ForEach(ImageFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }

                LabeledContent("JPEG 画質") {
                    HStack {
                        Slider(value: $model.jpegQuality, in: 0.3...1.0)
                            .frame(width: 150)
                        Text("\(Int(model.jpegQuality * 100))%")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }
                }
                .disabled(model.imageFormat != .jpeg)
            } header: {
                Text("保存")
            }

            Section {
                HStack {
                    Spacer()
                    Button("デフォルトに戻す") { showsResetConfirmation = true }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: height)
        .fixedSize(horizontal: false, vertical: height == nil)
        .confirmationDialog(
            "すべての設定をデフォルトに戻しますか？",
            isPresented: $showsResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("デフォルトに戻す", role: .destructive) { model.resetToDefaults() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("ホットキーや撮影後の挙動など、この画面の設定がすべて既定値に戻ります（保存先はそのままです）。")
        }
    }

    @State private var showsResetConfirmation = false
}

@MainActor
final class SettingsWindowController: NSWindowController {

    private static var shared: SettingsWindowController?

    static func show() {
        if let existing = shared {
            NSApp.activate(ignoringOtherApps: true)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        let controller = SettingsWindowController()
        shared = controller

        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init() {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 460, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Shotter 設定"
        window.isReleasedWhenClosed = false

        super.init(window: window)
        // 閉じたら作り直す。収録前のバーなど、他の場所で変えた設定を次に開いたとき読み直すため。
        window.delegate = self

        let model = SettingsModel()
        let hosting = NSHostingView(rootView: SettingsView(model: model))

        // 項目が増えて縦に長くなったので、画面に入りきらなければ高さを抑えてスクロールさせる。
        let naturalSize = hosting.fittingSize
        let available = (NSScreen.main?.visibleFrame.height ?? naturalSize.height) - 60
        if naturalSize.height > available {
            hosting.rootView = SettingsView(model: model, height: available)
            window.setContentSize(CGSize(width: naturalSize.width, height: available))
        } else {
            window.setContentSize(naturalSize)
        }
        window.contentView = hosting
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

}

extension SettingsWindowController: NSWindowDelegate {

    func windowWillClose(_ notification: Notification) {
        Self.shared = nil
    }
}
