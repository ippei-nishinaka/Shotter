import AppKit
import Carbon.HIToolbox

/// グローバルホットキーの組み合わせ。
/// `modifiers` は Carbon の修飾キーフラグ（cmdKey / shiftKey / optionKey / controlKey）。
struct KeyCombo: Equatable {

    var keyCode: UInt32
    var modifiers: UInt32

    /// 範囲キャプチャの既定値: ⌃⇧A。macOS 標準のスクリーンショット（⌘⇧3/4/5）と競合しない。
    static let defaultAreaCapture = KeyCombo(
        keyCode: UInt32(kVK_ANSI_A),
        modifiers: UInt32(controlKey | shiftKey)
    )

    /// ウィンドウキャプチャの既定値: ⌃⇧W。
    static let defaultWindowCapture = KeyCombo(
        keyCode: UInt32(kVK_ANSI_W),
        modifiers: UInt32(controlKey | shiftKey)
    )

    /// 文字認識の既定値: ⌃⇧O（OCR の O）。
    static let defaultTextRecognition = KeyCombo(
        keyCode: UInt32(kVK_ANSI_O),
        modifiers: UInt32(controlKey | shiftKey)
    )

    // MARK: - NSEvent との相互変換

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init?(event: NSEvent) {
        let carbonModifiers = Self.carbonModifiers(from: event.modifierFlags)
        // 修飾キーなしのホットキーは他アプリを壊しかねないので受け付けない。
        guard carbonModifiers != 0 else { return nil }

        self.keyCode = UInt32(event.keyCode)
        self.modifiers = carbonModifiers
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: Int = 0
        if flags.contains(.command) { result |= cmdKey }
        if flags.contains(.shift) { result |= shiftKey }
        if flags.contains(.option) { result |= optionKey }
        if flags.contains(.control) { result |= controlKey }
        return UInt32(result)
    }

    // MARK: - 表示

    /// 「⌃⇧A」のような表示用文字列。
    var displayString: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + Self.keyLabel(for: keyCode)
    }

    /// 仮想キーコード → 表示ラベル。
    static func keyLabel(for keyCode: UInt32) -> String {
        if let special = specialKeyLabels[Int(keyCode)] { return special }
        if let letter = letterKeyLabels[Int(keyCode)] { return letter }
        return "Key \(keyCode)"
    }

    private static let letterKeyLabels: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=",
        kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Backslash: "\\", kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'",
        kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
        kVK_ANSI_Grave: "`",
    ]

    private static let specialKeyLabels: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    // MARK: - 永続化

    /// "modifiers:keyCode" 形式で UserDefaults に入れる。
    var storageString: String { "\(modifiers):\(keyCode)" }

    init?(storageString: String) {
        let parts = storageString.split(separator: ":")
        guard parts.count == 2,
              let modifiers = UInt32(parts[0]),
              let keyCode = UInt32(parts[1])
        else { return nil }

        self.modifiers = modifiers
        self.keyCode = keyCode
    }
}
