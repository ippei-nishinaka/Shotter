import CoreGraphics
import Foundation

enum Geometry {

    /// 点と線分の最短距離。線ベースの注釈のヒットテストに使う。
    static func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy

        guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }

        var t = ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared
        t = min(max(t, 0), 1)

        let projected = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
        return hypot(point.x - projected.x, point.y - projected.y)
    }

    /// 2 点から正規化された矩形を作る。
    static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
    }

    /// Shift ドラッグ時の角度スナップ。始点からの向きを 45 度刻みに丸める。
    static func snapToDiagonal(_ point: CGPoint, from origin: CGPoint) -> CGPoint {
        let dx = point.x - origin.x
        let dy = point.y - origin.y
        let length = hypot(dx, dy)
        guard length > 0 else { return point }

        let step = CGFloat.pi / 4
        let angle = (atan2(dy, dx) / step).rounded() * step
        return CGPoint(x: origin.x + cos(angle) * length, y: origin.y + sin(angle) * length)
    }

    /// Shift ドラッグ時の正方形スナップ。符号を保ったまま縦横を揃える。
    static func snapToSquare(_ point: CGPoint, from origin: CGPoint) -> CGPoint {
        let dx = point.x - origin.x
        let dy = point.y - origin.y
        let side = max(abs(dx), abs(dy))
        return CGPoint(
            x: origin.x + (dx < 0 ? -side : side),
            y: origin.y + (dy < 0 ? -side : side)
        )
    }

    /// 点を矩形の内側に収める。
    static func clamp(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, rect.minX), rect.maxX),
            y: min(max(point.y, rect.minY), rect.maxY)
        )
    }
}
