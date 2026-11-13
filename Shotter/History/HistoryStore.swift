import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// 履歴に入っているものの種類。保持期間も種類ごとに分かれている。
enum HistoryItemKind {
    case image
    case video

    @MainActor var retention: HistoryRetention {
        switch self {
        case .image: return Preferences.historyRetention
        case .video: return Preferences.videoHistoryRetention
        }
    }
}

/// 収録した動画の情報。読み込みのたびに動画を開かずに済むよう、サイドカーの JSON に置いておく。
struct RecordingInfo: Codable {
    var duration: TimeInterval
    var pixelWidth: Int
    var pixelHeight: Int
    var hasSystemAudio: Bool
    var hasMicrophone: Bool
    /// 1 ポイントあたりのピクセル数。注釈の太さなどを画面の見た目に合わせるのに使う。
    /// 古いファイルや、落ちたあと復旧したファイルには無い。
    var pointScale: Double?
}

/// 履歴 1 件分。
struct HistoryItem: Identifiable, Equatable {
    let url: URL
    let date: Date
    let pixelSize: CGSize?
    var kind: HistoryItemKind = .image
    /// 動画の長さ（秒）。
    var duration: TimeInterval?
    var fileSize: Int64?

    var id: String { url.lastPathComponent }

    var displayName: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M月d日(E) HH:mm"
        return formatter.string(from: date)
    }

    var sizeDescription: String {
        var parts: [String] = []
        if let pixelSize { parts.append("\(Int(pixelSize.width)) × \(Int(pixelSize.height))") }
        if kind == .video, let fileSize {
            parts.append(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))
        }
        return parts.joined(separator: "・")
    }
}

/// 撮影した画像と収録した動画を保存しておく履歴。
///
/// 保存先は既定で `~/Library/Application Support/Shotter/History/`。設定で画像・動画それぞれ変えられる。
/// 保持期間（画像と動画で別々）を過ぎたファイルは**実ファイルごと削除**する。
@MainActor
final class HistoryStore: ObservableObject {

    static let shared = HistoryStore()

    @Published private(set) var items: [HistoryItem] = []

    /// サムネイルを描き直してほしいときに増やす（動画に注釈を付けたときなど）。一覧が見て再描画する。
    @Published private(set) var thumbnailRevision = 0

    private let fileManager = FileManager.default
    private var thumbnailCache: [String: NSImage] = [:]

    private init() {}

