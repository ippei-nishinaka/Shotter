import AppKit

/// 始点から終点へ向かう矢印。終点側に塗りつぶしの矢じりを描く。
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

        let ux = dx / length
        let uy = dy / length

        // 矢じりの根元。軸はここまでしか引かず、先端からはみ出さないようにする。
        let neck = CGPoint(x: end.x - ux * headLength, y: end.y - uy * headLength)

        context.setStrokeColor(style.resolvedColor)
        context.setFillColor(style.resolvedColor)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(lineWidth)

        if length > headLength {
            context.move(to: start)
            context.addLine(to: neck)
            context.strokePath()
        }

        // 軸に対して垂直な単位ベクトル。
        let px = -uy
        let py = ux

        context.move(to: end)
        context.addLine(to: CGPoint(x: neck.x + px * headWidth / 2, y: neck.y + py * headWidth / 2))
        context.addLine(to: CGPoint(x: neck.x - px * headWidth / 2, y: neck.y - py * headWidth / 2))
        context.closePath()
        context.fillPath()
    }

    override func hitTest(_ point: CGPoint) -> Bool {
        Geometry.distance(from: point, toSegment: start, end) <= max(style.lineWidth, 8)
    }
}
