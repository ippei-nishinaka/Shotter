#if DEBUG
import AppKit
import ScreenCaptureKit

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

    /// `--debug-overlay-frames` で、範囲選択オーバーレイの実際の位置と
    /// アニメーション設定を出力する。画面収録の権限は不要（ダミー画像を使う）。
    @MainActor
    static func dumpOverlayFramesAndQuit() {
        for screen in NSScreen.screens {
            let scale = screen.backingScaleFactor
            guard let image = solidImage(
                width: Int(screen.frame.width * scale),
                height: Int(screen.frame.height * scale)
            ) else { continue }

            let snapshot = DisplaySnapshot(
                displayID: screen.displayID ?? 0,
                frame: screen.frame,
                scale: scale,
                image: image
            )
            let window = SelectionOverlayWindow(snapshot: snapshot)
            window.orderFrontRegardless()

            let requested = screen.frame
            let actual = window.frame
            let shifted = requested != actual

            log("ディスプレイ \(screen.displayID ?? 0)")
            log("  要求した frame: \(requested)")
            log("  実際の frame  : \(actual)")
            log("  ずれ          : \(shifted ? "⚠️ あり（AppKit に補正されています）" : "なし")")
            log("  animationBehavior: \(window.animationBehavior.rawValue) "
                + "(none=\(NSWindow.AnimationBehavior.none.rawValue), default=\(NSWindow.AnimationBehavior.default.rawValue))")
            log("  visibleFrame  : \(screen.visibleFrame)")

            window.orderOut(nil)
        }
        NSApp.terminate(nil)
    }

    private static func solidImage(width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// `--debug-capture-timing <path>` で、暗転が出るまでの所要時間を測って
    /// ファイルへ書き出す。`open` 経由で起動しないと権限が Terminal 側に
    /// 紐付いてしまうため、標準エラーではなくファイルに落とす。
    @MainActor
    static func measureCaptureTimingAndQuit() {
        let outputPath: String? = {
            guard let index = CommandLine.arguments.firstIndex(of: "--debug-capture-timing"),
                  CommandLine.arguments.indices.contains(index + 1)
            else { return nil }
            return CommandLine.arguments[index + 1]
        }()

        var report: [String] = []
        func record(_ line: String) {
            report.append(line)
            log(line)
            if let outputPath {
                try? report.joined(separator: "\n").write(
                    toFile: outputPath, atomically: true, encoding: .utf8
                )
            }
        }

        guard CGPreflightScreenCaptureAccess() else {
            record("画面収録が未許可のため計測できません")
            NSApp.terminate(nil)
            return
        }

        Task { @MainActor in
            let service = ScreenCaptureService()
            for attempt in 1...3 {
                let start = Date()
                do {
                    let snapshots = try await service.captureAllDisplays()
                    let captured = Date()

                    var windows: [SelectionOverlayWindow] = []
                    for snapshot in snapshots {
                        let window = SelectionOverlayWindow(snapshot: snapshot)
                        window.contentView?.layoutSubtreeIfNeeded()
                        window.display()
                        windows.append(window)
                    }
                    for window in windows { window.orderFrontRegardless() }
                    let shown = Date()

                    record(String(
                        format: "%d 回目: 撮影 %.0f ms / オーバーレイ表示 %.0f ms / 合計 %.0f ms (%d 画面)",
                        attempt,
                        captured.timeIntervalSince(start) * 1000,
                        shown.timeIntervalSince(captured) * 1000,
                        shown.timeIntervalSince(start) * 1000,
                        snapshots.count
                    ))

                    for window in windows { window.orderOut(nil) }
                } catch {
                    record("失敗: \(error)")
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            NSApp.terminate(nil)
        }
    }

    /// `--debug-rounded <path>` で、角丸マスクの結果を PNG に書き出す。
    @MainActor
    static func dumpRoundedCornerSampleAndQuit() {
        guard let index = CommandLine.arguments.firstIndex(of: "--debug-rounded"),
              CommandLine.arguments.indices.contains(index + 1),
              let image = makeTextSampleImage()
        else { NSApp.terminate(nil); return }

        let scale: CGFloat = 2
        guard let masked = ImageMask.roundedCorners(
            image,
            radius: ImageMask.fallbackWindowCornerRadius * scale
        ) else {
            log("マスクに失敗しました")
            NSApp.terminate(nil)
            return
        }

        // 透明部分が見えるように、市松模様の上に重ねて書き出す。
        let width = masked.width
        let height = masked.height
        if let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
           let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
           ) {
            let square = 16
            for y in stride(from: 0, to: height, by: square) {
                for x in stride(from: 0, to: width, by: square) {
                    let dark = ((x / square) + (y / square)) % 2 == 0
                    context.setFillColor(CGColor(srgbRed: dark ? 1 : 0.2, green: dark ? 0.2 : 0.6, blue: 0.4, alpha: 1))
                    context.fill(CGRect(x: x, y: y, width: square, height: square))
                }
            }
            context.draw(masked, in: CGRect(x: 0, y: 0, width: width, height: height))

            if let composited = context.makeImage(),
               let data = NSBitmapImageRep(cgImage: composited).representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                log("角丸マスクの確認画像: \(CommandLine.arguments[index + 1])")
            }
        }
        NSApp.terminate(nil)
    }

    /// `--debug-corner-probe <path>` で、実際のウィンドウの角丸半径を実測する。
    ///
    /// ScreenCaptureKit の desktopIndependentWindow フィルタはウィンドウを
    /// **アルファ付き**で返す（角の外側が透明になる）。最上段の行を走査して
    /// 最初に不透明になる x 座標を探すと、それがそのまま角丸の半径になる。
    @MainActor
    static func probeWindowCornerRadiusAndQuit() {
        let outputPath: String? = {
            guard let index = CommandLine.arguments.firstIndex(of: "--debug-corner-probe"),
                  CommandLine.arguments.indices.contains(index + 1)
            else { return nil }
            return CommandLine.arguments[index + 1]
        }()

        var report: [String] = []
        func record(_ line: String) {
            report.append(line)
            log(line)
            if let outputPath {
                try? report.joined(separator: "\n").write(
                    toFile: outputPath, atomically: true, encoding: .utf8
                )
            }
        }

        Task { @MainActor in
            defer { NSApp.terminate(nil) }

            guard CGPreflightScreenCaptureAccess() else {
                record("画面収録が未許可のため計測できません")
                return
            }

            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: true
                )
                let ownPID = ProcessInfo.processInfo.processIdentifier

                // 一番大きいウィンドウを対象にする（角がはっきり見えるように）。
                let candidates = content.windows.filter {
                    $0.isOnScreen
                        && $0.windowLayer == 0
                        && $0.owningApplication?.processID != ownPID
                        && $0.frame.width > 200 && $0.frame.height > 200
                }
                guard let target = candidates.max(by: {
                    $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
                }) else {
                    record("対象になるウィンドウが見つかりませんでした")
                    return
                }

                let appName = target.owningApplication?.applicationName ?? "?"
                record("対象: \(appName)  frame=\(target.frame)")

                let filter = SCContentFilter(desktopIndependentWindow: target)
                let configuration = SCStreamConfiguration()
                var scale: CGFloat = 2

                if #available(macOS 14.0, *) {
                    scale = CGFloat(filter.pointPixelScale)
                    configuration.width = Int(filter.contentRect.width * scale)
                    configuration.height = Int(filter.contentRect.height * scale)
                    configuration.ignoreShadowsSingleWindow = true
                    configuration.shouldBeOpaque = false
                    configuration.captureResolution = .best
                } else {
                    configuration.width = Int(target.frame.width * scale)
                    configuration.height = Int(target.frame.height * scale)
                }
                configuration.showsCursor = false
                configuration.pixelFormat = kCVPixelFormatType_32BGRA

                guard #available(macOS 14.0, *) else {
                    record("この計測は macOS 14 以降が必要です")
                    return
                }
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: configuration
                )
                record("撮影サイズ: \(image.width) x \(image.height) px  (scale=\(scale))")

                guard let analysis = analyzeCorner(of: image) else {
                    record("ピクセルを解析できませんでした")
                    return
                }
                record("不透明領域の左上: (\(analysis.originX), \(analysis.originY))")
                record("最上段で最初に不透明になる x: \(analysis.firstOpaqueX) px")
                record("")
                record("複数の行で交差検証（r = (x+y) + √(2xy) で逆算）:")
                for estimate in analysis.estimates {
                    record(String(
                        format: "  y=%3d px → x=%3d px → r ≒ %.1f px = %.1f pt",
                        estimate.y, estimate.x, estimate.radius, estimate.radius / scale
                    ))
                }
                let median = analysis.medianRadius
                record("")
                record(String(format: "→ 角丸半径 ≒ %.1f px = %.1f pt", median, median / scale))
            } catch {
                record("失敗: \(error)")
            }
        }
    }

    private struct CornerAnalysis {
        struct Estimate {
            let y: Int
            let x: Int
            let radius: CGFloat
        }

        let originX: Int
        let originY: Int
        let firstOpaqueX: Int
        let radiusPixels: Int
        let estimates: [Estimate]

        var medianRadius: CGFloat {
            let sorted = estimates.map(\.radius).sorted()
            guard !sorted.isEmpty else { return CGFloat(radiusPixels) }
            return sorted[sorted.count / 2]
        }
    }

    /// アルファ付き画像の左上の角を調べる。
    private static func analyzeCorner(of image: CGImage) -> CornerAnalysis? {
        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data)
        else { return nil }

        let width = image.width
        let height = image.height
        let bytesPerRow = image.bytesPerRow
        let bytesPerPixel = image.bitsPerPixel / 8
        guard bytesPerPixel >= 4 else { return nil }

        // premultipliedFirst(BGRA) なら alpha は 4 バイト目、last なら同じく末尾。
        let alphaInfo = image.alphaInfo
        let alphaOffset = (alphaInfo == .premultipliedFirst || alphaInfo == .first) ? 0 : bytesPerPixel - 1

        func alpha(_ x: Int, _ y: Int) -> UInt8 {
            bytes[y * bytesPerRow + x * bytesPerPixel + alphaOffset]
        }

        // 影の余白があるかもしれないので、不透明領域の左上を先に探す。
        var originY = 0
        while originY < height {
            if (0..<width).contains(where: { alpha($0, originY) > 128 }) { break }
            originY += 1
        }
        guard originY < height else { return nil }

        var originX = 0
        while originX < width {
            if (originY..<min(originY + 64, height)).contains(where: { alpha(originX, $0) > 128 }) { break }
            originX += 1
        }

        // 最上段で最初に不透明になる x。これが角丸の半径にあたる。
        var firstOpaqueX = originX
        while firstOpaqueX < width, alpha(firstOpaqueX, originY) <= 128 {
            firstOpaqueX += 1
        }

        // 最上段だけだとアンチエイリアスの影響を受けやすいので、
        // 数行分を測って r を逆算し、中央値を採る。
        var estimates: [CornerAnalysis.Estimate] = []
        for offset in [4, 8, 12, 16, 20, 24] {
            let row = originY + offset
            guard row < height else { continue }

            var x = originX
            while x < width, alpha(x, row) <= 128 { x += 1 }

            let dx = CGFloat(x - originX)
            let dy = CGFloat(offset)
            guard dx > 0 else { continue }

            // (r - x)^2 = 2ry - y^2 を r について解いた形。
            let radius = (dx + dy) + (2 * dx * dy).squareRoot()
            estimates.append(CornerAnalysis.Estimate(y: offset, x: x - originX, radius: radius))
        }

        return CornerAnalysis(
            originX: originX,
            originY: originY,
            firstOpaqueX: firstOpaqueX,
            radiusPixels: firstOpaqueX - originX,
            estimates: estimates
        )
    }

    /// `--debug-window-capture <path>` で、ウィンドウキャプチャの経路を
    /// そのまま通した結果を PNG に書き出す。透明部分が分かるよう市松模様に重ねる。
    @MainActor
    static func dumpWindowCaptureAndQuit() {
        guard let index = CommandLine.arguments.firstIndex(of: "--debug-window-capture"),
              CommandLine.arguments.indices.contains(index + 1)
        else { NSApp.terminate(nil); return }
        let path = CommandLine.arguments[index + 1]

        Task { @MainActor in
            defer { NSApp.terminate(nil) }

            guard CGPreflightScreenCaptureAccess() else {
                log("画面収録が未許可です")
                return
            }

            do {
                let snapshots = try await ScreenCaptureService().captureAllDisplays()
                let windows = WindowLister.onScreenWindows()
                guard let target = windows.max(by: {
                    $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
                }) else {
                    log("ウィンドウが見つかりません")
                    return
                }
                log("対象: \(target.ownerName)  frame=\(target.frame)")

                guard let cropped = SnapshotCompositor.crop(snapshots, to: target.frame) else {
                    log("切り出しに失敗しました")
                    return
                }

                let scale = snapshots.first { $0.frame.intersects(target.frame) }?.scale ?? 2
                let masked = await CaptureCoordinator.shared.maskToWindowShape(
                    cropped, windowID: target.windowID, scale: scale
                )
                log("結果: \(masked.width) x \(masked.height) px")

                // 角の部分だけを切り出して拡大し、市松模様に重ねる。
                let corner = 120
                guard let topLeft = masked.cropping(
                    to: CGRect(x: 0, y: 0, width: corner, height: corner)
                ) else { return }

                let scaleUp = 3
                let size = corner * scaleUp
                guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                      let context = CGContext(
                        data: nil, width: size, height: size,
                        bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                      )
                else { return }

                let square = 24
                for y in stride(from: 0, to: size, by: square) {
                    for x in stride(from: 0, to: size, by: square) {
                        let dark = ((x / square) + (y / square)) % 2 == 0
                        context.setFillColor(CGColor(
                            srgbRed: dark ? 1 : 0.15, green: dark ? 0.15 : 0.7, blue: 0.35, alpha: 1
                        ))
                        context.fill(CGRect(x: x, y: y, width: square, height: square))
                    }
                }
                context.interpolationQuality = .none
                context.draw(topLeft, in: CGRect(x: 0, y: 0, width: size, height: size))

                if let composited = context.makeImage(),
                   let data = NSBitmapImageRep(cgImage: composited)
                    .representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: path))
                    log("左上の角を 3 倍に拡大して書き出しました: \(path)")
                }
            } catch {
                log("失敗: \(error)")
            }
        }
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
