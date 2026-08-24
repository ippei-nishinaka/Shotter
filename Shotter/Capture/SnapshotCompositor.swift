import AppKit

/// フリーズ済みのディスプレイ画像から、選択矩形の部分だけを切り出す。
/// 選択範囲が複数ディスプレイにまたがる場合は 1 枚に合成する。
enum SnapshotCompositor {

    /// - Parameter globalRect: AppKit グローバル座標（左下原点・ポイント単位）の選択範囲。
    static func crop(_ snapshots: [DisplaySnapshot], to globalRect: CGRect) -> CGImage? {
        let targets = snapshots.filter { $0.frame.intersects(globalRect) }
        guard !targets.isEmpty else { return nil }

        // 1 枚に収まっている場合は再サンプリングせずそのまま切り出す。
        if targets.count == 1, let only = targets.first, only.frame.contains(globalRect) {
            return only.image.cropping(to: pixelRect(of: globalRect, in: only))
        }

        let scale = targets.map(\.scale).max() ?? 2
        let width = Int((globalRect.width * scale).rounded())
        let height = Int((globalRect.height * scale).rounded())
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

        for snapshot in targets {
            let overlap = snapshot.frame.intersection(globalRect)
            guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { continue }
            guard let piece = snapshot.image.cropping(to: pixelRect(of: overlap, in: snapshot)) else { continue }

            // CGContext は左下原点なので、AppKit 座標の差分をそのまま使える。
            let destination = CGRect(
                x: (overlap.minX - globalRect.minX) * scale,
                y: (overlap.minY - globalRect.minY) * scale,
                width: overlap.width * scale,
                height: overlap.height * scale
            )
            context.draw(piece, in: destination)
        }

        return context.makeImage()
    }

    /// AppKit グローバル座標の矩形を、そのディスプレイ画像内のピクセル矩形（左上原点）に変換する。
    private static func pixelRect(of globalRect: CGRect, in snapshot: DisplaySnapshot) -> CGRect {
        let local = CGRect(
            x: globalRect.minX - snapshot.frame.minX,
            y: snapshot.frame.maxY - globalRect.maxY,
            width: globalRect.width,
            height: globalRect.height
        )

        let pixels = CGRect(
            x: local.minX * snapshot.scale,
            y: local.minY * snapshot.scale,
            width: local.width * snapshot.scale,
            height: local.height * snapshot.scale
        ).integral

        let bounds = CGRect(x: 0, y: 0, width: snapshot.image.width, height: snapshot.image.height)
        return pixels.intersection(bounds)
    }
}
