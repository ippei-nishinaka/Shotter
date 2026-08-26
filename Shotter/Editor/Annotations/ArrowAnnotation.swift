import AppKit

/// 始点から終点へ向かう矢印。矢じりの形は `style.arrowHead` で切り替える。
final class ArrowAnnotation: TwoPointAnnotation {

    /// 曲がり具合。始点→終点の線に対する垂直方向のずれ（画像ピクセル）。
    /// 0 なら直線。中央のつまみをドラッグして変える。
    var bend: CGFloat = 0

    override var handleLayout: HandleLayout { .endpoints }

    /// 二次ベジエの制御点。曲線が中点＋垂直方向 bend を通るように 2 倍にしている。
    private var controlPoint: CGPoint {
        let mid = midpoint
        guard bend != 0, let perpendicular = perpendicularUnit else { return mid }
        return CGPoint(x: mid.x + perpendicular.x * bend * 2, y: mid.y + perpendicular.y * bend * 2)
    }

    private var midpoint: CGPoint {
        CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
    }

    /// 始点→終点に対して垂直な単位ベクトル。
    private var perpendicularUnit: CGPoint? {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0 else { return nil }
        return CGPoint(x: -dy / length, y: dx / length)
    }

    /// 曲線を折れ線で近似した点列。当たり判定と外接矩形に使う。
    private func sampledPoints(count: Int = 24) -> [CGPoint] {
        guard bend != 0 else { return [start, end] }
        let control = controlPoint
        return (0...count).map { step in
            let t = CGFloat(step) / CGFloat(count)
            let inverse = 1 - t
            return CGPoint(
                x: inverse * inverse * start.x + 2 * inverse * t * control.x + t * t * end.x,
                y: inverse * inverse * start.y + 2 * inverse * t * control.y + t * t * end.y
            )
        }
    }

    override var boundingBox: CGRect {
        guard bend != 0 else { return super.boundingBox }
        var box = CGRect(origin: start, size: .zero)
        for point in sampledPoints() {
            box = box.union(CGRect(origin: point, size: .zero))
        }
        return box.insetBy(dx: -style.lineWidth, dy: -style.lineWidth)
    }

    override var handles: [AnnotationHandle] {
        var result = super.handles
        // 曲げるためのつまみは、曲線が実際に通る位置に置く。
        if let perpendicular = perpendicularUnit {
            result.append(
                AnnotationHandle(
                    kind: .bend,
                    position: CGPoint(
                        x: midpoint.x + perpendicular.x * bend,
                        y: midpoint.y + perpendicular.y * bend
                    )
                )
            )
        }
        return result
    }

    override func moveHandle(_ kind: AnnotationHandle.Kind, to point: CGPoint, constrained: Bool) {
        guard kind == .bend else {
            super.moveHandle(kind, to: point, constrained: constrained)
            return
        }
        guard let perpendicular = perpendicularUnit else { return }

        // つまんだ位置の、垂直方向の成分だけを取る。
        let delta = CGPoint(x: point.x - midpoint.x, y: point.y - midpoint.y)
        bend = delta.x * perpendicular.x + delta.y * perpendicular.y
    }

    override func copy() -> Annotation {
        let duplicate = ArrowAnnotation(start: start, end: end, style: style)
        duplicate.id = id
        duplicate.bend = bend
        return duplicate
    }

    override func draw(in context: CGContext, environment: AnnotationRenderEnvironment) {
        let lineWidth = max(style.lineWidth, 1)
        let headLength = max(lineWidth * 3.4, 12)
        let headWidth = max(lineWidth * 3.0, 10)

        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0.5 else { return }

        // 曲げているときは、矢じりの向きを終点での接線に合わせる。
        let control = controlPoint
        let tipDirection = bend == 0
            ? CGPoint(x: dx, y: dy)
            : CGPoint(x: end.x - control.x, y: end.y - control.y)
        let tipLength = max(hypot(tipDirection.x, tipDirection.y), 0.001)
        let unit = CGPoint(x: tipDirection.x / tipLength, y: tipDirection.y / tipLength)

        let tailDirection = bend == 0
            ? CGPoint(x: -dx, y: -dy)
            : CGPoint(x: start.x - control.x, y: start.y - control.y)
        let tailLength = max(hypot(tailDirection.x, tailDirection.y), 0.001)
        let tailUnit = CGPoint(x: tailDirection.x / tailLength, y: tailDirection.y / tailLength)

        context.setStrokeColor(style.resolvedColor)
        context.setFillColor(style.resolvedColor)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(lineWidth)

        switch style.arrowHead {
        case .filled:
            guard length > headLength else {
                fillHead(at: end, unit: unit, headLength: headLength, headWidth: headWidth, in: context)
                return
            }
            strokeShaft(
                from: start,
                to: neck(from: end, towards: unit, by: headLength),
                control: control,
                in: context
            )
            fillHead(at: end, unit: unit, headLength: headLength, headWidth: headWidth, in: context)

        case .open:
            // 開いた矢じりは軸を先端まで引いてよい。
            strokeShaft(from: start, to: end, control: control, in: context)
            strokeHead(at: end, unit: unit, headLength: headLength, headWidth: headWidth, in: context)

        case .double:
            if length > headLength * 2 {
                strokeShaft(
                    from: neck(from: start, towards: tailUnit, by: headLength),
                    to: neck(from: end, towards: unit, by: headLength),
                    control: control,
                    in: context
                )
            }
            fillHead(at: end, unit: unit, headLength: headLength, headWidth: headWidth, in: context)
            fillHead(at: start, unit: tailUnit, headLength: headLength, headWidth: headWidth, in: context)
        }
    }

    override func hitTest(_ point: CGPoint) -> Bool {
        let slack = max(style.lineWidth, 8)
        let points = sampledPoints()
        for index in 0..<(points.count - 1) {
            if Geometry.distance(from: point, toSegment: points[index], points[index + 1]) <= slack {
                return true
            }
        }
        return false
    }

    // MARK: - Private

    /// 矢じりの根元。軸はここまでしか引かず、先端からはみ出さないようにする。
    private func neck(from tip: CGPoint, towards unit: CGPoint, by length: CGFloat) -> CGPoint {
        CGPoint(x: tip.x - unit.x * length, y: tip.y - unit.y * length)
    }

    /// 曲げているときは二次ベジエ、そうでなければ直線で軸を引く。
    private func strokeShaft(
        from origin: CGPoint,
        to destination: CGPoint,
        control: CGPoint,
        in context: CGContext
    ) {
        context.move(to: origin)
        if bend == 0 {
            context.addLine(to: destination)
        } else {
            context.addQuadCurve(to: destination, control: control)
        }
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
