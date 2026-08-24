import CoreGraphics

enum ImageMask {

    /// macOS のウィンドウの角丸の半径（ポイント）。
    /// ウィンドウキャプチャで四隅に背景が写り込むのを防ぐために使う。
    static let windowCornerRadius: CGFloat = 10

    /// 角を丸くくり抜く。四隅は透明になる。
    /// - Parameter radius: ピクセル単位の半径。
    static func roundedCorners(_ image: CGImage, radius: CGFloat) -> CGImage? {
        let width = image.width
        let height = image.height
        guard radius > 0, width > 0, height > 0,
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

        let rect = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        let clamped = min(radius, min(rect.width, rect.height) / 2)

        context.interpolationQuality = .high
        context.addPath(
            CGPath(roundedRect: rect, cornerWidth: clamped, cornerHeight: clamped, transform: nil)
        )
        context.clip()
        context.draw(image, in: rect)

        return context.makeImage()
    }
}
