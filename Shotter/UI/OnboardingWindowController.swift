import AppKit
import SwiftUI

/// 画面収録の権限の状態を監視するモデル。
@MainActor
final class ScreenRecordingPermissionModel: ObservableObject {

    @Published private(set) var isGranted: Bool

    /// 権限を許可した後は macOS の仕様でアプリの再起動が要る。
    @Published private(set) var needsRelaunch = false

    private let service = ScreenCaptureService()
    private var pollingTask: Task<Void, Never>?
    private let initialState: Bool

    init() {
        let granted = CGPreflightScreenCaptureAccess()
        isGranted = granted
        initialState = granted
    }

    /// システム設定で許可されたのを検知するため、開いている間だけ定期的に確認する。
    func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }

                let granted = CGPreflightScreenCaptureAccess()
                if granted != self.isGranted {
                    self.isGranted = granted
                }
                // 起動後に許可された場合、実際に使えるようになるのは再起動後。
                if granted, !self.initialState {
                    self.needsRelaunch = true
                }
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// 未許可なら、システム標準の権限ダイアログを一度だけ出す。
    func requestAccess() {
        service.requestScreenRecordingPermission()
    }

    func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    /// 権限を反映させるためにアプリを再起動する。
    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true

        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }
}

struct OnboardingView: View {

    @ObservedObject var model: ScreenRecordingPermissionModel
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 32))
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Shotter へようこそ")
                        .font(.title2.bold())
                    Text("メニューバーから範囲を選んで撮影し、その場で注釈を付けられます。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("画面収録の許可が必要です")
                    .font(.headline)

                Text("""
                スクリーンショットを撮影するには、macOS の「画面収録」の許可が必要です。\
                システム設定 > プライバシーとセキュリティ > 画面収録 の一覧で Shotter を有効にしてください。
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                statusRow
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("使い方")
                    .font(.headline)
                Label("メニューバーの 📷 →「範囲を選択してキャプチャ」", systemImage: "1.circle")
                Label(
                    "ホットキー \(Preferences.hotKey.displayString) で範囲、"
                        + "\(Preferences.windowHotKey.displayString) でウィンドウ（設定で変更可）",
                    systemImage: "2.circle"
                )
                Label("ドラッグで範囲選択、Esc でキャンセル", systemImage: "3.circle")
            }
            .font(.callout)

            HStack {
                Spacer()
                if model.needsRelaunch {
                    Button("Shotter を再起動") { model.relaunch() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("はじめる", action: onDismiss)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear { model.startPolling() }
        .onDisappear { model.stopPolling() }
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 10) {
            if model.isGranted {
                Label("許可済み", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if model.needsRelaunch {
                    Text("反映にはアプリの再起動が必要です")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Label("未許可", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)

                Button("許可をリクエスト") { model.requestAccess() }
                Button("システム設定を開く") { model.openSystemSettings() }
            }
        }
        .padding(.top, 4)
    }
}

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {

    private static var shared: OnboardingWindowController?

    static func show() {
        if let existing = shared {
            NSApp.activate(ignoringOtherApps: true)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        let controller = OnboardingWindowController()
        shared = controller

        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// 初回起動時、または権限が未許可のときだけ出す。
    static func showIfNeeded() {
        guard !Preferences.hasCompletedOnboarding || !CGPreflightScreenCaptureAccess() else { return }
        show()
    }

    private init() {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 520, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Shotter"
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self

        let hosting = NSHostingView(
            rootView: OnboardingView(
                model: ScreenRecordingPermissionModel(),
                onDismiss: { [weak self] in self?.close() }
            )
        )
        window.contentView = hosting
        window.setContentSize(hosting.fittingSize)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        Preferences.hasCompletedOnboarding = true
        Self.shared = nil
    }
}
