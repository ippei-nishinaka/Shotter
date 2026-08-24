import AppKit

/// 手順番号を示す丸番号。番号は配置順から自動で決まり、削除すると自動で振り直される。
final class CounterAnnotation: Annotation, DragCreatableAnnotation {

    var id = UUID()
    var style: AnnotationStyle
    var center: CGPoint

    init(center: CGPoint, style: AnnotationStyle) {
        self.center = center
        self.style = style
    }

    var radius: CGFloat {
        max(style.fontSize * 0.85, 12)
    }

    var boundingBox: CGRect {
        CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
    }

    func draw(in context: CGContext, environment: AnnotationRenderEnvironment) {
        let number = environment.counterNumbers[id] ?? 1
        let circle = boundingBox

        context.setFillColor(style.resolvedColor)
        context.fillEllipse(in: circle)

        // 背景に埋もれないよう白い縁を付ける。
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
        context.setLineWidth(max(radius * 0.12, 1.5))
        context.strokeEllipse(in: circle.insetBy(dx: max(radius * 0.06, 0.75), dy: max(radius * 0.06, 0.75)))

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: radius * 1.15, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let label = NSAttributedString(string: "\(number)", attributes: attributes)
        let size = label.size()

        // 呼び出し元は左上原点・y 下向きなので flipped: true で包む。
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        label.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
        NSGraphicsContext.restoreGraphicsState()
    }

    func hitTest(_ point: CGPoint) -> Bool {
        hypot(point.x - center.x, point.y - center.y) <= radius
    }

    func copy() -> Annotation {
        let duplicate = CounterAnnotation(center: center, style: style)
        duplicate.id = id
        return duplicate
    }

    func translate(by offset: CGVector) {
        center = CGPoint(x: center.x + offset.dx, y: center.y + offset.dy)
    }

    // MARK: - DragCreatableAnnotation

    /// クリックで置き、そのままドラッグすれば位置を微調整できる。
    func updateDrag(to point: CGPoint, constrained: Bool) {
        center = point
    }

    /// クリックしただけで確定させる。
    var isValidForCommit: Bool { true }
}
