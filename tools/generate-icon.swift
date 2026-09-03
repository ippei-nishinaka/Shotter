#!/usr/bin/env swift
//
// Shotter のアプリアイコンを生成する。
// 実行すると build/AppIcon.iconset/ 以下に必要な全サイズの PNG を書き出す。
// その後 `iconutil -c icns` で .icns に固める（build.sh 側から呼ぶ）。
//
import AppKit
import CoreGraphics

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024),
]

let outputDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/AppIcon.iconset")
try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

func draw(pixels: Int) -> CGImage? {
    let size = CGFloat(pixels)
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: nil,
            width: pixels,
            height: pixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
    else { return nil }

    context.interpolationQuality = .high

    // --- 背景の角丸四角（グラデーション） -------------------------------------
    let cornerRadius = size * 0.224
    let backgroundRect = CGRect(x: 0, y: 0, width: size, height: size)
    let backgroundPath = CGPath(roundedRect: backgroundRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    context.saveGState()
    context.addPath(backgroundPath)
    context.clip()

    let colors = [
        CGColor(red: 0.36, green: 0.55, blue: 0.98, alpha: 1),
        CGColor(red: 0.47, green: 0.35, blue: 0.92, alpha: 1),
    ]
    guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: [0, 1]) else { return nil }
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: size),
        end: CGPoint(x: size, y: 0),
        options: []
    )

    // 上部にごく薄いハイライトを重ね、ガラスっぽい質感を足す。
    let highlight = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.16),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0),
        ] as CFArray,
        locations: [0, 1]
    )
    if let highlight {
        context.drawLinearGradient(
            highlight,
            start: CGPoint(x: size / 2, y: size),
            end: CGPoint(x: size / 2, y: size * 0.35),
            options: []
        )
    }
    context.restoreGState()

    // --- メニューバーと同じ camera シンボルを、白でくり抜いて重ねる -----------
    // メニューバーのアイコン（StatusItemController）と同じ形にして統一感を出す。
    // 色を付けているのはここ（背景のグラデーション）だけで、形は同じ。
    guard let baseSymbol = NSImage(systemSymbolName: "camera", accessibilityDescription: nil) else {
        return context.makeImage()
    }
    let config = NSImage.SymbolConfiguration(pointSize: size * 0.46, weight: .medium)
    guard let symbol = baseSymbol.withSymbolConfiguration(config) else { return context.makeImage() }
    let tintedSymbol = tinted(symbol, color: .white)

    let symbolSize = tintedSymbol.size
    let origin = CGPoint(x: (size - symbolSize.width) / 2, y: (size - symbolSize.height) / 2)

    let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    tintedSymbol.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    return context.makeImage()
}

/// テンプレート画像（SF Symbol）を単色で塗りつぶす。
func tinted(_ image: NSImage, color: NSColor) -> NSImage {
    let output = NSImage(size: image.size)
    output.lockFocus()
    color.set()
    let imageRect = NSRect(origin: .zero, size: image.size)
    image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1)
    imageRect.fill(using: .sourceAtop)
    output.unlockFocus()
    return output
}

func writePNG(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: url)
}

for entry in sizes {
    guard let image = draw(pixels: entry.pixels) else {
        FileHandle.standardError.write("failed to render \(entry.name)\n".data(using: .utf8)!)
        continue
    }
    writePNG(image, to: outputDir.appendingPathComponent("\(entry.name).png"))
}

print("✅ icon PNGs written to \(outputDir.path)")
