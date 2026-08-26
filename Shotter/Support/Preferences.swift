import AppKit

/// UserDefaults に置く設定値。ステップ6の設定画面でも参照する。
@MainActor
enum Preferences {

    private enum Key {
        static let lastSaveDirectory = "lastSaveDirectory"
        static let imageFormat = "imageFormat"
        static let jpegQuality = "jpegQuality"
        static let hotKey = "captureHotKey"
        static let windowHotKey = "windowCaptureHotKey"
        static let textHotKey = "textRecognitionHotKey"
        static let afterCapture = "afterCaptureAction"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let addsShadowByDefault = "addsShadowByDefault"
        static let roundsCornersByDefault = "roundsCornersByDefault"
        static let historyRetention = "historyRetentionDays"
    }

    private static var defaults: UserDefaults { .standard }

    /// 前回の保存先。次回の保存ダイアログの初期位置に使う。
    static var lastSaveDirectory: URL? {
        get {
            guard let path = defaults.string(forKey: Key.lastSaveDirectory) else { return nil }
            let url = URL(fileURLWithPath: path)
            return FileManager.default.fileExists(atPath: path) ? url : nil
        }
        set {
            defaults.set(newValue?.path, forKey: Key.lastSaveDirectory)
        }
    }

    static var imageFormat: ImageFormat {
        get {
            guard let raw = defaults.string(forKey: Key.imageFormat) else { return .png }
            return ImageFormat(rawValue: raw) ?? .png
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.imageFormat)
        }
    }

    /// 撮影した画像に最初から影を付けるか（既定は OFF）。
    /// エディタの S キーによる切り替えはその 1 枚だけに効き、ここは変えない。
    static var addsShadowByDefault: Bool {
        get { defaults.bool(forKey: Key.addsShadowByDefault) }
        set { defaults.set(newValue, forKey: Key.addsShadowByDefault) }
    }

    /// 撮影した画像の角を最初から丸めるか（既定は OFF）。
    static var roundsCornersByDefault: Bool {
        get { defaults.bool(forKey: Key.roundsCornersByDefault) }
        set { defaults.set(newValue, forKey: Key.roundsCornersByDefault) }
    }

    /// 履歴の保持期間（既定は 2 週間）。
    static var historyRetention: HistoryRetention {
        get {
            guard let stored = defaults.object(forKey: Key.historyRetention) as? Int,
                  let retention = HistoryRetention(rawValue: stored)
            else { return .default }
            return retention
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.historyRetention)
        }
    }

    /// 初回起動時の案内を表示済みか。
    static var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: Key.hasCompletedOnboarding) }
        set { defaults.set(newValue, forKey: Key.hasCompletedOnboarding) }
    }

    /// 範囲キャプチャを開始するグローバルホットキー。
    static var hotKey: KeyCombo {
        get { combo(forKey: Key.hotKey, default: .defaultAreaCapture) }
        set { defaults.set(newValue.storageString, forKey: Key.hotKey) }
    }

    /// ウィンドウキャプチャを開始するグローバルホットキー。
    static var windowHotKey: KeyCombo {
        get { combo(forKey: Key.windowHotKey, default: .defaultWindowCapture) }
        set { defaults.set(newValue.storageString, forKey: Key.windowHotKey) }
    }

    /// 文字を読み取ってコピーするグローバルホットキー。
    static var textRecognitionHotKey: KeyCombo {
        get { combo(forKey: Key.textHotKey, default: .defaultTextRecognition) }
        set { defaults.set(newValue.storageString, forKey: Key.textHotKey) }
    }

    private static func combo(forKey key: String, default fallback: KeyCombo) -> KeyCombo {
        guard let raw = defaults.string(forKey: key),
              let combo = KeyCombo(storageString: raw)
        else { return fallback }
        return combo
    }

    static var afterCaptureAction: AfterCaptureAction {
        get {
            guard let raw = defaults.string(forKey: Key.afterCapture) else { return .thumbnail }
            return AfterCaptureAction(rawValue: raw) ?? .thumbnail
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.afterCapture)
        }
    }

    static var jpegQuality: CGFloat {
        get {
            let value = defaults.object(forKey: Key.jpegQuality) as? Double
            return CGFloat(value ?? 0.9)
        }
        set {
            defaults.set(Double(newValue), forKey: Key.jpegQuality)
        }
    }
}

/// 撮影直後の挙動。
enum AfterCaptureAction: String, CaseIterable, Identifiable {
    /// コピーしたうえでサムネイルを出し、クリックされたらエディタを開く（既定）。
    case thumbnail
    case openEditor
    case copyOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .thumbnail:  return "コピーしてサムネイルを表示"
        case .openEditor: return "すぐに注釈エディタを開く"
        case .copyOnly:   return "クリップボードにコピーだけする"
        }
    }

    var detail: String {
        switch self {
        case .thumbnail:  return "画面の右下に出るサムネイルをクリックすると注釈エディタが開きます。"
        case .openEditor: return "撮影するたびに注釈エディタが開きます。"
        case .copyOnly:   return "エディタもサムネイルも出さず、コピーだけして終わります。"
        }
    }
}
