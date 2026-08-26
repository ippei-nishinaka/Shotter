import Foundation

/// 注釈ツールの種類。表示順はそのままツールバーの並び順になる。
enum AnnotationTool: String, CaseIterable, Identifiable {
    case select
    case arrow
    case rectangle
    case filledRectangle
    case ellipse
    case line
    case freehand
    case highlight
    case text
    case pixelate
    case spotlight
    case counter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select:          return "編集"
        case .arrow:           return "矢印"
        case .rectangle:       return "四角（枠）"
        case .filledRectangle: return "四角（塗り）"
        case .ellipse:         return "円"
        case .line:            return "線"
        case .freehand:        return "フリーハンド"
        case .highlight:       return "ハイライト"
        case .text:            return "テキスト"
        case .pixelate:        return "モザイク"
        case .spotlight:       return "強調"
        case .counter:         return "ナンバリング"
        }
    }

    /// ショートカットの由来になる英語名。頭文字がそのままキーになる。
    var englishName: String {
        switch self {
        case .select:          return "Edit"
        case .arrow:           return "Arrow"
        case .rectangle:       return "Outline"
        case .filledRectangle: return "Block"
        case .ellipse:         return "Circle"
        case .line:            return "Line"
        case .freehand:        return "Draw"
        case .highlight:       return "Highlight"
        case .text:            return "Text"
        case .pixelate:        return "Mosaic"
        case .spotlight:       return "Focus"
        case .counter:         return "Numbering"
        }
    }

    /// ツールチップに出す「何ができるか」。
    var hint: String {
        switch self {
        case .select:
            return "描いた注釈をクリックで選び、ドラッグで移動、つまみでリサイズ、Delete で削除。テキストはダブルクリックで再編集。"
        case .arrow:
            return "ドラッグで矢印を引きます。Shift で 45 度ずつに固定。"
        case .rectangle:
            return "ドラッグで枠だけの四角を描きます（塗りは Block／B）。Shift で正方形。"
        case .filledRectangle:
            return "ドラッグで塗りつぶしの四角を描きます。Shift で正方形。"
        case .ellipse:
            return "ドラッグで楕円を描きます。Shift で正円。"
        case .line:
            return "ドラッグで直線を引きます。Shift で 45 度ずつに固定。"
        case .freehand:
            return "ドラッグで手描きの線を引きます。"
        case .highlight:
            return "ドラッグで蛍光ペンを引きます。下の文字が透けたまま色が乗ります。"
        case .text:
            return "クリックした位置に文字を入力します。Esc で確定。"
        case .pixelate:
            return "ドラッグした範囲をモザイク／ぼかしで隠します。"
        case .spotlight:
            return "指定した範囲以外を暗くして、そこだけを目立たせます。"
        case .counter:
            return "クリックで連番の丸数字を置きます。削除すると自動で振り直されます。"
        }
    }

    /// ツールバーのボタンにマウスを乗せたときに出る説明。
    var tooltip: String {
        """
        \(title)（\(englishName)）　ショートカット: \(String(shortcutKey).uppercased())
        \(hint)
        """
    }

    /// ツールバーに表示する SF Symbol 名。
    var symbolName: String {
        switch self {
        case .select:          return "cursorarrow"
        case .arrow:           return "arrow.up.right"
        case .rectangle:       return "rectangle"
        case .filledRectangle: return "rectangle.fill"
        case .ellipse:         return "circle"
        case .line:            return "line.diagonal"
        case .freehand:        return "scribble"
        case .highlight:       return "highlighter"
        case .text:            return "character"
        case .pixelate:        return "mosaic"
        case .spotlight:       return "flashlight.on.fill"
        case .counter:         return "1.circle.fill"
        }
    }

    /// symbolName が古い OS で見つからなかったときの代替。
    var fallbackSymbolName: String {
        switch self {
        case .highlight: return "pencil.tip"
        case .pixelate:  return "square.grid.3x3.fill"
        case .spotlight: return "circle.dashed"
        case .counter:   return "1.circle.fill"
        default:         return "questionmark"
        }
    }

    /// ⌘ではなく単独キーで切り替えるためのショートカット。
    var shortcutKey: Character {
        switch self {
        case .select:          return "e"
        case .arrow:           return "a"
        case .rectangle:       return "o"
        case .filledRectangle: return "b"
        case .ellipse:         return "c"
        case .line:            return "l"
        case .freehand:        return "d"
        case .highlight:       return "h"
        case .text:            return "t"
        case .pixelate:        return "m"
        case .spotlight:       return "f"
        case .counter:         return "n"
        }
    }
}
