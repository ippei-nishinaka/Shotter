import AppKit

/// 指定範囲以外を暗くして注目させる。
///
/// 複数置いたときに暗さが重ならないよう、暗転レイヤーは
/// `AnnotationRenderer` がまとめて 1 枚だけ描く（`drawCombined`）。
final class SpotlightAnnotation: TwoPointAnnotation {

    /// 周囲を覆う暗さ。
    static let dimAlpha: CGFloat = 0.55

    override var constraintMode: ConstraintMode { .square }

    override func draw(in context: CGContext, environment: AnnotationRenderEnvironment) {
        // 単体では描かない。描画は drawCombined が担当する。
    }

    override func hitTest(_ point: CGPoint) -> Bool {
        rect.contains(point)
    }

    override func copy() -> Annotation {
        let duplicate = SpotlightAnnotation(start: start, end: end, style: style)
        duplicate.id = id
        return duplicate
    }

    /// 画像全体を暗くし、各スポットライトの矩形だけを even-odd で抜く。
    nonisolated static func drawCombined(
        _ spotlights: [SpotlightAnnotation],
        in context: CGContext,
        environment: AnnotationRenderEnvironment
    ) {
        let holes = spotlights.map { $0.rect }.filter { $0.width >= 1 && $0.height >= 1 }
        guard !holes.isEmpty else { return }

        let path = CGMutablePath()
        path.addRect(CGRect(origin: .zero, size: environment.imageSize))
        for (index, hole) in holes.enumerated() {
            let radius = min(spotlights[index].style.cornerRadius, min(hole.width, hole.height) / 2)
            path.addRoundedRect(in: hole, cornerWidth: radius, cornerHeight: radius)
        }

        context.saveGState()
        context.addPath(path)
        context.setFillColor(CGColor(gray: 0, alpha: dimAlpha))
        context.fillPath(using: .evenOdd)
        context.restoreGState()
    }
}
