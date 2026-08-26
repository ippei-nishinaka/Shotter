#if DEBUG
import AppKit

/// 実装済みの注釈を一通り並べたサンプルを流し込む。
/// ツールを 1 つ実装するたびにここへ 1 行足し、描画結果を目視確認する。
@MainActor
enum DebugSamples {

    /// 1600 × 1000 のサンプル画像を 4 列 × 4 行に区切って配置する。
    private static let columns = 4
    private static let cellSize = CGSize(width: 400, height: 250)

    /// ツールごとのオプション（矢印の形・線種・角丸）の描画確認用。
    static func populateOptionVariants(_ store: AnnotationStore) {
        func style(_ color: NSColor, _ width: CGFloat = 6) -> AnnotationStyle {
            AnnotationStyle(color: color, lineWidth: width, fontSize: 32)
        }

        // 矢印 3 種
        for (index, head) in ArrowHeadStyle.allCases.enumerated() {
            var arrowStyle = style(.systemRed)
            arrowStyle.arrowHead = head
            let y = 90 + CGFloat(index) * 90
            store.add(ArrowAnnotation(
                start: CGPoint(x: 80, y: y),
                end: CGPoint(x: 420, y: y),
                style: arrowStyle
            ))
        }

        // 曲げた矢印（bend の正負）
        for (index, bend) in [CGFloat(70), -70].enumerated() {
            var curved = style(.systemOrange)
            curved.arrowHead = .filled
            let arrow = ArrowAnnotation(
                start: CGPoint(x: 80, y: 640 + CGFloat(index) * 140),
                end: CGPoint(x: 420, y: 640 + CGFloat(index) * 140),
                style: curved
            )
            arrow.bend = bend
            store.add(arrow)
        }

        // 線 4 種
        for (index, dash) in StrokeDashStyle.allCases.enumerated() {
            var lineStyle = style(.systemBlue, 5)
            lineStyle.dash = dash
            let y = 80 + CGFloat(index) * 70
            store.add(LineAnnotation(
                start: CGPoint(x: 540, y: y),
                end: CGPoint(x: 940, y: y),
                style: lineStyle
            ))
        }

        // 角丸あり／なしの四角とハイライト
        for (index, radius) in [CGFloat(0), 24].enumerated() {
            let x = 1060 + CGFloat(index) * 250

            var outline = style(.systemGreen)
            outline.cornerRadius = radius
            store.add(RectangleAnnotation(
                start: CGPoint(x: x, y: 70),
                end: CGPoint(x: x + 200, y: 200),
                style: outline
            ))

            var block = style(.systemPurple)
            block.cornerRadius = radius
            let filled = RectangleAnnotation(
                start: CGPoint(x: x, y: 240),
                end: CGPoint(x: x + 200, y: 370),
                style: block
            )
            filled.isFilled = true
            store.add(filled)

            var highlight = style(.systemYellow)
            highlight.cornerRadius = radius
            store.add(HighlightAnnotation(
                start: CGPoint(x: x, y: 410),
                end: CGPoint(x: x + 200, y: 500),
                style: highlight
            ))
        }

        // テキストの書体
        var bold = style(.white)
        bold.text.isBold = true
        bold.fontSize = 40
        store.add(TextAnnotation(origin: CGPoint(x: 80, y: 420), text: "太字 Bold", style: bold, maxWidth: 400))

        var italic = style(.white)
        italic.text.isItalic = true
        italic.fontSize = 40
        store.add(TextAnnotation(origin: CGPoint(x: 80, y: 490), text: "斜体 Italic", style: italic, maxWidth: 400))

        var struck = style(.white)
        struck.text.isStrikethrough = true
        struck.text.isUnderlined = true
        struck.fontSize = 40
        store.add(TextAnnotation(origin: CGPoint(x: 80, y: 560), text: "下線と取消線", style: struck, maxWidth: 400))
    }

