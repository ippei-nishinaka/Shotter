import AppKit
import SwiftUI

/// 設定の実体。UserDefaults との読み書きをまとめ、変更をすぐ反映させる。
@MainActor
final class SettingsModel: ObservableObject {

    @Published var areaHotKey: KeyCombo? {
        didSet {
            guard areaHotKey != oldValue else { return }
            if let areaHotKey { Preferences.hotKey = areaHotKey }
            areaHotKeyFailed = !CaptureCoordinator.shared.applyHotKey(areaHotKey, for: .areaCapture)
        }
    }

    @Published var windowHotKey: KeyCombo? {
        didSet {
            guard windowHotKey != oldValue else { return }
            if let windowHotKey { Preferences.windowHotKey = windowHotKey }
            windowHotKeyFailed = !CaptureCoordinator.shared.applyHotKey(windowHotKey, for: .windowCapture)
        }
    }

    @Published var textHotKey: KeyCombo? {
        didSet {
            guard textHotKey != oldValue else { return }
            if let textHotKey { Preferences.textRecognitionHotKey = textHotKey }
            textHotKeyFailed = !CaptureCoordinator.shared.applyHotKey(textHotKey, for: .textRecognition)
        }
    }

    @Published var afterCaptureAction: AfterCaptureAction {
        didSet { Preferences.afterCaptureAction = afterCaptureAction }
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
        afterCaptureAction = Preferences.afterCaptureAction
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

    @ViewBuilder
    private func hotKeyRow(
        title: String,
        combo: Binding<KeyCombo?>,
        failed: Bool
    ) -> some View {
        LabeledContent(title) {
            VStack(alignment: .leading, spacing: 4) {
                HotKeyRecorder(combo: combo)
                    .frame(width: 170, height: 24)

                if failed {
                    Label(
                        "他のアプリが使用中のため登録できませんでした",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
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

                Text("フィールドをクリックしてキーを押します。Delete でクリア、Esc で取り消し。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            } header: {
                Text("撮影")
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
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
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

        let hosting = NSHostingView(rootView: SettingsView(model: SettingsModel()))
        window.contentView = hosting
        window.setContentSize(hosting.fittingSize)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        window?.delegate = self
    }
}

extension SettingsWindowController: NSWindowDelegate {

    func windowWillClose(_ notification: Notification) {
        Self.shared = nil
    }
}
