import AppKit
import UniformTypeIdentifiers

enum ImageFormat: String, CaseIterable, Identifiable {
    case png
    case jpeg

    var id: String { rawValue }

    var title: String {
        switch self {
        case .png:  return "PNG"
        case .jpeg: return "JPEG"
        }
    }

    var fileExtension: String {
        switch self {
        case .png:  return "png"
        case .jpeg: return "jpg"
        }
    }

    var contentType: UTType {
        switch self {
        case .png:  return .png
        case .jpeg: return .jpeg
        }
    }
}

enum ImageExportError: LocalizedError {
    case encodingFailed

    var errorDescription: String? {
        "画像の書き出しに失敗しました。"
    }
}

enum ImageExporter {

    /// 指定形式のデータへエンコードする。
    static func data(from image: CGImage, format: ImageFormat, jpegQuality: CGFloat) -> Data? {
        let representation = NSBitmapImageRep(cgImage: image)

        switch format {
        case .png:
            return representation.representation(using: .png, properties: [:])
        case .jpeg:
            return representation.representation(
                using: .jpeg,
                properties: [.compressionFactor: jpegQuality]
            )
        }
    }

    /// 「Shotter 2026-08-24 11.09.32」のような、macOS のスクリーンショットに近い名前。
    static func defaultFileName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Shotter \(formatter.string(from: date))"
    }
}
