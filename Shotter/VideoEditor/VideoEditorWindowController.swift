import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// 動画エディタの中身。上が静止画と共通のツールバー、真ん中が動画と注釈、下がタイムライン。
struct VideoEditorView: View {

    @ObservedObject var store: VideoEditorStore
    @ObservedObject var annotations: AnnotationStore
    let onCopyFrame: () -> Void
    let onSaveFrame: () -> Void
    let onOpenFrameInEditor: () -> Void
    let onExport: (VideoExportFormat) -> Void

    var body: some View {
        VStack(spacing: 0) {
            EditorToolbarView(store: annotations, trailingActions: AnyView(actions), fileURL: store.videoURL)
            Divider()
            ToolOptionsBar(store: annotations)
            Divider()

            VideoCanvasRepresentable(store: annotations, player: store.player) {
                store.pause()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            VideoTimelineView(store: store, annotations: annotations)
                .frame(height: timelineHeight)
        }
        .instantTooltipContainer()
        .overlay {
            if let progress = store.exportProgress {
                exportProgressOverlay(progress)
            }
        }
    }

    /// 注釈の数に合わせて伸ばす（多すぎるときはタイムラインの中でスクロール）。
    private var timelineHeight: CGFloat {
        let lanes = CGFloat(min(max(annotations.annotations.count, 1), 6))
        return 34 + 26 + lanes * 24 + 16 + 33
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Menu {
                Button("クリップボードにコピー", action: onCopyFrame)
                Button("画像として保存…", action: onSaveFrame)
                Divider()
                Button("静止画エディタで開く", action: onOpenFrameInEditor)
            } label: {
                Label("このコマ", systemImage: "photo")
            }
            .fixedSize()
            .instantTooltip(
                title: "このコマを静止画にする",
                detail: "今の再生位置のコマに、表示中の注釈を乗せた画像をコピー・保存します。静止画エディタで続けて編集もできます。"
            )

            Menu {
                ForEach(VideoExportFormat.allCases) { format in
                    Button(format.title) { onExport(format) }
                }
            } label: {
                Label("動画を書き出す", systemImage: "square.and.arrow.up")
            }
            .fixedSize()
            .instantTooltip(
                title: "動画を書き出す",
                shortcut: "⌘S",
                detail: "注釈を焼き込んだ動画を保存します。トリムした範囲だけが書き出されます。"
            )
        }
    }

    private func exportProgressOverlay(_ progress: Double) -> some View {
        ZStack {
            Color.black.opacity(0.35)
            VStack(spacing: 12) {
                Text("動画を書き出しています… \(Int(progress * 100))%")
                    .font(.system(size: 13, weight: .semibold))
                ProgressView(value: progress)
                    .frame(width: 280)
                Button("中止") { store.cancelExport() }
            }
            .padding(20)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Material.regular))
        }
        .contentShape(Rectangle())
    }
}

/// GIF の保存ダイアログに足す設定（幅・fps）。
@MainActor
final class GIFOptionsModel: ObservableObject {
    @Published var options: GIFExportOptions
    let length: Double

    init(options: GIFExportOptions, length: Double) {
        self.options = options
        self.length = length
    }

    var frameCountDescription: String {
        let frames = Int((length * Double(options.framesPerSecond)).rounded(.up))
        return "最大 \(frames) コマ（\(VideoDurationBadge.format(length))）"
    }
}

struct GIFOptionsView: View {
    @ObservedObject var model: GIFOptionsModel

    var body: some View {
        HStack(spacing: 16) {
            Picker("幅", selection: $model.options.maxWidth) {
                ForEach(GIFExportOptions.widthChoices, id: \.self) { width in
                    Text(GIFExportOptions.widthTitle(width)).tag(width)
                }
            }
            .fixedSize()

            Picker("fps", selection: $model.options.framesPerSecond) {
                ForEach(GIFExportOptions.frameRateChoices, id: \.self) { fps in
                    Text("\(fps)").tag(fps)
                }
            }
            .fixedSize()

            Text(model.frameCountDescription)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }
}

/// 収録した動画に注釈を付けるウィンドウ。
@MainActor
final class VideoEditorWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {

    private static var openControllers: [VideoEditorWindowController] = []
    private static var loadingURLs: Set<URL> = []

    /// アプリの終了時に、開いているすべてのエディタの編集内容を履歴へ書き戻す。
    static func flushAllPendingEdits() {
        for controller in openControllers { controller.store.flushSave() }
    }

    let store: VideoEditorStore
    private var keyMonitor: Any?

