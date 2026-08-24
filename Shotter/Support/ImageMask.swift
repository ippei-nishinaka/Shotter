import CoreGraphics

enum ImageMask {

    /// ウィンドウの実際の形が取れなかったときに使う、角丸半径の目安（ポイント）。
    ///
    /// macOS 26 でウィンドウの角丸が大きくなったため、OS で値を変えている。
    /// 実測値: macOS 26 では 20.0〜20.9 pt（複数のウィンドウ・複数の行で計測）。
    static var fallbackWindowCornerRadius: CGFloat {
        if #available(macOS 26.0, *) { return 20 }
        return 10
    }

    /// ウィンドウの実際の形（アルファ）で切り抜く。
    ///
    /// ScreenCaptureKit から取得したウィンドウ画像のアルファをマスクとして使うので、
    /// 角丸の半径を推測する必要がなく、OS のバージョンにも依存しない。
    static func applying(alphaMask: CGImage, to image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
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

        let rect = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        context.interpolationQuality = .high
        context.draw(image, in: rect)

        // destinationIn は「マスク側が不透明なところだけ残す」合成。
        context.setBlendMode(.destinationIn)
        context.draw(alphaMask, in: rect)

        return context.makeImage()
    }

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
