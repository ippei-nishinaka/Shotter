import AppKit

/// 外枠のみ／塗りつぶしの四角。`isFilled` で切り替える。
final class RectangleAnnotation: TwoPointAnnotation {

    var isFilled = false

    /// 角の丸み。0 なら直角。
    var cornerRadius: CGFloat = 0

    override var constraintMode: ConstraintMode { .square }

    override func draw(in context: CGContext, environment: AnnotationRenderEnvironment) {
        let lineWidth = max(style.lineWidth, 1)
        // ストロークが選択範囲の外へはみ出さないよう、線幅の半分だけ内側に寄せる。
        let target = isFilled ? rect : rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        guard target.width > 0, target.height > 0 else { return }

        let path = CGPath(
            roundedRect: target,
            cornerWidth: min(cornerRadius, target.width / 2),
            cornerHeight: min(cornerRadius, target.height / 2),
            transform: nil
        )

        context.addPath(path)
        if isFilled {
            context.setFillColor(style.resolvedColor)
            context.fillPath()
        } else {
            context.setStrokeColor(style.resolvedColor)
            context.setLineWidth(lineWidth)
            context.setLineJoin(.miter)
            context.strokePath()
        }
    }

    override func hitTest(_ point: CGPoint) -> Bool {
        guard !isFilled else { return rect.contains(point) }

        // 枠のみの場合は、外周付近だけを当たり判定にする。
        let slack = max(style.lineWidth, 8)
        return rect.insetBy(dx: -slack, dy: -slack).contains(point)
            && !rect.insetBy(dx: slack, dy: slack).contains(point)
    }

    override func copy() -> Annotation {
        let duplicate = RectangleAnnotation(start: start, end: end, style: style)
        duplicate.id = id
        duplicate.isFilled = isFilled
        duplicate.cornerRadius = cornerRadius
        return duplicate
    }
}
