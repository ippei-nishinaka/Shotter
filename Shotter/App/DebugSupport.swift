#if DEBUG
import AppKit

/// 開発中の動作確認用。`--debug-editor` を付けて起動すると、
/// 画面収録の権限なしでテスト画像の注釈エディタを開く。
enum DebugSupport {

    static var shouldOpenEditorOnLaunch: Bool {
        CommandLine.arguments.contains("--debug-editor")
    }

    /// `--debug-dump-canvas <path>` が指定されていれば、その出力先パス。
    static var canvasDumpPath: String? {
        guard let index = CommandLine.arguments.firstIndex(of: "--debug-dump-canvas"),
              CommandLine.arguments.indices.contains(index + 1)
        else { return nil }
        return CommandLine.arguments[index + 1]
    }

    private static func intArgument(named name: String) -> Int? {
        guard let index = CommandLine.arguments.firstIndex(of: name),
              CommandLine.arguments.indices.contains(index + 1)
        else { return nil }
        return Int(CommandLine.arguments[index + 1])
    }

    static var shouldOpenSettings: Bool {
        CommandLine.arguments.contains("--debug-settings")
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    /// `--debug-loginitem <path>` で自動起動の状態をファイルへ書き出して終了する。
    @MainActor
    static func dumpLoginItemStatusAndQuit() {
        guard let index = CommandLine.arguments.firstIndex(of: "--debug-loginitem"),
              CommandLine.arguments.indices.contains(index + 1)
        else { NSApp.terminate(nil); return }

        var report = "state(前): \(LoginItemManager.state)\n"
        do {
            try LoginItemManager.setEnabled(true)
            report += "登録後: \(LoginItemManager.state)\n"
            report += "plist: \(LoginItemManager.plistURL.path)\n"
            try LoginItemManager.setEnabled(false)
            report += "解除後: \(LoginItemManager.state)\n"
        } catch {
            report += "エラー: \(error)\n"
        }

        try? report.write(
            toFile: CommandLine.arguments[index + 1],
            atomically: true,
            encoding: .utf8
        )
        NSApp.terminate(nil)
    }

    /// `--debug-ocr` で、文字を描いたテスト画像を OCR して結果を出力する。
    @MainActor
    static func runOCRCheckAndQuit() {
        guard let image = makeTextSampleImage() else {
            log("テスト画像を作れませんでした")
            NSApp.terminate(nil)
            return
        }

        Task { @MainActor in
            do {
                let result = try await TextRecognizer.recognize(in: image)
                log("認識結果 \(result.lines.count) 行:")
                for line in result.lines { log("  | \(line)") }
            } catch {
                log("OCR 失敗: \(error)")
            }
            NSApp.terminate(nil)
        }
    }

    /// OCR 確認用に、白地へ日本語と英語を描いた画像を作る。
    private static func makeTextSampleImage() -> CGImage? {
        let size = CGSize(width: 900, height: 400)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: Int(size.width), height: Int(size.height),
                bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))

        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext

