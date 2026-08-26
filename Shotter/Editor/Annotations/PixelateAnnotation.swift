import AppKit
import CoreImage

/// 指定範囲を下地の画像ごとモザイク／ぼかしで潰す。機密情報を隠す用途。
final class PixelateAnnotation: TwoPointAnnotation {

    enum Mode: String, CaseIterable, Identifiable {
        case pixelate
        case blur

        var id: String { rawValue }

        var title: String {
            switch self {
            case .pixelate: return "モザイク"
            case .blur:     return "ぼかし"
            }
        }

        var symbolName: String {
            switch self {
            case .pixelate: return "square.grid.3x3.fill"
            case .blur:     return "drop.fill"
            }
        }
    }

    var mode: Mode = .pixelate

    override var constraintMode: ConstraintMode { .square }

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private var cachedImage: CGImage?
    private var cacheKey: String = ""

    override func draw(in context: CGContext, environment: AnnotationRenderEnvironment) {
        let target = rect.integral
        guard target.width >= 1, target.height >= 1 else { return }

        guard let processed = processedImage(for: target, environment: environment) else { return }
        AnnotationRenderer.drawImage(processed, in: target, context: context)
    }

    override func hitTest(_ point: CGPoint) -> Bool {
        rect.contains(point)
    }

    override func updateDrag(to point: CGPoint, constrained: Bool) {
        super.updateDrag(to: point, constrained: constrained)
        cachedImage = nil
    }

    override func copy() -> Annotation {
        let duplicate = PixelateAnnotation(start: start, end: end, style: style)
        duplicate.id = id
        duplicate.mode = mode
        return duplicate
    }

    // MARK: - Private

    private func processedImage(
        for target: CGRect,
        environment: AnnotationRenderEnvironment
    ) -> CGImage? {
        let key = "\(mode.rawValue)-\(style.pixelateIntensity)-\(target)"
        if key == cacheKey, let cachedImage { return cachedImage }

        // CGImage の座標系は左上原点なので、注釈の座標をそのまま切り出しに使える。
        let bounds = CGRect(origin: .zero, size: environment.imageSize)
        let cropRect = target.intersection(bounds)
        guard cropRect.width >= 1, cropRect.height >= 1,
              let cropped = environment.sourceImage.cropping(to: cropRect)
        else { return nil }

        let input = CIImage(cgImage: cropped)
        let output: CIImage?

        switch mode {
        case .pixelate:
            // ブロックサイズは領域の短辺に合わせ、小さい領域でも粒が見えるようにする。
            let blockSize = max(min(cropRect.width, cropRect.height) / 12, 8) * style.pixelateIntensity
            output = input
                .clampedToExtent()
                .applyingFilter("CIPixellate", parameters: [
                    kCIInputScaleKey: blockSize,
                    kCIInputCenterKey: CIVector(x: input.extent.minX, y: input.extent.minY),
                ])
                .cropped(to: input.extent)

        case .blur:
            let radius = max(min(cropRect.width, cropRect.height) / 10, 6) * style.pixelateIntensity
            output = input
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                .cropped(to: input.extent)
        }

        guard let output,
              let image = Self.ciContext.createCGImage(output, from: input.extent)
        else { return nil }

        cachedImage = image
        cacheKey = key
        return image
    }
}
