import AppKit

/// 注釈を CGContext へ描画する。画面表示と書き出しで同じコードを通す。
@MainActor
enum AnnotationRenderer {

    /// 元画像＋注釈を 1 枚のビットマップに焼き込む。
    /// - Returns: 画像ピクセル等倍の CGImage。
    static func flatten(_ store: AnnotationStore) -> CGImage? {
        let padding = store.shadowPadding
        let width = Int(store.outputSize.width.rounded())
        let height = Int(store.outputSize.height.rounded())
        guard width > 0, height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        context.interpolationQuality = .high

        let imageRect = CGRect(
            x: padding,
            y: padding,
            width: store.imageSize.width,
            height: store.imageSize.height
        )

        if store.hasShadow {
            // 元画像のアルファ（ウィンドウの角丸など）に沿って影が落ちる。
            context.saveGState()
            ShadowStyle.apply(to: context, scale: store.pixelScale)
            context.draw(store.sourceImage, in: imageRect)
            context.restoreGState()
        } else {
            context.draw(store.sourceImage, in: imageRect)
        }

        // 注釈は左上原点で座標を持っているので、余白の分ずらしてから y 軸を反転する。
        // 注釈自体には影を付けない。
        context.saveGState()
        context.translateBy(x: padding, y: padding)
        flipToTopLeftOrigin(context, height: store.imageSize.height)
        drawAnnotations(store.annotations, in: context, environment: store.renderEnvironment)
        context.restoreGState()

        return context.makeImage()
    }

    /// 左上原点（y 下向き）のコンテキストへ CGImage を正しい向きで描く。
    /// そのまま context.draw すると CTM の影響で上下が反転してしまうため。
    nonisolated static func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: 0, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: rect.minX, y: 0, width: rect.width, height: rect.height))
        context.restoreGState()
    }

    /// 左上原点の座標系へ変換する。
    nonisolated static func flipToTopLeftOrigin(_ context: CGContext, height: CGFloat) {
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: 1, y: -1)
    }

    nonisolated static func drawAnnotations(
        _ annotations: [Annotation],
        in context: CGContext,
        environment: AnnotationRenderEnvironment
    ) {
        var environment = environment
        environment.counterNumbers = counterNumbers(in: annotations)

        let spotlights = annotations.compactMap { $0 as? SpotlightAnnotation }
        var didDrawSpotlights = false

        for annotation in annotations {
            // スポットライトは暗転が重ならないよう、最初の 1 つの位置でまとめて描く。
            if annotation is SpotlightAnnotation {
                guard !didDrawSpotlights else { continue }
                didDrawSpotlights = true
                SpotlightAnnotation.drawCombined(spotlights, in: context, environment: environment)
                continue
            }

            context.saveGState()
            annotation.draw(in: context, environment: environment)
            context.restoreGState()
        }
    }

    /// 連番の番号は配列の並び順で決まる。削除すると自動的に繰り上がる。
    nonisolated static func counterNumbers(in annotations: [Annotation]) -> [UUID: Int] {
        var numbers: [UUID: Int] = [:]
        var next = 1
        for annotation in annotations where annotation is CounterAnnotation {
            numbers[annotation.id] = next
            next += 1
        }
        return numbers
    }
}
