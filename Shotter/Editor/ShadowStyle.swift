import CoreGraphics

/// 書き出した画像の周りに付ける影の見た目。
/// 値はすべてポイント単位で、描画時に画像の拡大率を掛けて使う。
enum ShadowStyle {

    /// ぼかしの大きさ。macOS のウィンドウの影に近い、大きめで柔らかい影にしている。
    static let blurRadius: CGFloat = 26

    /// 影を落とす方向（下向き）。
    static let offsetY: CGFloat = 12

    static let opacity: CGFloat = 0.35

    /// 影が切れないように画像の周りへ足す余白。
    static let padding: CGFloat = 48

    static var color: CGColor {
        CGColor(srgbRed: 0, green: 0, blue: 0, alpha: opacity)
    }

    /// CGContext（左下原点）で使う影の設定を適用する。
    static func apply(to context: CGContext, scale: CGFloat) {
        context.setShadow(
            offset: CGSize(width: 0, height: -offsetY * scale),
            blur: blurRadius * scale,
            color: color
        )
    }
}
