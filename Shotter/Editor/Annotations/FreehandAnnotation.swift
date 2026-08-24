import AppKit

/// フリーハンドの線。ドラッグ中の通過点を溜めて、中点を通る二次ベジエで滑らかに描く。
final class FreehandAnnotation: Annotation, DragCreatableAnnotation {

    var id = UUID()
    var style: AnnotationStyle
    private(set) var points: [CGPoint]

    /// 点を詰め込みすぎないための最小間隔（画像ピクセル）。
    private let minimumSpacing: CGFloat = 1.5

    init(points: [CGPoint], style: AnnotationStyle) {
        self.points = points
        self.style = style
    }

    convenience init(start: CGPoint, style: AnnotationStyle) {
        self.init(points: [start], style: style)
    }

    var boundingBox: CGRect {
        guard let first = points.first else { return .zero }
        var box = CGRect(origin: first, size: .zero)
        for point in points.dropFirst() {
            box = box.union(CGRect(origin: point, size: .zero))
        }
        return box.insetBy(dx: -style.lineWidth, dy: -style.lineWidth)
    }

    func draw(in context: CGContext, environment: AnnotationRenderEnvironment) {
        let lineWidth = max(style.lineWidth, 1)
        context.setStrokeColor(style.resolvedColor)
        context.setFillColor(style.resolvedColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        guard points.count > 1 else {
            // 点を 1 つ打っただけのときは丸を置く。
            guard let point = points.first else { return }
            context.fillEllipse(in: CGRect(
                x: point.x - lineWidth / 2,
                y: point.y - lineWidth / 2,
                width: lineWidth,
                height: lineWidth
            ))
            return
        }

        let path = CGMutablePath()
        path.move(to: points[0])

        if points.count == 2 {
            path.addLine(to: points[1])
        } else {
            // 各点を制御点にして、隣り合う点の中点どうしを結ぶと角が取れる。
            for index in 1..<(points.count - 1) {
                let control = points[index]
                let midpoint = CGPoint(
                    x: (control.x + points[index + 1].x) / 2,
                    y: (control.y + points[index + 1].y) / 2
                )
                path.addQuadCurve(to: midpoint, control: control)
            }
            path.addLine(to: points[points.count - 1])
        }

        context.addPath(path)
        context.strokePath()
    }

    func hitTest(_ point: CGPoint) -> Bool {
        let slack = max(style.lineWidth, 8)
        guard points.count > 1 else {
            guard let only = points.first else { return false }
            return hypot(point.x - only.x, point.y - only.y) <= slack
        }
        for index in 0..<(points.count - 1) {
            if Geometry.distance(from: point, toSegment: points[index], points[index + 1]) <= slack {
                return true
            }
        }
        return false
    }

    func copy() -> Annotation {
        let duplicate = FreehandAnnotation(points: points, style: style)
        duplicate.id = id
        return duplicate
    }

    func translate(by offset: CGVector) {
        points = points.map { CGPoint(x: $0.x + offset.dx, y: $0.y + offset.dy) }
    }

    // MARK: - DragCreatableAnnotation

    func updateDrag(to point: CGPoint, constrained: Bool) {
        guard let last = points.last else {
            points = [point]
            return
        }
        guard hypot(point.x - last.x, point.y - last.y) >= minimumSpacing else { return }
        points.append(point)
    }

    var isValidForCommit: Bool {
        points.count >= 2
    }
}