    /// 既定の保存先。無ければ作る。
    var defaultDirectory: URL {
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

    /// 画像の保存先。設定で変えていればそこ。
    var imageDirectory: URL { directory(for: .image) }

    /// 動画の保存先。設定で変えていればそこ。
    var videoDirectory: URL { directory(for: .video) }

    /// 設定で選んだフォルダが見つからない（外付けディスクを外したなど）ときは、既定の場所を使う。
    func directory(for kind: HistoryItemKind) -> URL {
        if let custom = Preferences.saveDirectory(for: kind), Self.isExistingDirectory(custom) {
            return custom
        }
        return defaultDirectory
    }

    private static func isExistingDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// 収録中のファイルを置く場所。隠しフォルダなので一覧には出ない。
    /// 止めたときの移動が一瞬で済むよう、動画の保存先と同じボリュームに置く。
    private var recordingsDirectory: URL {
        recordingsDirectory(in: videoDirectory)
    }

    private func recordingsDirectory(in base: URL) -> URL {
        let url = base.appendingPathComponent(".recording", isDirectory: true)
        if !fileManager.fileExists(atPath: url.path) {
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    /// 動画の履歴を「保存しない」にしているときの保存先（~/Movies/Shotter）。
    private var moviesDirectory: URL {
        let base = fileManager.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        let url = base.appendingPathComponent("Shotter", isDirectory: true)
        if !fileManager.fileExists(atPath: url.path) {
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    /// 動画の保存先があるボリュームの空き容量（バイト）。収録を始める前の確認に使う。
    var availableDiskSpace: Int64? {
        let values = try? videoDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// 一覧にあるファイルの合計サイズ。
    var totalFileSize: Int64 {
        items.compactMap(\.fileSize).reduce(0, +)
    }

    // MARK: - 保存

    /// 撮影した画像を履歴へ保存する。設定が「保存しない」なら何もしない。
    @discardableResult
    func save(_ image: CGImage, date: Date = Date()) -> URL? {
        guard Preferences.historyRetention.keepsHistory else { return nil }
        guard let data = ImageExporter.data(from: image, format: .png, jpegQuality: 1) else {
            return nil
        }

        let url = imageDirectory.appendingPathComponent(fileName(for: date, extension: "png"))
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return nil
        }

        reload()
        return url
    }

    // MARK: - 動画

    /// 収録中に書き込むファイルの場所。止めたら `storeRecording` で履歴へ移す。
    func temporaryRecordingURL(for date: Date) -> URL {
        recordingsDirectory.appendingPathComponent(fileName(for: date, extension: "mov"))
    }

    /// 書き終えた収録ファイルを履歴へ移す。
    /// 動画の履歴を「保存しない」にしている場合は ~/Movies/Shotter へ移す。
    /// - Returns: 移した先。
    func storeRecording(
        _ result: RecordingWriterResult,
        hasSystemAudio: Bool,
        hasMicrophone: Bool,
        pointScale: CGFloat? = nil,
        date: Date
    ) async throws -> URL {
        let info = RecordingInfo(
            duration: result.duration,
            pixelWidth: Int(result.pixelSize.width),
            pixelHeight: Int(result.pixelSize.height),
            hasSystemAudio: hasSystemAudio,
            hasMicrophone: hasMicrophone,
            pointScale: pointScale.map(Double.init)
        )
        return try await storeRecordingFile(at: result.url, info: info, poster: result.poster, date: date)
    }

    private func storeRecordingFile(at source: URL, info: RecordingInfo?, poster: CGImage?, date: Date) async throws -> URL {
        let name = fileName(for: date, extension: "mov")

        guard Preferences.videoHistoryRetention.keepsHistory else {
            let destination = moviesDirectory.appendingPathComponent(name)
            try await Self.moveInBackground(source, to: destination)
            return destination
        }

        let destination = videoDirectory.appendingPathComponent(name)
        try await Self.moveInBackground(source, to: destination)

        if let info, let data = try? JSONEncoder().encode(info) {
            try? data.write(to: recordingInfoURL(for: destination), options: .atomic)
        }
        if let poster, let data = ImageExporter.data(from: poster, format: .jpeg, jpegQuality: 0.8) {
            try? data.write(to: posterURL(for: destination), options: .atomic)
        }

        reload()
        return destination
    }

    /// 前回、収録中にアプリが落ちた場合に残ったファイルを履歴へ移す。
    /// 10 秒ごとにフラグメントとして書き出しているので、落ちる直前までは再生できる。
    func recoverInterruptedRecordings() async {
        // 保存先を変えたあとでも拾えるよう、既定の場所と今の保存先の両方を見る。
        let folders = Self.unique([recordingsDirectory, recordingsDirectory(in: defaultDirectory)])
        let leftovers = folders.flatMap { folder in
            ((try? fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.creationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []).filter { $0.pathExtension.lowercased() == "mov" }
        }

        for url in leftovers {
            let date = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
            let (info, poster) = await Self.inspectRecording(at: url)
            _ = try? await storeRecordingFile(at: url, info: info, poster: poster, date: date)
        }
    }

    /// 別のディスクへの移動はコピーになり、数 GB の動画だと時間がかかるので、画面を止めないよう裏で行う。
    private static func moveInBackground(_ source: URL, to destination: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.moveItem(at: source, to: destination)
        }.value
    }

    /// 履歴に並べる動画の拡張子。収録したものは .mov、外から取り込んだものは元の形式のまま。
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]

    /// 外から開いた動画（BTT や Finder の「このアプリで開く」）を履歴へ取り込む。
    /// 元のファイルには手を付けず、コピーしたものを編集する。動画の履歴を「保存しない」にしている
    /// 場合だけは、コピーせずに元のファイルをそのまま開く。
    /// - Returns: エディタで開くファイル。
    func importVideo(at source: URL, date: Date = Date()) async throws -> URL {
        guard Preferences.videoHistoryRetention.keepsHistory else { return source }

        let ext = source.pathExtension.lowercased()
        let destination = videoDirectory.appendingPathComponent(
            fileName(for: date, extension: Self.videoExtensions.contains(ext) ? ext : "mov")
        )
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.copyItem(at: source, to: destination)
        }.value

        let (info, poster) = await Self.inspectRecording(at: destination)
        if let info, let data = try? JSONEncoder().encode(info) {
            try? data.write(to: recordingInfoURL(for: destination), options: .atomic)
        }
        if let poster, let data = ImageExporter.data(from: poster, format: .jpeg, jpegQuality: 0.8) {
            try? data.write(to: posterURL(for: destination), options: .atomic)
        }
        reload()
        return destination
    }

    // MARK: - 保存先の変更

    /// 今の保存先にあるその種類のファイルの数。保存先を変えるときに「移動しますか」と聞くのに使う。
    func itemCount(of kind: HistoryItemKind) -> Int {
        reload()
        return items.filter { $0.kind == kind }.count
    }

    /// その種類のファイルを、注釈などのサイドカーごと新しいフォルダへ移す。
    /// - Returns: 移せた件数と、移せなかった件数（同じ名前のファイルが既にあるなど）。
    func moveItems(of kind: HistoryItemKind, to destination: URL) async -> (moved: Int, failed: Int) {
        reload()
        let targets = items.filter { $0.kind == kind && $0.url.deletingLastPathComponent().standardizedFileURL != destination.standardizedFileURL }
        var moved = 0
        var failed = 0

        for item in targets {
            let files = [item.url] + sidecarURLs(for: item).filter { fileManager.fileExists(atPath: $0.path) }
            do {
                for file in files {
                    try await Self.moveInBackground(file, to: destination.appendingPathComponent(file.lastPathComponent))
                }
                moved += 1
            } catch {
                failed += 1
            }
            thumbnailCache[item.id] = nil
        }

        reload()
        return (moved, failed)
    }

    /// 画像・動画と対になって置かれるファイル（注釈・収録情報・ポスター）。
    private func sidecarURLs(for item: HistoryItem) -> [URL] {
        var urls = [annotationsURL(for: item.url)]
        if item.kind == .video {
            urls.append(recordingInfoURL(for: item.url))
            urls.append(posterURL(for: item.url))
            urls.append(editedPosterURL(for: item.url))
        }
        return urls
    }

    private static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// 動画ファイルを開いて長さ・大きさ・最初のコマを調べる。
    private static func inspectRecording(at url: URL) async -> (RecordingInfo?, CGImage?) {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration),
              let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize)
        else { return (nil, nil) }

        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        let info = RecordingInfo(
            duration: duration.seconds,
            pixelWidth: Int(size.width),
            pixelHeight: Int(size.height),
            hasSystemAudio: !audioTracks.isEmpty,
            hasMicrophone: audioTracks.count > 1
        )

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let poster = try? await generator.image(at: .zero).image
        return (info, poster)
    }

    private func recordingInfoURL(for videoURL: URL) -> URL {
        videoURL.deletingPathExtension().appendingPathExtension("recording.json")
    }

    /// 注釈を付けた動画の、注釈込みの見本のコマ。あれば一覧のサムネイルに使う。
    private func editedPosterURL(for videoURL: URL) -> URL {
        videoURL.deletingPathExtension().appendingPathExtension("edited.jpg")
    }

    /// 注釈込みの見本のコマを保存する。nil なら消す（注釈をすべて消したとき）。
    func saveEditedPoster(_ image: CGImage?, for videoURL: URL) {
        let url = editedPosterURL(for: videoURL)
        if let image, fileManager.fileExists(atPath: videoURL.path), let data = ImageExporter.data(from: image, format: .jpeg, jpegQuality: 0.8) {
            try? data.write(to: url, options: .atomic)
        } else {
            try? fileManager.removeItem(at: url)
        }
        thumbnailCache[videoURL.lastPathComponent] = nil
        thumbnailRevision &+= 1
    }

    private func posterURL(for videoURL: URL) -> URL {
        videoURL.deletingPathExtension().appendingPathExtension("poster.jpg")
    }

    private func loadRecordingInfo(for videoURL: URL) -> RecordingInfo? {
        guard let data = try? Data(contentsOf: recordingInfoURL(for: videoURL)) else { return nil }
        return try? JSONDecoder().decode(RecordingInfo.self, from: data)
    }

    // MARK: - 注釈（オブジェクトのまま保存）

    /// 画像と対になる注釈のサイドカー。`Shotter-....png` に対して `Shotter-....json`。
    private func annotationsURL(for imageURL: URL) -> URL {
        imageURL.deletingPathExtension().appendingPathExtension("json")
    }

    /// 編集内容をオブジェクトのまま書き出す。ラスターへ焼き込まないので、
    /// 次に開いたときも引き続き動かしたり編集し直したりできる。
    @discardableResult
    func saveDocument(_ document: AnnotationDocument, for imageURL: URL) -> Bool {
        // エディタを開いたまま履歴から消した画像には書き戻さない（注釈のファイルだけが残り続けてしまう）。
        guard fileManager.fileExists(atPath: imageURL.path) else { return false }
        do {
            let data = try JSONEncoder().encode(document)
            try data.write(to: annotationsURL(for: imageURL), options: .atomic)
            thumbnailCache[imageURL.lastPathComponent] = nil
            // 履歴ウィンドウを開いたまま編集しても、サムネイルが注釈込みの見た目に追従するようにする。
            thumbnailRevision &+= 1
            return true
        } catch {
            return false
        }
    }

    func loadDocument(for item: HistoryItem) -> AnnotationDocument? {
        guard let data = try? Data(contentsOf: annotationsURL(for: item.url)) else { return nil }
        return try? JSONDecoder().decode(AnnotationDocument.self, from: data)
    }

    /// 動画の編集内容（注釈と表示時間・トリム）を書き出す。
    @discardableResult
    func saveVideoDocument(_ document: VideoDocument, for videoURL: URL) -> Bool {
        guard fileManager.fileExists(atPath: videoURL.path) else { return false }
        do {
            let data = try JSONEncoder().encode(document)
            try data.write(to: annotationsURL(for: videoURL), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    func loadVideoDocument(for videoURL: URL) -> VideoDocument? {
        guard let data = try? Data(contentsOf: annotationsURL(for: videoURL)) else { return nil }
        return try? JSONDecoder().decode(VideoDocument.self, from: data)
    }

    /// 履歴にある動画なら、その収録情報。
    func recordingInfo(for videoURL: URL) -> RecordingInfo? {
        loadRecordingInfo(for: videoURL)
    }

    /// 同じ秒に複数撮ってもぶつからないよう、ミリ秒まで入れる。
    private func fileName(for date: Date, extension pathExtension: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return "Shotter-\(formatter.string(from: date)).\(pathExtension)"
    }

    // MARK: - 読み込み

    func reload() {
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .fileSizeKey]
        let imageFolder = imageDirectory.standardizedFileURL.path
        let videoFolder = videoDirectory.standardizedFileURL.path

        // 画像は画像の保存先から、動画は動画の保存先から拾う（同じフォルダでも構わない）。
        let urls = Self.unique([imageDirectory, videoDirectory]).flatMap { folder in
            ((try? fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )) ?? []).filter { url in
                let parent = url.deletingLastPathComponent().standardizedFileURL.path
                switch url.pathExtension.lowercased() {
                case "png":                        return parent == imageFolder
                case let ext where Self.videoExtensions.contains(ext): return parent == videoFolder
                default:                           return false
                }
            }
        }

        items = urls
            .compactMap { url -> HistoryItem? in
                let values = try? url.resourceValues(forKeys: Set(keys))
                let date = values?.creationDate ?? values?.contentModificationDate ?? .distantPast
                let fileSize = values?.fileSize.map(Int64.init)

                switch url.pathExtension.lowercased() {
                case "png":
                    return HistoryItem(url: url, date: date, pixelSize: Self.pixelSize(of: url), fileSize: fileSize)
                case let ext where Self.videoExtensions.contains(ext):
                    let info = loadRecordingInfo(for: url)
                    return HistoryItem(
                        url: url,
                        date: date,
                        pixelSize: info.map { CGSize(width: $0.pixelWidth, height: $0.pixelHeight) },
                        kind: .video,
                        duration: info?.duration,
                        fileSize: fileSize
                    )
                default:
                    return nil
                }
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

    /// 保持期間を過ぎたファイルを実際に削除する。期間は画像と動画で別々に判定する。
    /// - Returns: 削除した件数。
    @discardableResult
    func purgeExpired(now: Date = Date()) -> Int {
        reload()
        var removed = 0
        for item in items where Self.isExpired(item, now: now) {
            if delete(item, reloading: false) { removed += 1 }
        }
        if removed > 0 { reload() }
        return removed
    }

    private static func isExpired(_ item: HistoryItem, now: Date) -> Bool {
        let retention = item.kind.retention
        // 「保存しない」に切り替えたときは、残っているものもすべて消す。
        guard retention.keepsHistory else { return true }
        guard let expiration = retention.expirationDate(from: now) else { return false }
        return item.date < expiration
    }

    @discardableResult
    func delete(_ item: HistoryItem, reloading: Bool = true) -> Bool {
        do {
            try fileManager.removeItem(at: item.url)
            try? fileManager.removeItem(at: annotationsURL(for: item.url))
            if item.kind == .video {
                try? fileManager.removeItem(at: recordingInfoURL(for: item.url))
                try? fileManager.removeItem(at: posterURL(for: item.url))
                try? fileManager.removeItem(at: editedPosterURL(for: item.url))
            }
            thumbnailCache[item.id] = nil
            if reloading { reload() }
            return true
        } catch {
            return false
        }
    }

    /// - Parameter kind: 指定すれば、その種類（画像だけ・動画だけ）を消す。
    @discardableResult
    func removeAll(kind: HistoryItemKind? = nil) -> Int {
        reload()
        var removed = 0
        for item in items where kind == nil || item.kind == kind {
            if delete(item, reloading: false) { removed += 1 }
        }
        reload()
        return removed
    }

    // MARK: - 読み出し

    func image(for item: HistoryItem) -> CGImage? {
        guard item.kind == .image, let source = CGImageSourceCreateWithURL(item.url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// 一覧用の縮小画像。編集済みなら注釈も乗せた見た目にする。
    func thumbnail(for item: HistoryItem, maxPixelSize: Int = 480) -> NSImage? {
        if let cached = thumbnailCache[item.id] { return cached }

        if item.kind == .image, let document = loadDocument(for: item), !document.annotations.isEmpty {
            if let flattened = flattenedImage(for: item, document: document),
               let scaled = Self.resizedThumbnail(of: flattened, maxPixelSize: maxPixelSize) {
                thumbnailCache[item.id] = scaled
                return scaled
            }
        }

        let sourceURL: URL
        if item.kind == .video {
            let edited = editedPosterURL(for: item.url)
            sourceURL = fileManager.fileExists(atPath: edited.path) ? edited : posterURL(for: item.url)
        } else {
            sourceURL = item.url
        }
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else { return nil }
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

    /// 元画像の上に注釈を焼き込んだもの（表示専用。ファイルには書き出さない）。
    private func flattenedImage(for item: HistoryItem, document: AnnotationDocument) -> CGImage? {
        guard let base = image(for: item) else { return nil }
        let store = AnnotationStore(
            image: base,
            pointSize: CGSize(width: base.width, height: base.height),
            document: document
        )
        return AnnotationRenderer.flatten(store)
    }

    /// CGContext で描き直して縮小する。ImageIO のサムネイル API は元がファイルにある前提のため、
    /// メモリ上でしか存在しないフラット化済み画像にはこちらを使う。
    private static func resizedThumbnail(of image: CGImage, maxPixelSize: Int) -> NSImage? {
        let longestSide = CGFloat(max(image.width, image.height))
        let scale = min(1, CGFloat(maxPixelSize) / longestSide)
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let resized = context.makeImage() else { return nil }

        return NSImage(cgImage: resized, size: NSSize(width: width / 2, height: height / 2))
    }

    func revealInFinder(_ item: HistoryItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }
}
