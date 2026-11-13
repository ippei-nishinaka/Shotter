import CoreImage
import CoreVideo

/// 収録中にウィンドウの大きさが変わっても、動画の枠いっぱいに映るようにする。
///
/// 動画の枠（ピクセルサイズ）は収録開始時に決まり、途中で変えられない。
/// ScreenCaptureKit はウィンドウが大きくなると縮小して、小さくなると等倍のまま、
/// どちらも枠の左上に描いてくる。その描かれた範囲（contentRect）を切り出し、
/// 縦横比を保ったまま枠いっぱいに拡大縮小して中央に置き直す。
/// 開始時の大きさのまま（いちばん多い場合）は何もせずそのまま通す。
final class FrameFitter {

    private let canvasSize: CGSize
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var pool: CVPixelBufferPool?

    init(canvasSize: CGSize) {
        self.canvasSize = canvasSize
    }

    /// - Parameter contentRect: バッファの中でウィンドウが描かれている範囲（ピクセル・左上原点）。
    /// - Returns: そのまま書いてよいなら元のバッファ。枠に合わせ直したならその新しいバッファ。
    func fit(_ pixelBuffer: CVPixelBuffer, contentRect: CGRect) -> CVPixelBuffer {
        let bufferSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        let content = contentRect.intersection(CGRect(origin: .zero, size: bufferSize))

        guard !content.isEmpty, !Self.fillsCanvas(content, bufferSize: bufferSize, canvasSize: canvasSize),
              let output = makeOutputBuffer()
        else { return pixelBuffer }

        // CIImage は左下原点なので、上下を反転した位置で切り出す。
        let cropRect = CGRect(
            x: content.minX,
            y: bufferSize.height - content.maxY,
            width: content.width,
            height: content.height
        )
        let scale = min(canvasSize.width / content.width, canvasSize.height / content.height)
        let offset = CGPoint(
            x: ((canvasSize.width - content.width * scale) / 2).rounded(),
            y: ((canvasSize.height - content.height * scale) / 2).rounded()
        )

        let fitted = CIImage(cvPixelBuffer: pixelBuffer)
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))
            .applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: scale,
                kCIInputAspectRatioKey: 1,
            ])
            .transformed(by: CGAffineTransform(translationX: offset.x, y: offset.y))

        let canvas = CGRect(origin: .zero, size: canvasSize)
        let image = fitted.composited(over: CIImage(color: .black).cropped(to: canvas)).cropped(to: canvas)

        CVBufferPropagateAttachments(pixelBuffer, output)
        context.render(image, to: output)
        return output
    }

    /// 枠と同じ大きさのバッファに、ウィンドウがちょうど全面に描かれているか。
    private static func fillsCanvas(_ content: CGRect, bufferSize: CGSize, canvasSize: CGSize) -> Bool {
        let tolerance: CGFloat = 1
        return abs(bufferSize.width - canvasSize.width) <= tolerance
            && abs(bufferSize.height - canvasSize.height) <= tolerance
            && content.minX <= tolerance && content.minY <= tolerance
            && abs(content.width - canvasSize.width) <= tolerance
            && abs(content.height - canvasSize.height) <= tolerance
    }

    private func makeOutputBuffer() -> CVPixelBuffer? {
        if pool == nil {
            let attributes: [CFString: Any] = [
                // 画面収録と同じ YUV にそろえて、エンコーダへ渡す形式を混在させない。
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey: Int(canvasSize.width),
                kCVPixelBufferHeightKey: Int(canvasSize.height),
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        }
        guard let pool else { return nil }

        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }
}
