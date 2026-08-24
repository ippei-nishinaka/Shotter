import AppKit

/// LSUIElement アプリなのでメニューバーには表示されないが、
/// メインメニューを組んでおくと ⌘Z / ⌘C / ⌘W などのキーボードショートカットが有効になる。
enum MainMenu {

    static func build() -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(applicationMenuItem())
        mainMenu.addItem(fileMenuItem())
        mainMenu.addItem(editMenuItem())
        mainMenu.addItem(windowMenuItem())
        return mainMenu
    }

    private static func applicationMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Shotter")
        menu.addItem(
            withTitle: "Shotter を終了",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        item.submenu = menu
        return item
    }

    private static func fileMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "ファイル")

        menu.addItem(
            withTitle: "保存…",
            action: #selector(EditorWindowController.saveDocument(_:)),
            keyEquivalent: "s"
        )

        // ⌘C。テキスト入力中は編集メニューの copy: に譲るため、
        // EditorWindowController 側の validateMenuItem で無効化している。
        menu.addItem(
            withTitle: "注釈込みでコピー",
            action: #selector(EditorWindowController.copyFlattenedImage(_:)),
            keyEquivalent: "c"
        )

        item.submenu = menu
        return item
    }

    private static func editMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "編集")

        menu.addItem(withTitle: "取り消す", action: #selector(EditorWindowController.undo(_:)), keyEquivalent: "z")

        let redo = NSMenuItem(title: "やり直す", action: #selector(EditorWindowController.redo(_:)), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)

        menu.addItem(.separator())
        menu.addItem(withTitle: "切り取り", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "コピー", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "ペースト", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "すべてを選択", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(.separator())
        menu.addItem(withTitle: "削除", action: #selector(NSText.delete(_:)), keyEquivalent: "\u{8}")

        item.submenu = menu
        return item
    }

    private static func windowMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "ウインドウ")
        menu.addItem(withTitle: "しまう", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "閉じる", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        item.submenu = menu
        return item
    }
}
