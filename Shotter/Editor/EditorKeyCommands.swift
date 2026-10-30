import AppKit

/// 静止画・動画のエディタで共通のキー操作（アンドゥ・削除・選択解除・ツールの切り替え）。
@MainActor
enum EditorKeyCommands {

    /// - Parameter extraCharacter: 修飾キーなしで押された文字のうち、エディタ固有のもの（静止画の S / R など）。
    ///   処理したら true を返す。ツールの切り替えより先に聞く。
    /// - Returns: 処理したら true（イベントを飲み込む）。
    static func handle(
        _ event: NSEvent,
        store: AnnotationStore,
        canvas: AnnotationCanvasView?,
        extraCharacter: (Character) -> Bool = { _ in false }
    ) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCommand = flags.contains(.command)
        let hasControl = flags.contains(.control)
        let hasShift = flags.contains(.shift)
        let hasOption = flags.contains(.option)

        // 6 = Z, 16 = Y
        if (hasCommand || hasControl), !hasOption {
            switch event.keyCode {
            case 6:
                if hasShift { store.redo() } else { store.undo() }
                return true
            case 16:
                store.redo()
                return true
            default:
                // ⌘S / ⇧⌘C などはメニューに任せる。
                return false
            }
        }

        guard !hasCommand, !hasControl, !hasOption else { return false }

        switch event.keyCode {
        case 51, 117: // delete / forward delete
            store.deleteSelection()
            return true
        case 53: // escape
            store.select(nil)
            return true
        default:
            break
        }

        guard let character = event.charactersIgnoringModifiers?.lowercased().first else {
            return false
        }

        if extraCharacter(character) { return true }

        guard let tool = AnnotationTool.allCases.first(where: { $0.shortcutKey == character }) else {
            return false
        }

        store.tool = tool
        if let canvas { canvas.window?.invalidateCursorRects(for: canvas) }
        return true
    }
}
