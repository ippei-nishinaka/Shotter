import AppKit

/// 始点から終点へ向かう矢印。矢じりの形は `style.arrowHead` で切り替える。
final class ArrowAnnotation: TwoPointAnnotation {

    override var handleLayout: HandleLayout { .endpoints }

    override func draw(in context: CGContext, environment: AnnotationRenderEnvironment) {
        let lineWidth = max(style.lineWidth, 1)
        let headLength = max(lineWidth * 3.4, 12)
        let headWidth = max(lineWidth * 3.0, 10)

        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0.5 else { return }

        let unit = CGPoint(x: dx / length, y: dy / length)

        context.setStrokeColor(style.resolvedColor)
        context.setFillColor(style.resolvedColor)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(lineWidth)

        switch style.arrowHead {
        case .filled:
            drawShaft(from: start, to: neck(from: end, towards: unit, by: headLength),
                      length: length, headLength: headLength, in: context)
            fillHead(at: end, unit: unit, headLength: headLength, headWidth: headWidth, in: context)

        case .open:
            // 開いた矢じりは軸を先端まで引いてよい。
            context.move(to: start)
            context.addLine(to: end)
            context.strokePath()
            strokeHead(at: end, unit: unit, headLength: headLength, headWidth: headWidth, in: context)

        case .double:
            let reversed = CGPoint(x: -unit.x, y: -unit.y)
            let tailNeck = neck(from: start, towards: reversed, by: headLength)
            let headNeck = neck(from: end, towards: unit, by: headLength)

            if length > headLength * 2 {
                context.move(to: tailNeck)
                context.addLine(to: headNeck)
                context.strokePath()
            }
            fillHead(at: end, unit: unit, headLength: headLength, headWidth: headWidth, in: context)
            fillHead(at: start, unit: reversed, headLength: headLength, headWidth: headWidth, in: context)
        }
    }

    override func hitTest(_ point: CGPoint) -> Bool {
        Geometry.distance(from: point, toSegment: start, end) <= max(style.lineWidth, 8)
    }

    // MARK: - Private

    /// 矢じりの根元。軸はここまでしか引かず、先端からはみ出さないようにする。
    private func neck(from tip: CGPoint, towards unit: CGPoint, by length: CGFloat) -> CGPoint {
        CGPoint(x: tip.x - unit.x * length, y: tip.y - unit.y * length)
    }

    private func drawShaft(
        from origin: CGPoint,
        to neck: CGPoint,
        length: CGFloat,
        headLength: CGFloat,
        in context: CGContext
    ) {
        guard length > headLength else { return }
        context.move(to: origin)
        context.addLine(to: neck)
        context.strokePath()
    }

    private func fillHead(
        at tip: CGPoint,
        unit: CGPoint,
        headLength: CGFloat,
        headWidth: CGFloat,
        in context: CGContext
    ) {
        let base = neck(from: tip, towards: unit, by: headLength)
        // 軸に対して垂直な単位ベクトル。
        let perpendicular = CGPoint(x: -unit.y, y: unit.x)

        context.move(to: tip)
        context.addLine(to: CGPoint(
            x: base.x + perpendicular.x * headWidth / 2,
            y: base.y + perpendicular.y * headWidth / 2
        ))
        context.addLine(to: CGPoint(
            x: base.x - perpendicular.x * headWidth / 2,
            y: base.y - perpendicular.y * headWidth / 2
        ))
        context.closePath()
        context.fillPath()
    }

    private func strokeHead(
        at tip: CGPoint,
        unit: CGPoint,
        headLength: CGFloat,
        headWidth: CGFloat,
        in context: CGContext
    ) {
        let base = neck(from: tip, towards: unit, by: headLength)
        let perpendicular = CGPoint(x: -unit.y, y: unit.x)

        context.move(to: CGPoint(
            x: base.x + perpendicular.x * headWidth / 2,
            y: base.y + perpendicular.y * headWidth / 2
        ))
        context.addLine(to: tip)
        context.addLine(to: CGPoint(
            x: base.x - perpendicular.x * headWidth / 2,
            y: base.y - perpendicular.y * headWidth / 2
        ))
        context.strokePath()
    }
}
