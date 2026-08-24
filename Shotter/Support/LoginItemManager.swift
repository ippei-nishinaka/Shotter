import AppKit

/// ログイン時の自動起動。
///
/// macOS 13 以降の `SMAppService.mainApp` は署名や設置場所の条件が厳しく、
/// 個人ビルド（ad-hoc / 自己署名）では `.notFound` になって使えない。
/// そのため `~/Library/LaunchAgents` に LaunchAgent の plist を置く方式にしている。
/// この方式なら置き場所を問わず動作し、ユーザー領域だけで完結する。
@MainActor
enum LoginItemManager {

    private static let label = "com.ippei.Shotter.launchatlogin"

    enum State: Equatable {
        /// 登録済みで、今のアプリの場所を指している。
        case enabled
        case disabled
        /// 登録済みだが、別の場所のアプリを指している（アプリを移動した後など）。
        case pathMismatch(registered: String)

        var isOn: Bool { self != .disabled }
    }

    static var plistURL: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// 起動対象の実行ファイル。
    private static var executablePath: String {
        Bundle.main.executableURL?.path
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/Shotter").path
    }

    static var state: State {
        guard let registered = registeredExecutablePath() else { return .disabled }
        return registered == executablePath ? .enabled : .pathMismatch(registered: registered)
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try writePlist()
        } else {
            try removePlist()
        }
    }

    /// 登録済みのパスを今のアプリの場所に更新する。
    static func refreshPath() throws {
        try writePlist()
    }

    static func openLoginItemsSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    /// アプリが `/Applications` の外にあると、移動やビルドのやり直しで登録が外れやすい。
    static var isInApplicationsFolder: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications/")
    }

    // MARK: - Private

    private static func registeredExecutablePath() -> String? {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
              ) as? [String: Any],
              let arguments = plist["ProgramArguments"] as? [String]
        else { return nil }

        return arguments.first
    }

    private static func writePlist() throws {
        let directory = plistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            // ログイン時に 1 回起動するだけ。終了しても復活させない。
            "KeepAlive": false,
        ]

        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: plistURL, options: .atomic)
    }

    private static func removePlist() throws {
        guard FileManager.default.fileExists(atPath: plistURL.path) else { return }
        try FileManager.default.removeItem(at: plistURL)
    }
}
