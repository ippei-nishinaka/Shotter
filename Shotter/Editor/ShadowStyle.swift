import CoreGraphics

/// 書き出した画像の周りに付ける影の見た目。
/// 値はすべてポイント単位で、描画時に画像の拡大率を掛けて使う。
enum ShadowStyle {

    /// ぼかしの大きさ。
    static let blurRadius: CGFloat = 16

    /// 影を落とす方向（下向き）。
    static let offsetY: CGFloat = 6

    static let opacity: CGFloat = 0.4

    /// 影が切れないように画像の周りへ足す余白。
    /// 下方向の広がり (offsetY + blurRadius) より少し大きくしておけば足りる。
    static let padding: CGFloat = 24

    static var color: CGColor {
        CGColor(srgbRed: 0, green: 0, blue: 0, alpha: opacity)
    }

    /// CGContext（左下原点）で使う影の設定を適用する。
    /// - Parameter strength: 影の強さの倍率。ぼかし・オフセット・濃さにまとめて掛ける。
    static func apply(to context: CGContext, scale: CGFloat, strength: CGFloat = 1) {
        context.setShadow(
            offset: CGSize(width: 0, height: -offsetY * scale * strength),
            blur: blurRadius * scale * strength,
            color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: min(opacity * strength, 0.85))
        )
    }
}