    /// 動画を読み込んでエディタを開く。同じ動画がもう開いていれば前に出すだけにする。
    static func present(url: URL) {
        let key = url.standardizedFileURL
        if let existing = openControllers.first(where: { $0.store.videoURL.standardizedFileURL == key }) {
            NSApp.activate(ignoringOtherApps: true)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        // 読み込みの途中でもう一度クリックされても、同じ動画のウィンドウを 2 つ開かない。
        guard loadingURLs.insert(key).inserted else { return }

        Task { @MainActor in
            defer { loadingURLs.remove(key) }
            do {
                let store = try await VideoEditorStore.load(url: url)
                let controller = VideoEditorWindowController(store: store)
                openControllers.append(controller)

                NSApp.activate(ignoringOtherApps: true)
                controller.showWindow(nil)
                controller.window?.makeKeyAndOrderFront(nil)
                controller.focusCanvas()
                controller.installKeyMonitor()
            } catch {
                AlertPresenter.showError(error, title: "動画を開けませんでした")
            }
        }
    }

    private init(store: VideoEditorStore) {
        self.store = store

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: CGSize(width: 1000, height: 700)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Shotter"
        window.subtitle = "\(Int(store.pixelSize.width)) × \(Int(store.pixelSize.height))・\(VideoDurationBadge.format(store.duration))"
        window.isReleasedWhenClosed = false
        window.contentMinSize = CGSize(width: 980, height: 520)
        // タイトルに動画ファイルのアイコンを出す。⌘ クリックで置き場所をたどれる。
        window.representedURL = store.videoURL

        super.init(window: window)

        window.delegate = self
        window.contentView = NSHostingView(
            rootView: VideoEditorView(
                store: store,
                annotations: store.annotationStore,
                onCopyFrame: { [weak self] in self?.copyFrame() },
                onSaveFrame: { [weak self] in self?.saveFrame() },
                onOpenFrameInEditor: { [weak self] in self?.openFrameInEditor() },
                onExport: { [weak self] in self?.export(format: $0) }
            )
        )

        window.setContentSize(preferredContentSize())
        positionOnActiveScreen()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - メニュー（⌘Z / ⌘C / ⌘S）

    @objc func undo(_ sender: Any?) { store.annotationStore.undo() }
    @objc func redo(_ sender: Any?) { store.annotationStore.redo() }
    @objc func copyFlattenedImage(_ sender: Any?) { copyFrame() }
    @objc func saveDocument(_ sender: Any?) { export(format: .mp4) }

    nonisolated func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        MainActor.assumeIsolated {
            switch menuItem.action {
            case #selector(undo(_:)):               return store.annotationStore.canUndo
            case #selector(redo(_:)):               return store.annotationStore.canRedo
            case #selector(copyFlattenedImage(_:)): return !(window?.firstResponder is NSTextView)
            case #selector(saveDocument(_:)):       return store.exportProgress == nil
            default:                                return true
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
        // テキスト入力中（注釈の文字・時刻の入力欄）は一切横取りしない。
        if window?.firstResponder is NSTextView { return false }
        guard store.exportProgress == nil else { return true }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let plain = flags.subtracting([.shift, .numericPad, .function]).isEmpty
        let hasShift = flags.contains(.shift)

        if plain {
            switch event.keyCode {
            case 49: // space
                store.togglePlayback()
                return true
            case 123: // ← は 3 秒戻る。⇧← は 1 コマ戻る。
                if hasShift { store.step(frames: -1) } else { store.skip(seconds: -VideoEditorStore.skipInterval) }
                return true
            case 124: // → は 3 秒進む。⇧→ は 1 コマ進む。
                if hasShift { store.step(frames: 1) } else { store.skip(seconds: VideoEditorStore.skipInterval) }
                return true
            default:
                break
            }

            if let id = store.annotationStore.selectedID {
                switch event.charactersIgnoringModifiers {
                case "[":
                    store.setStartToCurrentTime(id)
                    return true
                case "]":
                    store.setEndToCurrentTime(id)
                    return true
                default:
                    break
                }
            }
        }

        return EditorKeyCommands.handle(event, store: store.annotationStore, canvas: canvas)
    }

    private var canvas: AnnotationCanvasView? {
        window?.contentView?.firstDescendant(ofType: AnnotationCanvasView.self)
    }

    func focusCanvas() {
        guard let canvas else { return }
        window?.makeFirstResponder(canvas)
    }

    // MARK: - このコマ

    private func withStillFrame(_ body: @escaping (_ frame: CGImage, _ flattened: CGImage) -> Void) {
        store.pause()
        Task { @MainActor in
            do {
                let result = try await store.renderStillFrame()
                body(result.frame, result.flattened)
            } catch {
                AlertPresenter.showError(error, title: "このコマを取り出せませんでした")
            }
        }
    }

    private func copyFrame() {
        withStillFrame { _, flattened in
            guard Pasteboard.copy(flattened) else { return }
            HUDPresenter.show("このコマをコピーしました", symbolName: "checkmark.circle.fill")
        }
    }

    private func saveFrame() {
        withStillFrame { [weak self] _, flattened in
            ImageSavePanel.present(image: flattened, in: self?.window) { result in
                switch result {
                case .success(let url):
                    HUDPresenter.show("保存しました: \(url.lastPathComponent)", symbolName: "checkmark.circle.fill")
                case .failure(let error):
                    AlertPresenter.showError(error)
                }
            }
        }
    }

    /// 注釈を焼き込まず、オブジェクトのまま静止画エディタへ渡す（向こうで続けて動かせる）。
    private func openFrameInEditor() {
        let document = store.visibleAnnotationsDocument
        let pointSize = store.annotationStore.pointSize
        withStillFrame { frame, _ in
            // 静止画として撮ったときと同じく、履歴にも残す。
            let historyURL = HistoryStore.shared.save(frame)
            if let historyURL { HistoryStore.shared.saveDocument(document, for: historyURL) }
            EditorWindowController.present(image: frame, pointSize: pointSize, historyURL: historyURL, document: document)
        }
    }

    // MARK: - 動画の書き出し

    private func export(format: VideoExportFormat) {
        guard store.exportProgress == nil, let window else { return }
        store.pause()

        // GIF は 1 コマごとに画像を丸ごと持つので、長いと非常に大きくなる。先に一言確かめる。
        let length = store.trimEnd - store.trimStart
        if format == .gif, length > 60 {
            let alert = NSAlert()
            alert.messageText = "GIF にすると大きなファイルになります"
            alert.informativeText = "書き出す範囲が \(VideoDurationBadge.format(length)) あります。GIF は 1 分を超えると数十〜数百 MB になり、書き出しにも時間がかかります。トリムで短くするか、MP4 で書き出すのがおすすめです。"
            alert.addButton(withTitle: "GIF で書き出す")
            alert.addButton(withTitle: "やめる")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        let gifModel = GIFOptionsModel(options: Preferences.gifExportOptions, length: length)
        let panel = NSSavePanel()
        if format == .gif {
            let accessory = NSHostingView(rootView: GIFOptionsView(model: gifModel))
            accessory.frame = CGRect(origin: .zero, size: accessory.fittingSize)
            panel.accessoryView = accessory
        }
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = store.videoURL.deletingPathExtension().lastPathComponent
            + "-edited." + format.fileExtension
        if let directory = Preferences.lastSaveDirectory {
            panel.directoryURL = directory
        }

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Preferences.lastSaveDirectory = url.deletingLastPathComponent()

            if format == .gif { Preferences.gifExportOptions = gifModel.options }

            Task { @MainActor in
                do {
                    try await self.store.exportVideo(format: format, gifOptions: gifModel.options, to: url)
                    HUDPresenter.show("書き出しました: \(url.lastPathComponent)", symbolName: "checkmark.circle.fill")
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } catch VideoExportError.cancelled {
                    HUDPresenter.show("書き出しを中止しました", symbolName: "xmark.circle.fill")
                } catch {
                    AlertPresenter.showError(error, title: "動画を書き出せませんでした")
                }
            }
        }
    }

    // MARK: - NSWindowDelegate

    /// 書き出しの途中で閉じると書き出しも止まるので、うっかり閉じないよう確かめる。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard store.exportProgress != nil else { return true }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "動画の書き出しを中止して閉じますか？"
        alert.informativeText = "書き出しの途中です。閉じると、ここまでの書き出しは破棄されます。"
        alert.addButton(withTitle: "書き出しを続ける")
        alert.addButton(withTitle: "中止して閉じる")
        return alert.runModal() == .alertSecondButtonReturn
    }

    func windowWillClose(_ notification: Notification) {
        store.tearDown()
        removeKeyMonitor()
        Self.openControllers.removeAll { $0 === self }
    }

    // MARK: - ウィンドウの大きさ

    private func preferredContentSize() -> CGSize {
        let screen = EditorWindowController.screenUnderMouse() ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let chrome: CGFloat = 48 + 36 + 200 + 60
        let pointSize = store.annotationStore.pointSize

        let maxCanvas = CGSize(width: visible.width * 0.85 - 60, height: visible.height * 0.88 - chrome)
        let scale = min(1, min(maxCanvas.width / pointSize.width, maxCanvas.height / pointSize.height))
        return CGSize(
            width: max(980, pointSize.width * scale + 60),
            height: max(520, pointSize.height * scale + chrome)
        )
    }

    private func positionOnActiveScreen() {
        guard let window else { return }
        guard let screen = EditorWindowController.screenUnderMouse() else { return window.center() }
        let visible = screen.visibleFrame
        window.setFrameOrigin(CGPoint(
            x: visible.midX - window.frame.width / 2,
            y: visible.midY - window.frame.height / 2
        ))
    }
}
