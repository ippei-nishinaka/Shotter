import AppKit

/// 選択中のツールから、ドラッグで作る注釈のインスタンスを生成する。
/// ツールを 1 つ実装するたびにここへ 1 件足していく。
@MainActor
enum AnnotationFactory {

    static func makeDraft(at point: CGPoint, store: AnnotationStore) -> (any DragCreatableAnnotation)? {
        let style = store.currentStyle

        switch store.tool {
        case .arrow:
            return ArrowAnnotation(start: point, end: point, style: style)

        case .rectangle:
            return RectangleAnnotation(start: point, end: point, style: style)

        case .filledRectangle:
            let annotation = RectangleAnnotation(start: point, end: point, style: style)
            annotation.isFilled = true
            return annotation

        case .ellipse:
            return EllipseAnnotation(start: point, end: point, style: style)

        case .line:
            return LineAnnotation(start: point, end: point, style: style)

        case .freehand:
            return FreehandAnnotation(start: point, style: style)

        case .highlight:
            return HighlightAnnotation(start: point, end: point, style: style)

        case .pixelate:
            let annotation = PixelateAnnotation(start: point, end: point, style: style)
            annotation.mode = store.pixelateMode
            return annotation

        case .spotlight:
            return SpotlightAnnotation(start: point, end: point, style: style)

        case .counter:
            return CounterAnnotation(center: point, style: style)

        case .select, .text:
            // .text はクリックでインライン入力を開始するため、ここでは生成しない。
            return nil
        }
    }
}
