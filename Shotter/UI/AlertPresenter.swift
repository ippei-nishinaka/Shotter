import AppKit

/// 権限の案内やエラーのダイアログ表示。
@MainActor
enum AlertPresenter {

    static func showError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "キャプチャできませんでした"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
