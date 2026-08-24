import AppKit

/// AppKit の画面座標系（原点が左下・メインディスプレイ基準）と
/// CoreGraphics の表示座標系（原点が左上）の相互変換をまとめたもの。
enum ScreenGeometry {

    /// AppKit グローバル座標の矩形を CoreGraphics グローバル座標（左上原点）に変換する。
    static func cgGlobalRect(fromAppKit rect: CGRect) -> CGRect {
        guard let primary = NSScreen.screens.first else { return rect }
        return CGRect(
            x: rect.minX,
            y: primary.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// 2 点から正規化された矩形（負の幅/高さを持たない）を作る。
    static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
    }
}

extension NSScreen {

    /// ScreenCaptureKit / CoreGraphics で使うディスプレイ ID。
    var displayID: CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (deviceDescription[key] as? NSNumber)?.uint32Value
    }
}

extension NSView {

    /// 指定の型を持つ最初の子孫ビューを深さ優先で探す。
    func firstDescendant<T: NSView>(ofType type: T.Type) -> T? {
        for subview in subviews {
            if let match = subview as? T { return match }
            if let match = subview.firstDescendant(ofType: type) { return match }
        }
        return nil
    }
}
