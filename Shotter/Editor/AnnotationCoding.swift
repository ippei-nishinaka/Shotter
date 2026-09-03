import AppKit

/// NSColor は Codable ではないので、sRGB 成分に分解して保存する。
struct CodableColor: Codable, Equatable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var alpha: CGFloat

    init(_ color: NSColor) {
        let resolved = color.usingColorSpace(.sRGB) ?? color
        red = resolved.redComponent
        green = resolved.greenComponent
        blue = resolved.blueComponent
        alpha = resolved.alphaComponent
    }

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

extension AnnotationStyle: Codable {
    private enum CodingKeys: String, CodingKey {
        case color, lineWidth, fontSize, arrowHead, dash, cornerRadius, text, pixelateMode, pixelateIntensity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        color = try container.decode(CodableColor.self, forKey: .color).nsColor
        lineWidth = try container.decode(CGFloat.self, forKey: .lineWidth)
        fontSize = try container.decode(CGFloat.self, forKey: .fontSize)
        arrowHead = try container.decode(ArrowHeadStyle.self, forKey: .arrowHead)
        dash = try container.decode(StrokeDashStyle.self, forKey: .dash)
        cornerRadius = try container.decode(CGFloat.self, forKey: .cornerRadius)
        text = try container.decode(TextTraits.self, forKey: .text)
        pixelateMode = try container.decode(PixelateAnnotation.Mode.self, forKey: .pixelateMode)
        pixelateIntensity = try container.decode(CGFloat.self, forKey: .pixelateIntensity)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(CodableColor(color), forKey: .color)
        try container.encode(lineWidth, forKey: .lineWidth)
        try container.encode(fontSize, forKey: .fontSize)
        try container.encode(arrowHead, forKey: .arrowHead)
        try container.encode(dash, forKey: .dash)
        try container.encode(cornerRadius, forKey: .cornerRadius)
        try container.encode(text, forKey: .text)
        try container.encode(pixelateMode, forKey: .pixelateMode)
        try container.encode(pixelateIntensity, forKey: .pixelateIntensity)
    }
}

/// 注釈 1 つを丸ごと JSON へ書き出すための表現。
///
/// `Annotation` はプロトコルなので直接 Codable にできない。
/// 種類ごとに必要な値だけを持たせ、`makeAnnotation()` で元のクラスへ戻す。
enum AnnotationSnapshot: Codable {
    case arrow(id: UUID, style: AnnotationStyle, start: CGPoint, end: CGPoint, bend: CGFloat)
    case rectangle(id: UUID, style: AnnotationStyle, start: CGPoint, end: CGPoint, isFilled: Bool)
    case ellipse(id: UUID, style: AnnotationStyle, start: CGPoint, end: CGPoint, isFilled: Bool)
    case line(id: UUID, style: AnnotationStyle, start: CGPoint, end: CGPoint)
    case highlight(id: UUID, style: AnnotationStyle, start: CGPoint, end: CGPoint)
    case pixelate(id: UUID, style: AnnotationStyle, start: CGPoint, end: CGPoint)
    case spotlight(id: UUID, style: AnnotationStyle, start: CGPoint, end: CGPoint)
    case freehand(id: UUID, style: AnnotationStyle, points: [CGPoint])
    case text(id: UUID, style: AnnotationStyle, origin: CGPoint, text: String, maxWidth: CGFloat)
    case counter(id: UUID, style: AnnotationStyle, center: CGPoint)

    init?(_ annotation: Annotation) {
        switch annotation {
        case let a as ArrowAnnotation:
            self = .arrow(id: a.id, style: a.style, start: a.start, end: a.end, bend: a.bend)
        case let a as RectangleAnnotation:
            self = .rectangle(id: a.id, style: a.style, start: a.start, end: a.end, isFilled: a.isFilled)
        case let a as EllipseAnnotation:
            self = .ellipse(id: a.id, style: a.style, start: a.start, end: a.end, isFilled: a.isFilled)
        case let a as LineAnnotation:
            self = .line(id: a.id, style: a.style, start: a.start, end: a.end)
        case let a as HighlightAnnotation:
            self = .highlight(id: a.id, style: a.style, start: a.start, end: a.end)
        case let a as PixelateAnnotation:
            self = .pixelate(id: a.id, style: a.style, start: a.start, end: a.end)
        case let a as SpotlightAnnotation:
            self = .spotlight(id: a.id, style: a.style, start: a.start, end: a.end)
        case let a as FreehandAnnotation:
            self = .freehand(id: a.id, style: a.style, points: a.points)
        case let a as TextAnnotation:
            self = .text(id: a.id, style: a.style, origin: a.origin, text: a.text, maxWidth: a.maxWidth)
        case let a as CounterAnnotation:
            self = .counter(id: a.id, style: a.style, center: a.center)
        default:
            return nil
        }
    }

    func makeAnnotation() -> Annotation {
        switch self {
        case let .arrow(id, style, start, end, bend):
            let annotation = ArrowAnnotation(start: start, end: end, style: style)
            annotation.id = id
            annotation.bend = bend
            return annotation

        case let .rectangle(id, style, start, end, isFilled):
            let annotation = RectangleAnnotation(start: start, end: end, style: style)
            annotation.id = id
            annotation.isFilled = isFilled
            return annotation

        case let .ellipse(id, style, start, end, isFilled):
            let annotation = EllipseAnnotation(start: start, end: end, style: style)
            annotation.id = id
            annotation.isFilled = isFilled
            return annotation

        case let .line(id, style, start, end):
            let annotation = LineAnnotation(start: start, end: end, style: style)
            annotation.id = id
            return annotation

        case let .highlight(id, style, start, end):
            let annotation = HighlightAnnotation(start: start, end: end, style: style)
            annotation.id = id
            return annotation

        case let .pixelate(id, style, start, end):
            let annotation = PixelateAnnotation(start: start, end: end, style: style)
            annotation.id = id
            return annotation

        case let .spotlight(id, style, start, end):
            let annotation = SpotlightAnnotation(start: start, end: end, style: style)
            annotation.id = id
            return annotation

        case let .freehand(id, style, points):
            let annotation = FreehandAnnotation(points: points, style: style)
            annotation.id = id
            return annotation

        case let .text(id, style, origin, text, maxWidth):
            let annotation = TextAnnotation(origin: origin, text: text, style: style, maxWidth: maxWidth)
            annotation.id = id
            return annotation

        case let .counter(id, style, center):
            let annotation = CounterAnnotation(center: center, style: style)
            annotation.id = id
            return annotation
        }
    }
}

/// 1 枚分の編集状態をまるごと書き出したもの。履歴の JSON サイドカーに保存する。
struct AnnotationDocument: Codable {
    var annotations: [AnnotationSnapshot]
    var hasShadow: Bool
    var shadowStrength: CGFloat
    var hasRoundedCorners: Bool
    var cornerRoundness: CGFloat
    var counterStartNumber: Int
}