        let lines = [
            "スクリーンショット注釈ツール",
            "Shotter 0.1.0 — build.sh で作成",
            "請求書番号: INV-2026-0824",
            "合計金額 12,800 円（税込）",
        ]
        for (index, line) in lines.enumerated() {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 34, weight: .regular),
                .foregroundColor: NSColor.black,
            ]
            (line as NSString).draw(
                at: CGPoint(x: 40, y: size.height - 90 - CGFloat(index) * 70),
                withAttributes: attributes
            )
        }

        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    /// `--debug-windows` でウィンドウ一覧を標準エラーへ出して終了する。
    @MainActor
    static func dumpWindowListAndQuit() {
        let windows = WindowLister.onScreenWindows()
        log("検出したウィンドウ: \(windows.count) 件（手前から順）")
        for window in windows.prefix(15) {
            log(String(
                format: "  %-24@ x=%.0f y=%.0f w=%.0f h=%.0f",
                window.ownerName as NSString,
                window.frame.minX, window.frame.minY, window.frame.width, window.frame.height
            ))
        }
        NSApp.terminate(nil)
    }

    /// `--debug-hover <x> <y>`（コンテンツビュー座標・左上原点）で、
    /// その位置にカーソルを移動させてからダンプする。ツールチップの確認用。
    static func hoverPoint() -> CGPoint? {
        guard let index = CommandLine.arguments.firstIndex(of: "--debug-hover"),
              CommandLine.arguments.indices.contains(index + 2),
              let x = Double(CommandLine.arguments[index + 1]),
              let y = Double(CommandLine.arguments[index + 2])
        else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// コンテンツビュー座標を画面座標（左上原点）へ変換してカーソルを移動する。
    @MainActor
    static func moveCursor(to viewPoint: CGPoint, in window: NSWindow) {
        guard let content = window.contentView,
              let primary = NSScreen.screens.first
        else { return }

        // AppKit（左下原点）→ 画面グローバル → CoreGraphics（左上原点）。
        let flipped = CGPoint(x: viewPoint.x, y: content.bounds.height - viewPoint.y)
        let global = window.convertPoint(toScreen: content.convert(flipped, to: nil))
        CGWarpMouseCursorPosition(CGPoint(x: global.x, y: primary.frame.maxY - global.y))
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// `--debug-tooltip <キー>` に一致するか。キーはツール名かボタンのタイトル。
    static func isTooltipForced(_ key: String) -> Bool {
        forcedTooltipTool == key
    }

    /// `--debug-tooltip <ツール名>` で、そのツールのツールチップを出しっぱなしにする。
    static var forcedTooltipTool: String? {
        guard let index = CommandLine.arguments.firstIndex(of: "--debug-tooltip"),
              CommandLine.arguments.indices.contains(index + 1)
        else { return nil }
        return CommandLine.arguments[index + 1]
    }

    static var shouldShowThumbnail: Bool {
        CommandLine.arguments.contains("--debug-thumbnail")
    }

    /// 撮影後サムネイルを出して PNG に書き出し、終了する。
    @MainActor
    static func showThumbnailAndDump() {
        guard let image = makeSampleImage(width: 1600, height: 1000) else { return }
        CaptureThumbnailPresenter.show(
            image: image,
            pointSize: CGSize(width: 800, height: 500),
            onOpenEditor: {}
        )

        guard let path = canvasDumpPath else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)

            if let panel = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible }),
               let content = panel.contentView,
               let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                    log("サムネイルを書き出しました: \(path)")
                }
            } else {
                log("サムネイルが見つかりませんでした")
            }
            NSApp.terminate(nil)
        }
    }

    static var shouldOpenOnboarding: Bool {
        CommandLine.arguments.contains("--debug-onboarding")
    }

    /// 設定ウィンドウを開いて PNG に書き出し、終了する。
    @MainActor
    static func openSettingsAndDump() {
        SettingsWindowController.show()
        dumpWindowAndQuit(titled: "Shotter 設定")
    }

    /// 初回案内ウィンドウを開いて PNG に書き出し、終了する。
    @MainActor
    static func openOnboardingAndDump() {
        OnboardingWindowController.show()
        dumpWindowAndQuit(titled: "Shotter")
    }

    @MainActor
    private static func dumpWindowAndQuit(titled title: String) {
        guard let path = canvasDumpPath else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)

            if let window = NSApp.windows.first(where: { $0.title == title && $0.isVisible }),
               let content = window.contentView,
               let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                    log("「\(title)」を書き出しました: \(path)")
                }
            } else {
                log("「\(title)」ウィンドウが見つかりませんでした")
            }
            NSApp.terminate(nil)
        }
    }

    @MainActor
    static func openEditorWithSampleImage() {
        guard let image = makeSampleImage(width: 1600, height: 1000) else { return }
        let controller = EditorWindowController.present(
            image: image,
            pointSize: CGSize(width: 800, height: 500)
        )

        if CommandLine.arguments.contains("--debug-samples") {
            DebugSamples.populate(
                controller.store,
                includeSpotlight: CommandLine.arguments.contains("--debug-spotlight")
            )
        }

        // --debug-select <index> で指定した注釈を選択状態にする。
        if let index = intArgument(named: "--debug-select"),
           controller.store.annotations.indices.contains(index) {
            controller.store.tool = .select
            controller.store.select(controller.store.annotations[index])
        }

        guard let path = canvasDumpPath else { return }
        Task { @MainActor in
            // レイアウトと初回描画が終わるのを待ってから吸い出す。
            try? await Task.sleep(nanoseconds: 1_500_000_000)

            if let point = hoverPoint(), let window = controller.window {
                moveCursor(to: point, in: window)
                // onHover が届いて再描画されるまで待つ。
                try? await Task.sleep(nanoseconds: 900_000_000)
            }

            controller.dumpCanvas(to: path)
            NSApp.terminate(nil)
        }
    }

    private static func makeSampleImage(width: Int, height: Int) -> CGImage? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: [
                CGColor(srgbRed: 0.16, green: 0.22, blue: 0.35, alpha: 1),
                CGColor(srgbRed: 0.60, green: 0.35, blue: 0.45, alpha: 1),
            ] as CFArray,
            locations: [0, 1]
        )
        if let gradient {
            context.drawLinearGradient(
                gradient,
                start: .zero,
                end: CGPoint(x: width, y: height),
                options: []
            )
        }

        // 位置合わせを目視確認するためのグリッド。
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.25))
        context.setLineWidth(2)
        for x in stride(from: 0, through: width, by: 100) {
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: height))
        }
        for y in stride(from: 0, through: height, by: 100) {
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: width, y: y))
        }
        context.strokePath()

        // ハイライト（乗算合成）の見え方を確認するための、文字を模した白い領域。
        // 画像座標（左上原点）の x:0-400 / y:500-750 に置く。
        context.setFillColor(CGColor(gray: 0.97, alpha: 1))
        context.fill(CGRect(x: 20, y: height - 740, width: 360, height: 230))
        context.setFillColor(CGColor(gray: 0.25, alpha: 1))
        for row in 0..<6 {
            let y = height - 730 + row * 36
            context.fill(CGRect(x: 40, y: y, width: 300 - (row % 3) * 60, height: 16))
        }

        // 上下の向きが正しいかを確認するため、左上だけ明るい四角を置く。
        context.setFillColor(CGColor(srgbRed: 1, green: 0.85, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: height - 100, width: 100, height: 100))

        return context.makeImage()
    }
}
#endif
