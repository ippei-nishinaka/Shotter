import AppKit

/// ドラッグ範囲に内接する楕円。Shift で正円になる。
final class EllipseAnnotation: TwoPointAnnotation {

    var isFilled = false

    override var constraintMode: ConstraintMode { .square }

    override func draw(in context: CGContext, environment: AnnotationRenderEnvironment) {
        let lineWidth = max(style.lineWidth, 1)
        let target = isFilled ? rect : rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        guard target.width > 0, target.height > 0 else { return }

        context.addEllipse(in: target)
        if isFilled {
            context.setFillColor(style.resolvedColor)
            context.fillPath()
        } else {
            context.setStrokeColor(style.resolvedColor)
            context.setLineWidth(lineWidth)
            context.strokePath()
        }
    }

    override func hitTest(_ point: CGPoint) -> Bool {
        // 楕円の方程式で内外を判定する。
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radiusX = max(rect.width / 2, 1)
        let radiusY = max(rect.height / 2, 1)
        let normalized = pow((point.x - center.x) / radiusX, 2) + pow((point.y - center.y) / radiusY, 2)

        guard !isFilled else { return normalized <= 1 }

        // 枠のみの場合は輪郭付近だけ。
        let slack = max(style.lineWidth, 8)
        let inner = pow((point.x - center.x) / max(radiusX - slack, 1), 2)
            + pow((point.y - center.y) / max(radiusY - slack, 1), 2)
        return normalized <= pow((radiusX + slack) / radiusX, 2) && inner >= 1
    }

    override func copy() -> Annotation {
        let duplicate = EllipseAnnotation(start: start, end: end, style: style)
        duplicate.id = id
        duplicate.isFilled = isFilled
        return duplicate
    }
}
