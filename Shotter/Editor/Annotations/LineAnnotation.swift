import AppKit

/// 直線。Shift で 45 度刻みに角度が固定される。
final class LineAnnotation: TwoPointAnnotation {

    override var handleLayout: HandleLayout { .endpoints }

    override func draw(in context: CGContext, environment: AnnotationRenderEnvironment) {
        let lineWidth = max(style.lineWidth, 1)

        context.setStrokeColor(style.resolvedColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()
    }

    override func hitTest(_ point: CGPoint) -> Bool {
        Geometry.distance(from: point, toSegment: start, end) <= max(style.lineWidth, 8)
    }
}
