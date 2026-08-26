import AppKit
import SwiftUI

/// 撮影後の注釈編集ウィンドウ。
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {

    /// 開いているウィンドウを保持しておく（NSWindowController は誰かが持たないと解放される）。
    private static var openControllers: [EditorWindowController] = []

    let store: AnnotationStore

    /// ツールバー（SwiftUI）をクリックするとキャンバスからフォーカスが外れてしまうため、
    /// キー入力はファーストレスポンダに依存せずウィンドウ単位で拾う。
    private var keyMonitor: Any?

    @discardableResult
    static func present(image: CGImage, pointSize: CGSize) -> EditorWindowController {
        let controller = EditorWindowController(image: image, pointSize: pointSize)
        openControllers.append(controller)

        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.focusCanvas()
        controller.installKeyMonitor()
        return controller
    }

    private init(image: CGImage, pointSize: CGSize) {
        store = AnnotationStore(image: image, pointSize: pointSize)

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: CGSize(width: 900, height: 600)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Shotter"
        window.subtitle = "\(image.width) × \(image.height) px"
        window.titlebarAppearsTransparent = false
        window.isReleasedWhenClosed = false
        window.contentMinSize = CGSize(width: Self.toolbarMinWidth, height: 320)

        super.init(window: window)

        window.delegate = self
        window.contentView = NSHostingView(
            rootView: EditorView(
                store: store,
                onCopy: { [weak self] in self?.copyToPasteboard() },
                onSave: { [weak self] in self?.saveToFile() }
            )
        )

        window.setContentSize(preferredContentSize(for: pointSize))
        positionOnActiveScreen()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - アクション（メニューの ⌘Z / ⇧⌘Z から届く）

    @objc func undo(_ sender: Any?) {
        store.undo()
    }

    @objc func redo(_ sender: Any?) {
        store.redo()
    }

    @objc func copyFlattenedImage(_ sender: Any?) {
        copyToPasteboard()
    }

    @objc func saveDocument(_ sender: Any?) {
        saveToFile()
    }

    nonisolated func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        MainActor.assumeIsolated {
            switch menuItem.action {
            case #selector(undo(_:)):
                return store.canUndo
            case #selector(redo(_:)):
                return store.canRedo
            case #selector(copyFlattenedImage(_:)):
                // テキスト入力中の ⌘C は文字のコピーに使わせる。
                return !(window?.firstResponder is NSTextView)
            default:
                return true
            }
        }
    }

    // MARK: - キー入力

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            return self.handleKeyDown(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        guard let keyMonitor else { return }
        NSEvent.removeMonitor(keyMonitor)
        self.keyMonitor = nil
    }

    /// - Returns: 処理したら true（イベントを飲み込む）。
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        // テキスト入力中は一切横取りしない。
        if window?.firstResponder is NSTextView { return false }

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

        // S は描画ツールではなく、影のオン／オフ。
        if character == "s" {
            store.hasShadow.toggle()
            return true
        }

        guard let tool = AnnotationTool.allCases.first(where: { $0.shortcutKey == character }) else {
            return false
        }

        store.tool = tool
        canvas?.window?.invalidateCursorRects(for: canvas!)
        return true
    }

    private var canvas: AnnotationCanvasView? {
        window?.contentView?.firstDescendant(ofType: AnnotationCanvasView.self)
    }

    /// マウス操作を素直に受け取れるよう、開いた直後はキャンバスにフォーカスを置く。
    func focusCanvas() {
        guard let window,
              let canvas = window.contentView?.firstDescendant(ofType: AnnotationCanvasView.self)
        else { return }
        window.makeFirstResponder(canvas)
    }

    #if DEBUG
    /// 開発時の目視確認用。キャンバスの描画結果を PNG として書き出す。
    func dumpCanvas(to path: String) {
        guard let canvas = window?.contentView?.firstDescendant(ofType: AnnotationCanvasView.self),
              let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds)
        else {
            FileHandle.standardError.write(Data("キャンバスが見つかりませんでした\n".utf8))
            return
        }

        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
            FileHandle.standardError.write(Data("キャンバスを書き出しました: \(path)\n".utf8))
        }

        // ツールバーを含むウィンドウ全体も書き出しておく。
        if let content = window?.contentView,
           let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                let windowPath = (path as NSString).deletingPathExtension + "-window.png"
                try? png.write(to: URL(fileURLWithPath: windowPath))
                FileHandle.standardError.write(Data("ウィンドウ全体: \(windowPath)\n".utf8))
            }
        }

        // 書き出し（flatten）経路も同じ向き・同じ内容になるか確認する。
        guard let flattened = AnnotationRenderer.flatten(store) else { return }
        let base = (path as NSString).deletingPathExtension

        for format in ImageFormat.allCases {
            guard let data = ImageExporter.data(
                from: flattened,
                format: format,
                jpegQuality: Preferences.jpegQuality
            ) else { continue }

            let outputPath = "\(base)-flat.\(format.fileExtension)"
            try? data.write(to: URL(fileURLWithPath: outputPath))
            FileHandle.standardError.write(Data("書き出し結果: \(outputPath) (\(data.count) bytes)\n".utf8))
        }
    }
    #endif

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        removeKeyMonitor()
        Self.openControllers.removeAll { $0 === self }
    }

    // MARK: - Private

    private static let toolbarMinWidth: CGFloat = 860

    private func copyToPasteboard() {
        guard let flattened = AnnotationRenderer.flatten(store), Pasteboard.copy(flattened) else {
            AlertPresenter.showError(
                ScreenCaptureError.captureFailed("クリップボードへコピーできませんでした")
            )
            return
        }
        HUDPresenter.show("クリップボードにコピーしました", symbolName: "checkmark.circle.fill")
    }

    private func saveToFile() {
        guard let flattened = AnnotationRenderer.flatten(store) else {
            AlertPresenter.showError(ImageExportError.encodingFailed)
            return
        }

        ImageSavePanel.present(image: flattened, in: window) { result in
            switch result {
            case .success(let url):
                HUDPresenter.show("保存しました: \(url.lastPathComponent)", symbolName: "checkmark.circle.fill")
            case .failure(let error):
                AlertPresenter.showError(error)
            }
        }
    }

    /// 画像の等倍サイズを基準に、画面に収まる範囲でウィンドウサイズを決める。
    private func preferredContentSize(for pointSize: CGSize) -> CGSize {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame

        let maxCanvas = CGSize(
            width: visible.width * 0.85 - 32,
            height: visible.height * 0.85 - Self.toolbarHeight - 32
        )
        let scale = min(1, min(maxCanvas.width / pointSize.width, maxCanvas.height / pointSize.height))

        return CGSize(
            width: max(Self.toolbarMinWidth, pointSize.width * scale + 32),
            height: pointSize.height * scale + Self.toolbarHeight + 32
        )
    }

    private static let toolbarHeight: CGFloat = 48

    private func positionOnActiveScreen() {
        guard let window else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let screen else { return window.center() }

        let frame = window.frame
        let visible = screen.visibleFrame
        window.setFrameOrigin(
            CGPoint(
                x: visible.midX - frame.width / 2,
                y: visible.midY - frame.height / 2
            )
        )
    }
}
