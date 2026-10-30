import AppKit
import SwiftUI

/// 履歴の絞り込み。開いたときは常に「すべて」（画像と動画の両方）。
enum HistoryFilter: String, CaseIterable, Identifiable {
    case all
    case images
    case videos

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:    return "すべて"
        case .images: return "画像"
        case .videos: return "動画"
        }
    }

    var kind: HistoryItemKind? {
        switch self {
        case .all:    return nil
        case .images: return .image
        case .videos: return .video
        }
    }

    func includes(_ item: HistoryItem) -> Bool {
        kind == nil || item.kind == kind
    }
}

struct HistoryView: View {

    @ObservedObject var store: HistoryStore

    /// 「すべて削除」の確認。
    @State private var isConfirmingRemoveAll = false

    @State private var filter: HistoryFilter = .all

    init(store: HistoryStore) {
        self.store = store
        #if DEBUG
        // --debug-history-filter <all|images|videos> で、絞り込んだ状態で開く（見た目の確認用）。
        if let index = CommandLine.arguments.firstIndex(of: "--debug-history-filter"),
           CommandLine.arguments.indices.contains(index + 1),
           let initial = HistoryFilter(rawValue: CommandLine.arguments[index + 1]) {
            _filter = State(initialValue: initial)
        }
        #endif
    }

    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 14)]

    private var shownItems: [HistoryItem] {
        store.items.filter(filter.includes)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if shownItems.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(shownItems) { item in
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

            Picker("表示", selection: $filter) {
                ForEach(HistoryFilter.allCases) { filter in
                    Text("\(filter.title)（\(count(of: filter))）").tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("画像だけ・動画だけに絞り込めます")

            Button { isConfirmingRemoveAll = true } label: {
                // 絞り込みでボタンの文字が変わっても幅が変わらないよう、いちばん長い文言の幅を確保しておく。
                // （幅が変わると、左隣の絞り込みのボタンまで動いてしまう）
                ZStack {
                    ForEach(HistoryFilter.allCases) { filter in
                        Text(Self.removeTitle(for: filter)).hidden()
                    }
                    Text(removeTitle)
                }
            }
                .disabled(shownItems.isEmpty)
                .confirmationDialog(
                    "\(removeTarget)をすべて削除しますか？",
                    isPresented: $isConfirmingRemoveAll,
                    titleVisibility: .visible
                ) {
                    Button(removeTitle, role: .destructive) { store.removeAll(kind: filter.kind) }
                    Button("キャンセル", role: .cancel) {}
                } message: {
                    Text("\(shownItems.count) 件のファイルがディスクから削除されます。元に戻せません。")
                }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func count(of filter: HistoryFilter) -> Int {
        store.items.filter(filter.includes).count
    }

    /// 削除ボタンは、絞り込んでいるときはその種類だけを対象にする。
    private var removeTarget: String {
        switch filter {
        case .all:    return "履歴"
        case .images: return "画像の履歴"
        case .videos: return "動画の履歴"
        }
    }

    private var removeTitle: String {
        Self.removeTitle(for: filter)
    }

    private static func removeTitle(for filter: HistoryFilter) -> String {
        filter == .all ? "すべて削除" : "\(filter.title)をすべて削除"
    }

    private var retentionDescription: String {
        let total = ByteCountFormatter.string(fromByteCount: store.totalFileSize, countStyle: .file)
        let image = Self.retentionPhrase(Preferences.historyRetention)
        let video = Self.retentionPhrase(Preferences.videoHistoryRetention)
        return "\(store.items.count) 件（\(total)）・画像は\(image)、動画は\(video)"
    }

    private var emptyTitle: String {
        switch filter {
        case .all:    return "履歴はまだありません"
        case .images: return "画像の履歴はありません"
        case .videos: return "動画の履歴はありません"
        }
    }

    private static func retentionPhrase(_ retention: HistoryRetention) -> String {
        switch retention {
        case .disabled: return "保存しない設定"
        case .forever:  return "自動削除しない設定"
        default:        return "\(retention.title)で自動削除"
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text(emptyTitle)
                .foregroundStyle(.secondary)
            Text("撮影した画像や収録した動画がここに残ります。")
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
        .onTapGesture { open() }
        .onHover { isHovering = $0 }
        .contextMenu {
            if item.kind == .video {
                Button("動画エディタで開く") { open() }
                Button("QuickTime Player で再生") { NSWorkspace.shared.open(item.url) }
            } else {
                Button("注釈エディタで開く") { open() }
            }
            Button("コピー") { copyToPasteboard() }
            Button("Finder で表示") { store.revealInFinder(item) }
            Divider()
            Button("削除", role: .destructive) { store.delete(item) }
        }
        .help(item.kind == .video ? "クリックで動画エディタを開きます" : "クリックで注釈エディタを開きます")
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

            if item.kind == .video {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 30))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.white, Color.black.opacity(0.5))
            }
        }
        .frame(height: 120)
        .overlay(alignment: .bottomTrailing) {
            if let duration = item.duration {
                VideoDurationBadge(duration: duration)
                    .padding(8)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    isHovering ? Color.accentColor : Color.primary.opacity(0.12),
                    lineWidth: isHovering ? 2 : 1
                )
        )
    }

    private func open() {
        guard item.kind == .image else {
            VideoEditorWindowController.present(url: item.url)
            return
        }
        guard let image = store.image(for: item) else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        EditorWindowController.present(
            image: image,
            pointSize: CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale),
            historyURL: item.url,
            document: store.loadDocument(for: item)
        )
    }

    private func copyToPasteboard() {
        if item.kind == .video {
            Pasteboard.copy(fileURL: item.url)
        } else {
            guard let image = store.image(for: item) else { return }
            Pasteboard.copy(image)
        }
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
