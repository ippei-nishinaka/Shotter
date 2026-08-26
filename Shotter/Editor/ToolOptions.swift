import AppKit

/// 矢印の形。
enum ArrowHeadStyle: String, CaseIterable, Identifiable {
    /// 塗りつぶした三角の矢じり。
    case filled
    /// 線だけで開いた矢じり。
    case open
    /// 両端に矢じり。
    case double

    var id: String { rawValue }

    var title: String {
        switch self {
        case .filled: return "塗り"
        case .open:   return "線"
        case .double: return "両矢印"
        }
    }
}

/// 線の種類。
enum StrokeDashStyle: String, CaseIterable, Identifiable {
    case solid
    case dotted
    case dashed
    case dashDotDot

    var id: String { rawValue }

    var title: String {
        switch self {
        case .solid:      return "実線"
        case .dotted:     return "点線"
        case .dashed:     return "破線"
        case .dashDotDot: return "二点鎖線"
        }
    }

    /// CGContext へ渡す破線パターン。線幅に比例させて、太さを変えても見た目が崩れないようにする。
    func dashPattern(lineWidth: CGFloat) -> [CGFloat]? {
        let unit = max(lineWidth, 1)
        switch self {
        case .solid:      return nil
        case .dotted:     return [unit * 0.1, unit * 1.8]
        case .dashed:     return [unit * 3, unit * 2]
        case .dashDotDot: return [unit * 4, unit * 1.6, unit * 0.1, unit * 1.6, unit * 0.1, unit * 1.6]
        }
    }

    /// 点線は丸いキャップにしないと点にならない。
    var lineCap: CGLineCap {
        switch self {
        case .dotted, .dashDotDot: return .round
        default:                   return .butt
        }
    }
}

/// テキストの書体設定。
struct TextTraits: Equatable {
    /// nil はシステムフォント。
    var fontFamily: String?
    var isBold = false
    var isItalic = false
    var isUnderlined = false
    var isStrikethrough = false

    static let systemFontTitle = "システムフォント"

    /// 設定に合う NSFont を組み立てる。
    func font(ofSize size: CGFloat) -> NSFont {
        let base: NSFont
        if let fontFamily,
           let font = NSFontManager.shared.font(
            withFamily: fontFamily,
            traits: traitMask,
            weight: isBold ? 9 : 5,
            size: size
           ) {
            base = font
        } else {
            base = NSFont.systemFont(ofSize: size, weight: isBold ? .bold : .semibold)
        }

        // ファミリー側で斜体を持たない書体もあるので、無ければ変換して寄せる。
        guard isItalic, !base.fontDescriptor.symbolicTraits.contains(.italic) else { return base }
        let descriptor = base.fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    private var traitMask: NSFontTraitMask {
        var mask: NSFontTraitMask = []
        if isBold { mask.insert(.boldFontMask) }
        if isItalic { mask.insert(.italicFontMask) }
        return mask
    }

    /// 一覧に出す書体。全ファミリーだと多すぎるので、日本語が出るものを優先して絞る。
    static var availableFamilies: [String] {
        let all = NSFontManager.shared.availableFontFamilies
        let preferred = [
            "Hiragino Sans", "Hiragino Mincho ProN", "YuGothic", "YuMincho",
            "Helvetica Neue", "Avenir Next", "Menlo", "SF Pro", "Times New Roman",
        ]
        let front = preferred.filter(all.contains)
        return front + all.filter { !front.contains($0) }
    }
}
