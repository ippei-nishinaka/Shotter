import AppKit

/// 蛍光ペン。乗算合成で塗るので、下の文字が透けたまま色だけが乗る。
final class HighlightAnnotation: TwoPointAnnotation {

    /// 蛍光ペンらしい濃さ。
    static let alpha: CGFloat = 0.45

    override var constraintMode: ConstraintMode { .square }

    override func draw(in context: CGContext, environment: AnnotationRenderEnvironment) {
        let target = rect
        guard target.width > 0, target.height > 0 else { return }

        let color = (style.color.usingColorSpace(.sRGB) ?? style.color)
            .withAlphaComponent(Self.alpha)

        context.saveGState()
        // 乗算にすることで、塗りつぶしではなくマーカーを引いたような見え方になる。
        context.setBlendMode(.multiply)
        context.setFillColor(color.cgColor)

        let radius = min(style.cornerRadius, min(target.width, target.height) / 2)
        if radius > 0 {
            context.addPath(
                CGPath(roundedRect: target, cornerWidth: radius, cornerHeight: radius, transform: nil)
            )
            context.fillPath()
        } else {
            context.fill(target)
        }
        context.restoreGState()
    }

    override func hitTest(_ point: CGPoint) -> Bool {
        rect.contains(point)
    }
}
