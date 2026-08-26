import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 履歴 1 件分。
struct HistoryItem: Identifiable, Equatable {
    let url: URL
    let date: Date
    let pixelSize: CGSize?

    var id: String { url.lastPathComponent }

    var displayName: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M月d日(E) HH:mm"
        return formatter.string(from: date)
    }

    var sizeDescription: String {
        guard let pixelSize else { return "" }
        return "\(Int(pixelSize.width)) × \(Int(pixelSize.height))"
    }
}

/// 撮影した画像を保存しておく履歴。
///
/// 保存先は `~/Library/Application Support/Shotter/History/`。
/// 保持期間を過ぎたファイルは**実ファイルごと削除**する。
@MainActor
final class HistoryStore: ObservableObject {

    static let shared = HistoryStore()

    @Published private(set) var items: [HistoryItem] = []

    private let fileManager = FileManager.default
    private var thumbnailCache: [String: NSImage] = [:]

    private init() {}

    /// 保存先。無ければ作る。
    var directory: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let url = base
            .appendingPathComponent("Shotter", isDirectory: true)
            .appendingPathComponent("History", isDirectory: true)

        if !fileManager.fileExists(atPath: url.path) {
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    // MARK: - 保存

    /// 撮影した画像を履歴へ保存する。設定が「保存しない」なら何もしない。
    @discardableResult
    func save(_ image: CGImage, date: Date = Date()) -> URL? {
        guard Preferences.historyRetention.keepsHistory else { return nil }
        guard let data = ImageExporter.data(from: image, format: .png, jpegQuality: 1) else {
            return nil
        }

        let url = directory.appendingPathComponent(fileName(for: date))
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return nil
        }

        reload()
        return url
    }

    /// 同じ秒に複数撮ってもぶつからないよう、ミリ秒まで入れる。
    private func fileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return "Shotter-\(formatter.string(from: date)).png"
    }

    // MARK: - 読み込み

    func reload() {
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey]
        let urls = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []

        items = urls
            .filter { $0.pathExtension.lowercased() == "png" }
            .map { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                let date = values?.creationDate ?? values?.contentModificationDate ?? .distantPast
                return HistoryItem(url: url, date: date, pixelSize: Self.pixelSize(of: url))
            }
            .sorted { $0.date > $1.date }
    }

    private static func pixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: width, height: height)
    }

    // MARK: - 削除

    /// 保持期間を過ぎたファイルを実際に削除する。
    /// - Returns: 削除した件数。
    @discardableResult
    func purgeExpired(now: Date = Date()) -> Int {
        let retention = Preferences.historyRetention

        // 「保存しない」に切り替えたときは、残っているものもすべて消す。
        guard retention.keepsHistory else { return removeAll() }

        guard let expiration = retention.expirationDate(from: now) else { return 0 }

        reload()
        var removed = 0
        for item in items where item.date < expiration {
            if delete(item, reloading: false) { removed += 1 }
        }
        if removed > 0 { reload() }
        return removed
    }

    @discardableResult
    func delete(_ item: HistoryItem, reloading: Bool = true) -> Bool {
        do {
            try fileManager.removeItem(at: item.url)
            thumbnailCache[item.id] = nil
            if reloading { reload() }
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func removeAll() -> Int {
        reload()
        var removed = 0
        for item in items where delete(item, reloading: false) { removed += 1 }
        reload()
        return removed
    }

    // MARK: - 読み出し

    func image(for item: HistoryItem) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(item.url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// 一覧用の縮小画像。全体を読み込まずに済むよう ImageIO に作らせる。
    func thumbnail(for item: HistoryItem, maxPixelSize: Int = 480) -> NSImage? {
        if let cached = thumbnailCache[item.id] { return cached }

        guard let source = CGImageSourceCreateWithURL(item.url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width / 2, height: cgImage.height / 2)
        )
        thumbnailCache[item.id] = image
        return image
    }

    func revealInFinder(_ item: HistoryItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }
}
