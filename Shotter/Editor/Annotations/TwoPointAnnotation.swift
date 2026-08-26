import AppKit

/// ドラッグの開始点と終了点だけで形が決まる注釈の共通実装。
/// 矢印・線・四角・円・モザイク・スポットライトがこれを継承する。
class TwoPointAnnotation: Annotation, DragCreatableAnnotation, ResizableAnnotation {

    var id = UUID()
    var style: AnnotationStyle
    var start: CGPoint
    var end: CGPoint

    required init(start: CGPoint, end: CGPoint, style: AnnotationStyle) {
        self.start = start
        self.end = end
        self.style = style
    }

    /// 正規化された矩形。矩形系の注釈が使う。
    var rect: CGRect {
        Geometry.rect(from: start, to: end)
    }

    var boundingBox: CGRect {
        rect.insetBy(dx: -style.lineWidth, dy: -style.lineWidth)
    }

    func draw(in context: CGContext, environment: AnnotationRenderEnvironment) {
        // サブクラスで実装する。
    }

    func hitTest(_ point: CGPoint) -> Bool {
        boundingBox.contains(point)
    }

    func copy() -> Annotation {
        let duplicate = Self(start: start, end: end, style: style)
        duplicate.id = id
        return duplicate
    }

    func translate(by offset: CGVector) {
        start = CGPoint(x: start.x + offset.dx, y: start.y + offset.dy)
        end = CGPoint(x: end.x + offset.dx, y: end.y + offset.dy)
    }

    // MARK: - ResizableAnnotation

    /// つまみの並び方。矢印・線は両端、それ以外は外接矩形の 8 点。
    enum HandleLayout {
        case endpoints
        case box
    }

    var handleLayout: HandleLayout { .box }

    var handles: [AnnotationHandle] {
        switch handleLayout {
        case .endpoints:
            return [
                AnnotationHandle(kind: .start, position: start),
                AnnotationHandle(kind: .end, position: end),
            ]
        case .box:
            let box = rect
            return [
                AnnotationHandle(kind: .topLeft, position: CGPoint(x: box.minX, y: box.minY)),
                AnnotationHandle(kind: .top, position: CGPoint(x: box.midX, y: box.minY)),
                AnnotationHandle(kind: .topRight, position: CGPoint(x: box.maxX, y: box.minY)),
                AnnotationHandle(kind: .right, position: CGPoint(x: box.maxX, y: box.midY)),
                AnnotationHandle(kind: .bottomRight, position: CGPoint(x: box.maxX, y: box.maxY)),
                AnnotationHandle(kind: .bottom, position: CGPoint(x: box.midX, y: box.maxY)),
                AnnotationHandle(kind: .bottomLeft, position: CGPoint(x: box.minX, y: box.maxY)),
                AnnotationHandle(kind: .left, position: CGPoint(x: box.minX, y: box.midY)),
            ]
        }
    }

    func moveHandle(_ kind: AnnotationHandle.Kind, to point: CGPoint, constrained: Bool) {
        switch handleLayout {
        case .endpoints:
            switch kind {
            case .start:
                start = constrained ? Geometry.snapToDiagonal(point, from: end) : point
            default:
                end = constrained ? Geometry.snapToDiagonal(point, from: start) : point
            }

        case .box:
            let box = rect
            var minX = box.minX, maxX = box.maxX
            var minY = box.minY, maxY = box.maxY

            switch kind {
            case .topLeft:     minX = point.x; minY = point.y
            case .top:         minY = point.y
            case .topRight:    maxX = point.x; minY = point.y
            case .right:       maxX = point.x
            case .bottomRight: maxX = point.x; maxY = point.y
            case .bottom:      maxY = point.y
            case .bottomLeft:  minX = point.x; maxY = point.y
            case .left:        minX = point.x
            case .start, .end, .bend: break
            }

            // rect 側で正規化されるので、反転しても破綻しない。
            start = CGPoint(x: minX, y: minY)
            end = CGPoint(x: maxX, y: maxY)
        }
    }

    // MARK: - DragCreatableAnnotation

    /// Shift ドラッグでどう固定するか。線・矢印は角度、矩形・円は正方形に揃える。
    enum ConstraintMode {
        case angle
        case square
    }

    var constraintMode: ConstraintMode { .angle }

    func updateDrag(to point: CGPoint, constrained: Bool) {
        guard constrained else {
            end = point
            return
        }
        switch constraintMode {
        case .angle:  end = Geometry.snapToDiagonal(point, from: start)
        case .square: end = Geometry.snapToSquare(point, from: start)
        }
    }

    /// 点をクリックしただけのものを弾く。
    var isValidForCommit: Bool {
        hypot(end.x - start.x, end.y - start.y) >= 4
    }
}
