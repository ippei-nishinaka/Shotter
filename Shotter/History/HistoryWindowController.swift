import AppKit
import SwiftUI

struct HistoryView: View {

    @ObservedObject var store: HistoryStore

    /// 「すべて削除」の確認。
    @State private var isConfirmingRemoveAll = false

    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if store.items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(store.items) { item in
                            HistoryCell(store: store, item: item)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .onAppear { store.reload() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("履歴")
                    .font(.headline)
                Text(retentionDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("すべて削除") { isConfirmingRemoveAll = true }
                .disabled(store.items.isEmpty)
                .confirmationDialog(
                    "履歴をすべて削除しますか？",
                    isPresented: $isConfirmingRemoveAll,
                    titleVisibility: .visible
                ) {
                    Button("すべて削除", role: .destructive) { store.removeAll() }
                    Button("キャンセル", role: .cancel) {}
                } message: {
                    Text("\(store.items.count) 件のファイルがディスクから削除されます。元に戻せません。")
                }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var retentionDescription: String {
        let retention = Preferences.historyRetention
        switch retention {
        case .disabled:
            return "履歴は保存しない設定です（設定で変更できます）"
        case .forever:
            return "\(store.items.count) 件・自動削除しない設定です"
        default:
            return "\(store.items.count) 件・\(retention.title)を過ぎたものは自動で削除されます"
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("履歴はまだありません")
                .foregroundStyle(.secondary)
            Text("撮影した画像がここに残ります。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct HistoryCell: View {

    @ObservedObject var store: HistoryStore
    let item: HistoryItem

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            thumbnail
            Text(item.displayName)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            Text(item.sizeDescription)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { openInEditor() }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("注釈エディタで開く") { openInEditor() }
            Button("コピー") { copyToPasteboard() }
            Button("Finder で表示") { store.revealInFinder(item) }
            Divider()
            Button("削除", role: .destructive) { store.delete(item) }
        }
        .help("クリックで注釈エディタを開きます")
    }

    @ViewBuilder
    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))

            if let image = store.thumbnail(for: item) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(4)
            }
        }
        .frame(height: 120)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    isHovering ? Color.accentColor : Color.primary.opacity(0.12),
                    lineWidth: isHovering ? 2 : 1
                )
        )
    }

    private func openInEditor() {
        guard let image = store.image(for: item) else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        EditorWindowController.present(
            image: image,
            pointSize: CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        )
    }

    private func copyToPasteboard() {
        guard let image = store.image(for: item) else { return }
        Pasteboard.copy(image)
        HUDPresenter.show("クリップボードにコピーしました", symbolName: "checkmark.circle.fill")
    }
}

@MainActor
final class HistoryWindowController: NSWindowController, NSWindowDelegate {

    private static var shared: HistoryWindowController?

    static func show() {
        HistoryStore.shared.reload()

        if let existing = shared {
            NSApp.activate(ignoringOtherApps: true)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        let controller = HistoryWindowController()
        shared = controller

        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init() {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Shotter の履歴"
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: HistoryView(store: HistoryStore.shared))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        Self.shared = nil
    }
}
