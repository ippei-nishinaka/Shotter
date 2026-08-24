import AppKit

/// 画面に出ているウィンドウ 1 つ分の情報。`frame` は AppKit グローバル座標。
struct CapturedWindow {
    let frame: CGRect
    let ownerName: String
}

/// ウィンドウ選択キャプチャのための一覧取得。
///
/// `CGWindowListCopyWindowInfo` は**前面から背面の順**で返ってくるので、
/// 先に見つかったものがそのまま「一番手前のウィンドウ」になる。
/// ウィンドウ名の取得には画面収録の権限が要るが、位置とアプリ名は権限なしでも取れる。
enum WindowLister {

    /// 最小サイズ。これ未満はツールチップなどの可能性が高いので無視する。
    private static let minimumSize: CGFloat = 40

    static func onScreenWindows() -> [CapturedWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let entries = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let ownPID = Int(ProcessInfo.processInfo.processIdentifier)
        var result: [CapturedWindow] = []

        for entry in entries {
            // レイヤー 0 が通常のアプリのウィンドウ。メニューバーや Dock は別レイヤー。
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  (entry[kCGWindowOwnerPID as String] as? Int) != ownPID,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
                  let cgBounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  cgBounds.width >= minimumSize, cgBounds.height >= minimumSize
            else { continue }

            let ownerName = entry[kCGWindowOwnerName as String] as? String ?? "ウィンドウ"
            result.append(
                CapturedWindow(frame: appKitFrame(fromCG: cgBounds), ownerName: ownerName)
            )
        }

        return result
    }

    /// CoreGraphics のグローバル座標（左上原点）→ AppKit のグローバル座標（左下原点）。
    private static func appKitFrame(fromCG rect: CGRect) -> CGRect {
        guard let primary = NSScreen.screens.first else { return rect }
        return CGRect(
            x: rect.minX,
            y: primary.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}
