import AppKit

/// クリックするとキー入力待ちになり、押されたキーの組み合わせを記録するフィールド。
@MainActor
final class HotKeyRecorderView: NSView {

    var combo: KeyCombo? {
        didSet { needsDisplay = true }
    }

    /// 新しい組み合わせが確定したときに呼ばれる。nil はクリア。
    var onChange: ((KeyCombo?) -> Void)?

    private var isRecording = false {
        didSet { needsDisplay = true }
    }

    override var acceptsFirstResponder: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 160, height: 24)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    // MARK: - 入力

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        // 53 = escape（キャンセル）、51 = delete（クリア）
        switch event.keyCode {
        case 53:
            isRecording = false
            window?.makeFirstResponder(nil)
            return
        case 51:
            combo = nil
            onChange?(nil)
            isRecording = false
            window?.makeFirstResponder(nil)
            return
        default:
            break
        }

        guard let newCombo = KeyCombo(event: event) else {
            // 修飾キーなしは受け付けない。
            NSSound.beep()
            return
        }

        combo = newCombo
        onChange?(newCombo)
        isRecording = false
        window?.makeFirstResponder(nil)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // 録音中は ⌘S などのメニューショートカットに横取りさせない。
        guard isRecording else { return false }
        keyDown(with: event)
        return true
    }

    // MARK: - 描画

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5)

        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.controlBackgroundColor).setFill()
        path.fill()

        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isRecording ? 2 : 1
        path.stroke()

        let text: String
        let color: NSColor
        if isRecording {
            text = "キーを押してください…"
            color = .secondaryLabelColor
        } else if let combo {
            text = combo.displayString
            color = .labelColor
        } else {
            text = "クリックして設定"
            color = .secondaryLabelColor
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: isRecording ? .regular : .medium),
            .foregroundColor: color,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
            withAttributes: attributes
        )
    }
}