    static func populate(_ store: AnnotationStore, includeSpotlight: Bool = false) {
        var slot = 0
        func nextCell() -> CGRect {
            defer { slot += 1 }
            let column = slot % columns
            let row = slot / columns
            return CGRect(
                x: CGFloat(column) * cellSize.width,
                y: CGFloat(row) * cellSize.height,
                width: cellSize.width,
                height: cellSize.height
            ).insetBy(dx: 40, dy: 40)
        }

        func style(_ color: NSColor, _ width: CGFloat = 6) -> AnnotationStyle {
            AnnotationStyle(color: color, lineWidth: width, fontSize: 32)
        }

        // 矢印
        var cell = nextCell()
        store.add(ArrowAnnotation(
            start: CGPoint(x: cell.minX, y: cell.minY),
            end: CGPoint(x: cell.maxX, y: cell.maxY),
            style: style(.systemRed)
        ))

        cell = nextCell()
        store.add(ArrowAnnotation(
            start: CGPoint(x: cell.maxX, y: cell.minY),
            end: CGPoint(x: cell.minX, y: cell.maxY),
            style: style(.systemYellow, 2)
        ))

        // 四角（枠）
        cell = nextCell()
        store.add(RectangleAnnotation(
            start: cell.origin,
            end: CGPoint(x: cell.maxX, y: cell.maxY),
            style: style(.systemBlue)
        ))

        // 四角（塗り）
        cell = nextCell()
        let filled = RectangleAnnotation(
            start: cell.origin,
            end: CGPoint(x: cell.maxX, y: cell.maxY),
            style: style(.systemGreen)
        )
        filled.isFilled = true
        store.add(filled)

        // 円（枠）
        cell = nextCell()
        store.add(EllipseAnnotation(
            start: cell.origin,
            end: CGPoint(x: cell.maxX, y: cell.maxY),
            style: style(.systemOrange)
        ))

        // 円（塗り）
        cell = nextCell()
        let filledEllipse = EllipseAnnotation(
            start: cell.origin,
            end: CGPoint(x: cell.maxX, y: cell.maxY),
            style: style(.systemPurple)
        )
        filledEllipse.isFilled = true
        store.add(filledEllipse)

        // 線
        cell = nextCell()
        store.add(LineAnnotation(
            start: CGPoint(x: cell.minX, y: cell.maxY),
            end: CGPoint(x: cell.maxX, y: cell.minY),
            style: style(.white, 4)
        ))

        // フリーハンド（サイン波）
        cell = nextCell()
        let wave = stride(from: 0.0, through: 1.0, by: 0.02).map { t -> CGPoint in
            CGPoint(
                x: cell.minX + cell.width * t,
                y: cell.midY - sin(t * .pi * 3) * cell.height * 0.4
            )
        }
        store.add(FreehandAnnotation(points: wave, style: style(.black, 5)))

        // ハイライト（蛍光ペン）
        cell = nextCell()
        store.add(HighlightAnnotation(
            start: CGPoint(x: cell.minX, y: cell.midY - 30),
            end: CGPoint(x: cell.maxX, y: cell.midY + 30),
            style: style(.systemYellow)
        ))

        // テキスト（1 行・複数行・サイズ違い）
        cell = nextCell()
        store.add(TextAnnotation(
            origin: CGPoint(x: cell.minX, y: cell.minY),
            text: "サンプルテキスト Abc 123",
            style: style(.white, 6),
            maxWidth: cell.width
        ))

        cell = nextCell()
        var large = style(.systemYellow)
        large.fontSize = 56
        store.add(TextAnnotation(
            origin: CGPoint(x: cell.minX, y: cell.minY),
            text: "大きい文字\n2 行目",
            style: large,
            maxWidth: cell.width
        ))

        // モザイク
        cell = nextCell()
        let mosaic = PixelateAnnotation(
            start: cell.origin,
            end: CGPoint(x: cell.maxX, y: cell.maxY),
            style: style(.systemRed)
        )
        mosaic.mode = .pixelate
        store.add(mosaic)

        // ぼかし
        cell = nextCell()
        let blur = PixelateAnnotation(
            start: cell.origin,
            end: CGPoint(x: cell.maxX, y: cell.maxY),
            style: style(.systemRed)
        )
        blur.mode = .blur
        store.add(blur)

        // 連番（自動採番の確認のため 3 つ並べる）
        cell = nextCell()
        for index in 0..<3 {
            var counterStyle = style(.systemBlue)
            counterStyle.fontSize = 34
            store.add(CounterAnnotation(
                center: CGPoint(x: cell.minX + 50 + CGFloat(index) * 90, y: cell.midY),
                style: counterStyle
            ))
        }

        // スポットライト（画像全体が暗くなるので、指定時のみ）
        if includeSpotlight {
            cell = nextCell()
            store.add(SpotlightAnnotation(
                start: cell.origin,
                end: CGPoint(x: cell.maxX, y: cell.maxY),
                style: style(.white)
            ))
        }
    }
}
#endif
