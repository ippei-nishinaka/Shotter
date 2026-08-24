import AppKit

/// 画像上に置くテキスト。`origin` はテキストボックスの左上（画像ピクセル座標）。
final class TextAnnotation: Annotation {

    var id = UUID()
    var style: AnnotationStyle
    var origin: CGPoint
    var text: String

    /// 折り返し幅（画像ピクセル）。作成時に画像の右端までを割り当てる。
    var maxWidth: CGFloat

    init(origin: CGPoint, text: String, style: AnnotationStyle, maxWidth: CGFloat) {
        self.origin = origin
        self.text = text
        self.style = style
        self.maxWidth = maxWidth
    }

    static func font(ofSize size: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: .semibold)
    }

    var attributes: [NSAttributedString.Key: Any] {
        [
            .font: Self.font(ofSize: style.fontSize),
            .foregroundColor: style.color,
        ]
    }

    var attributedText: NSAttributedString {
        NSAttributedString(string: text, attributes: attributes)
    }

    /// 折り返しを考慮した実サイズ。
    var textSize: CGSize {
        guard !text.isEmpty else {
            return CGSize(width: style.fontSize, height: style.fontSize * 1.3)
        }
        let bounds = attributedText.boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
    }

    var boundingBox: CGRect {
        CGRect(origin: origin, size: textSize)
    }

    func draw(in context: CGContext, environment: AnnotationRenderEnvironment) {
        guard !text.isEmpty else { return }

        // 呼び出し元のコンテキストは「左上原点・y 下向き」なので flipped: true で包む。
        // こうすると AppKit のテキスト描画がそのまま正しい向きになる。
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext

        attributedText.draw(
            with: CGRect(origin: origin, size: CGSize(width: maxWidth, height: .greatestFiniteMagnitude)),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )

        NSGraphicsContext.restoreGraphicsState()
    }

    func hitTest(_ point: CGPoint) -> Bool {
        boundingBox.insetBy(dx: -4, dy: -4).contains(point)
    }

    func copy() -> Annotation {
        let duplicate = TextAnnotation(origin: origin, text: text, style: style, maxWidth: maxWidth)
        duplicate.id = id
        return duplicate
    }

    func translate(by offset: CGVector) {
        origin = CGPoint(x: origin.x + offset.dx, y: origin.y + offset.dy)
    }
}
