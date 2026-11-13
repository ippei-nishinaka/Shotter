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
        static let lineWidth = "annotationLineWidth"
        static let fontSize = "annotationFontSize"
        static let shadowStrength = "annotationShadowStrength"
        static let cornerRoundness = "annotationCornerRoundness"
        static let pixelateIntensity = "annotationPixelateIntensity"
        static let closesEditorOnCopyOrSave = "closesEditorOnCopyOrSave"
        static let recordingHotKey = "screenRecordingHotKey"
        static let recordingQuality = "recordingQuality"
        static let recordsSystemAudio = "recordsSystemAudio"
        static let systemAudioScope = "systemAudioScope"
        static let recordsMicrophone = "recordsMicrophone"
        static let microphoneDeviceID = "microphoneDeviceID"
        static let showsCursorInRecording = "showsCursorInRecording"
        static let recordingCountdown = "recordingCountdown"
        static let videoHistoryRetention = "videoHistoryRetentionDays"
        static let imageSaveDirectory = "imageSaveDirectory"
        static let videoSaveDirectory = "videoSaveDirectory"
        static let gifMaxWidth = "gifMaxWidth"
        static let gifFramesPerSecond = "gifFramesPerSecond"
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

    /// コピー／保存を押したら注釈エディタのウィンドウを閉じるか（既定は ON）。
    static var closesEditorOnCopyOrSave: Bool {
        get { defaults.object(forKey: Key.closesEditorOnCopyOrSave) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.closesEditorOnCopyOrSave) }
    }

    /// 履歴の保持期間（既定は自動削除しない）。
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

    /// 動画の履歴の保持期間（既定は自動削除しない）。1 本で数 GB になるので画像とは別に持つ。
    static var videoHistoryRetention: HistoryRetention {
        get {
            guard let stored = defaults.object(forKey: Key.videoHistoryRetention) as? Int,
                  let retention = HistoryRetention(rawValue: stored)
            else { return .defaultForVideo }
            return retention
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.videoHistoryRetention)
        }
    }

    /// 画像・動画の保存先。nil なら既定の場所（~/Library/Application Support/Shotter/History）。
    static func saveDirectory(for kind: HistoryItemKind) -> URL? {
        let key = kind == .image ? Key.imageSaveDirectory : Key.videoSaveDirectory
        guard let path = defaults.string(forKey: key) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func setSaveDirectory(_ url: URL?, for kind: HistoryItemKind) {
        let key = kind == .image ? Key.imageSaveDirectory : Key.videoSaveDirectory
        defaults.set(url?.path, forKey: key)
    }

    /// 前回 GIF を書き出したときの設定。次回も同じものを初期値にする。
    static var gifExportOptions: GIFExportOptions {
        get {
            var options = GIFExportOptions()
            if let width = defaults.object(forKey: Key.gifMaxWidth) as? Int { options.maxWidth = width }
            if let fps = defaults.object(forKey: Key.gifFramesPerSecond) as? Int { options.framesPerSecond = fps }
            return options
        }
        set {
            defaults.set(newValue.maxWidth, forKey: Key.gifMaxWidth)
            defaults.set(newValue.framesPerSecond, forKey: Key.gifFramesPerSecond)
        }
    }

    /// 初回起動時の案内を表示済みか。
    static var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: Key.hasCompletedOnboarding) }
        set { defaults.set(newValue, forKey: Key.hasCompletedOnboarding) }
    }

    /// 範囲キャプチャを開始するグローバルホットキー。nil は「割り当てなし」。
    static var hotKey: KeyCombo? {
        get { combo(forKey: Key.hotKey, default: .defaultAreaCapture) }
        set { setCombo(newValue, forKey: Key.hotKey) }
    }

    /// ウィンドウキャプチャを開始するグローバルホットキー。
    static var windowHotKey: KeyCombo? {
        get { combo(forKey: Key.windowHotKey, default: .defaultWindowCapture) }
        set { setCombo(newValue, forKey: Key.windowHotKey) }
    }

    /// 文字を読み取ってコピーするグローバルホットキー。
    static var textRecognitionHotKey: KeyCombo? {
        get { combo(forKey: Key.textHotKey, default: .defaultTextRecognition) }
        set { setCombo(newValue, forKey: Key.textHotKey) }
    }

    /// ウィンドウ収録を開始／停止するグローバルホットキー。
    static var recordingHotKey: KeyCombo? {
        get { combo(forKey: Key.recordingHotKey, default: .defaultScreenRecording) }
        set { setCombo(newValue, forKey: Key.recordingHotKey) }
    }

    /// 「割り当てなし」を覚えておくための値。未設定（＝既定のキーを使う）と区別する。
    private static let noHotKey = "none"

    private static func combo(forKey key: String, default fallback: KeyCombo) -> KeyCombo? {
        guard let raw = defaults.string(forKey: key) else { return fallback }
        if raw == noHotKey { return nil }
        return KeyCombo(storageString: raw) ?? fallback
    }

    private static func setCombo(_ combo: KeyCombo?, forKey key: String) {
        defaults.set(combo?.storageString ?? noHotKey, forKey: key)
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

    /// 注釈の線の太さ。最後に変えた値を次回も使う。
    static var lineWidth: CGFloat {
        get { CGFloat(defaults.object(forKey: Key.lineWidth) as? Double ?? 4) }
        set { defaults.set(Double(newValue), forKey: Key.lineWidth) }
    }

    /// テキスト・ナンバリングの文字サイズ。最後に変えた値を次回も使う。
    static var fontSize: CGFloat {
        get { CGFloat(defaults.object(forKey: Key.fontSize) as? Double ?? 24) }
        set { defaults.set(Double(newValue), forKey: Key.fontSize) }
    }

    /// 影の強さ。最後に変えた値を次回も使う。
    static var shadowStrength: CGFloat {
        get { CGFloat(defaults.object(forKey: Key.shadowStrength) as? Double ?? 1) }
        set { defaults.set(Double(newValue), forKey: Key.shadowStrength) }
    }

    /// 角の丸さ。最後に変えた値を次回も使う。
    static var cornerRoundness: CGFloat {
        get { CGFloat(defaults.object(forKey: Key.cornerRoundness) as? Double ?? Double(ImageMask.roundedCornerRadius)) }
        set { defaults.set(Double(newValue), forKey: Key.cornerRoundness) }
    }

    /// モザイク／ぼかしの強さ。最後に変えた値を次回も使う。
    static var pixelateIntensity: CGFloat {
        get { CGFloat(defaults.object(forKey: Key.pixelateIntensity) as? Double ?? 1) }
        set { defaults.set(Double(newValue), forKey: Key.pixelateIntensity) }
    }

    // MARK: - 収録

    static var recordingQuality: RecordingQuality {
        get {
            guard let raw = defaults.string(forKey: Key.recordingQuality) else { return .default }
            return RecordingQuality(rawValue: raw) ?? .default
        }
        set { defaults.set(newValue.rawValue, forKey: Key.recordingQuality) }
    }

    /// システム音声を録るか（既定は ON）。
    static var recordsSystemAudio: Bool {
        get { defaults.object(forKey: Key.recordsSystemAudio) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.recordsSystemAudio) }
    }

    /// システム音声を拾う範囲（既定は収録するアプリの音だけ）。
    static var systemAudioScope: SystemAudioScope {
        get {
            guard let raw = defaults.string(forKey: Key.systemAudioScope) else { return .default }
            return SystemAudioScope(rawValue: raw) ?? .default
        }
        set { defaults.set(newValue.rawValue, forKey: Key.systemAudioScope) }
    }

    /// マイクの音を録るか（既定は OFF）。
    static var recordsMicrophone: Bool {
        get { defaults.bool(forKey: Key.recordsMicrophone) }
        set { defaults.set(newValue, forKey: Key.recordsMicrophone) }
    }

    /// 使うマイク。nil ならシステムの既定。
    static var microphoneDeviceID: String? {
        get { defaults.string(forKey: Key.microphoneDeviceID) }
        set { defaults.set(newValue, forKey: Key.microphoneDeviceID) }
    }

    /// 収録にマウスポインタを写すか（既定は OFF）。
    static var showsCursorInRecording: Bool {
        get { defaults.bool(forKey: Key.showsCursorInRecording) }
        set { defaults.set(newValue, forKey: Key.showsCursorInRecording) }
    }

    /// 収録開始前に 3 秒のカウントダウンを出すか（既定は ON）。
    static var recordingCountdown: Bool {
        get { defaults.object(forKey: Key.recordingCountdown) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.recordingCountdown) }
    }

    static var recordingOptions: RecordingOptions {
        RecordingOptions(
            quality: recordingQuality,
            recordsSystemAudio: recordsSystemAudio,
            systemAudioScope: systemAudioScope,
            recordsMicrophone: recordsMicrophone,
            microphoneDeviceID: microphoneDeviceID,
            showsCursor: showsCursorInRecording
        )
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
        case .thumbnail:  return "クリップボードに入れてサムネイルを表示"
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
