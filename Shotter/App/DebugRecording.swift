#if DEBUG
import AppKit
import AVFoundation
import ScreenCaptureKit
import SwiftUI

/// 動画収録まわりの動作確認用。
extension DebugSupport {

    private static func stringArgument(named name: String, offset: Int = 1) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: name),
              CommandLine.arguments.indices.contains(index + offset)
        else { return nil }
        return CommandLine.arguments[index + offset]
    }

    // MARK: - ビットレートの検証

    /// `--debug-encode-bitrate <秒数> [画質]` で、合成した「動きの多い画面」を実際にエンコードし、
    /// ビットレートと 8 時間あたりのサイズを出力する。画面収録の権限は要らない。
    @MainActor
    static func measureEncodeBitrateAndQuit() {
        let seconds = Double(stringArgument(named: "--debug-encode-bitrate") ?? "") ?? 60
        let quality = stringArgument(named: "--debug-encode-bitrate", offset: 2)
            .flatMap(RecordingQuality.init(rawValue:)) ?? .longDuration

        Task.detached {
            do {
                let result = try await makeSyntheticRecording(
                    seconds: seconds,
                    quality: quality,
                    pointSize: CGSize(width: 1920, height: 1080)
                )
                let bytes = (try? FileManager.default.attributesOfItem(atPath: result.url.path)[.size] as? Int64) ?? 0
                let bitRate = Double(bytes) * 8 / result.duration
                let audio = Double(quality.systemAudioBitRate + quality.microphoneBitRate)
                let perEightHours = (bitRate + audio) * 8 * 3600 / 8

                log("画質: \(quality.title)（\(quality.framesPerSecond)fps・目標 \(quality.videoBitRate / 1000) kbps）")
                log("コーデック: \(RecordingWriter.supportsHEVC ? "HEVC" : "H.264")")
                log("映像: \(Int(result.pixelSize.width)) × \(Int(result.pixelSize.height))・\(result.videoFrameCount) フレーム・\(String(format: "%.1f", result.duration)) 秒")
                log("ファイル: \(bytes) バイト → 映像の実ビットレート \(Int(bitRate / 1000)) kbps")
                log("8 時間の見込み（音声 2 トラック込み）: \(String(format: "%.2f", perEightHours / 1_000_000_000)) GB")
                try? FileManager.default.removeItem(at: result.url)
            } catch {
                log("エンコード失敗: \(error)")
            }
            await MainActor.run { NSApp.terminate(nil) }
        }
    }

    /// 文字がスクロールし、色の付いた箱が動き回る画面を合成して書き込む。
    /// 画面収録としてはかなり厳しめ（毎フレーム全体が変わる）の素材。
    static func makeSyntheticRecording(
        seconds: Double,
        quality: RecordingQuality,
        pointSize: CGSize
    ) async throws -> RecordingWriterResult {
        let pixelSize = quality.outputPixelSize(forPointSize: pointSize, scale: 2)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Shotter-synthetic-\(UUID().uuidString).mov")
        let writer = try RecordingWriter(
            url: url,
            settings: RecordingWriterSettings(
                pixelSize: pixelSize,
                quality: quality,
                recordsSystemAudio: false,
                recordsMicrophone: false,
                isRealTime: false
            )
        )

        let width = Int(pixelSize.width), height = Int(pixelSize.height)
        let fps = quality.framesPerSecond
        let frameCount = Int(seconds * Double(fps))
        let font = NSFont.monospacedSystemFont(ofSize: CGFloat(height) / 40, weight: .regular)
        let lineHeight = CGFloat(height) / 30

        for frame in 0..<frameCount {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
            guard let buffer else { continue }

            CVPixelBufferLockBaseAddress(buffer, [])
            if let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer),
                width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) {
                context.setFillColor(CGColor(gray: 0.97, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))

                // 1 秒に 1 行ずつ流れる文字。
                let scroll = CGFloat(frame) * lineHeight / CGFloat(fps)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                let firstLine = Int(scroll / lineHeight)
                for line in firstLine..<(firstLine + 32) {
                    let y = CGFloat(height) - (CGFloat(line) * lineHeight - scroll) - lineHeight
                    let text = "\(line)  func render(frame: \(line * 7)) -> Image { let value = \(line * 31 % 997) }"
                    (text as NSString).draw(at: CGPoint(x: 20, y: y), withAttributes: [.font: font])
                }
                NSGraphicsContext.restoreGraphicsState()

                // 動き回る色付きの箱。
                for index in 0..<6 {
                    let t = Double(frame) / Double(fps) + Double(index)
                    let x = (sin(t * 0.9) * 0.4 + 0.5) * Double(width - 200)
                    let y = (cos(t * 0.7) * 0.4 + 0.5) * Double(height - 150)
                    context.setFillColor(NSColor(hue: CGFloat(index) / 6, saturation: 0.6, brightness: 0.9, alpha: 1).cgColor)
                    context.fill(CGRect(x: x, y: y, width: 200, height: 150))
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])

            writer.appendVideo(buffer, at: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        }

        return try await writer.finish()
    }

    // MARK: - ウィンドウのサイズ変更

    /// `--debug-record-resize <出力フォルダ>` で、テスト用のウィンドウを収録しながら大きく・小さくし、
    /// 変更前後のコマを PNG に書き出す。サイズ変更にどう追従しているかを目で確かめる用。
    @MainActor
    static func recordResizingWindowAndQuit() {
        guard let folder = stringArgument(named: "--debug-record-resize") else { NSApp.terminate(nil); return }

        // --on-retina を付けると、拡大率 2 のディスプレイ上で試す。
        let screen = CommandLine.arguments.contains("--on-retina")
            ? NSScreen.screens.first { $0.backingScaleFactor >= 2 }
            : NSScreen.main
        let origin = screen?.visibleFrame.origin ?? .zero
        func frame(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
            CGRect(x: origin.x + x, y: origin.y + y, width: width, height: height)
        }

        let window = NSWindow(
            contentRect: frame(100, 100, 600, 400),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "サイズ変更テスト"
        window.isReleasedWhenClosed = false
        window.setFrame(frame(100, 100, 600, 432), display: false)
        window.contentView = NSHostingView(rootView: ResizeTestPattern())
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        Task { @MainActor in
            defer { NSApp.terminate(nil) }
            do {
                try await Task.sleep(nanoseconds: 800_000_000)
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let scWindow = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                    log("テスト用のウィンドウが見つかりませんでした")
                    return
                }

                let url = URL(fileURLWithPath: folder).appendingPathComponent("resize.mov")
                try? FileManager.default.removeItem(at: url)
                var options = Preferences.recordingOptions
                options.recordsSystemAudio = false
                options.recordsMicrophone = false
                if let quality = stringArgument(named: "--debug-quality").flatMap(RecordingQuality.init(rawValue:)) {
                    options.quality = quality
                }
                let scale = window.screen?.backingScaleFactor ?? 2
                let recorder = try ScreenRecorder(window: scWindow, scale: scale, options: options, outputURL: url)
                try await recorder.start()

                try await Task.sleep(nanoseconds: 1_500_000_000)
                window.setFrame(frame(50, 20, 1000, 700), display: true)
                try await Task.sleep(nanoseconds: 1_500_000_000)
                window.setFrame(frame(100, 200, 400, 250), display: true)
                try await Task.sleep(nanoseconds: 1_500_000_000)

                let result = try await recorder.stop()
                log("映像: \(Int(result.pixelSize.width)) × \(Int(result.pixelSize.height))・\(String(format: "%.1f", result.duration)) 秒")

                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                for (label, seconds) in [("1_before", 1.0), ("2_larger", 2.6), ("3_smaller", 4.1)] {
                    let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
                    let rep = NSBitmapImageRep(cgImage: image)
                    let path = URL(fileURLWithPath: folder).appendingPathComponent("\(label).png")
                    try rep.representation(using: .png, properties: [:])?.write(to: path)
                    log("\(label): \(image.width) × \(image.height) → \(path.path)")
                }
            } catch {
                log("失敗: \(error)")
            }
        }
    }

    // MARK: - 実際の収録

    /// `--debug-record <秒数> [アプリ名]` で、一番手前のウィンドウ（アプリ名を渡せばそのアプリのもの）を今の設定で数秒収録し、
    /// できたファイルの中身（長さ・解像度・トラック・ビットレート）を出力する。
    @MainActor
    static func recordFrontWindowAndQuit() {
        let seconds = Double(stringArgument(named: "--debug-record") ?? "") ?? 5
        let appName = stringArgument(named: "--debug-record", offset: 2).flatMap { $0.hasPrefix("--") ? nil : $0 }

        Task { @MainActor in
            defer { NSApp.terminate(nil) }
            guard CGPreflightScreenCaptureAccess() else {
                log("画面収録の権限がありません")
                return
            }

            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let ownPID = ProcessInfo.processInfo.processIdentifier
                guard let target = WindowLister.onScreenWindows().first(where: { appName == nil || $0.ownerName == appName }),
                      let window = content.windows.first(where: {
                          $0.windowID == target.windowID && $0.owningApplication?.processID != ownPID
                      })
                else {
                    log("収録できるウィンドウが見つかりませんでした")
                    return
                }

                var options = Preferences.recordingOptions
                // --debug-audio-scope entireMac で、設定を変えずに音の範囲だけ切り替えて試せる。
                if let scope = stringArgument(named: "--debug-audio-scope").flatMap(SystemAudioScope.init(rawValue:)) {
                    options.systemAudioScope = scope
                }
                log("対象: \(target.ownerName)（\(Int(window.frame.width)) × \(Int(window.frame.height)) pt）")
                log("設定: 画質=\(options.quality.title) システム音声=\(options.recordsSystemAudio)（\(options.systemAudioScope.title)） マイク=\(options.recordsMicrophone) ポインタ=\(options.showsCursor)")

                let url = FileManager.default.temporaryDirectory.appendingPathComponent("Shotter-debug-record.mov")
                try? FileManager.default.removeItem(at: url)
                let recorder = try ScreenRecorder(window: window, scale: 2, options: options, outputURL: url)
                try await recorder.start()
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                let result = try await recorder.stop()

                let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                log("結果: \(String(format: "%.2f", result.duration)) 秒・\(result.videoFrameCount) フレーム・\(Int(result.pixelSize.width)) × \(Int(result.pixelSize.height))")
                log("ファイル: \(bytes) バイト（\(Int(Double(bytes) * 8 / result.duration / 1000)) kbps）・ポスター: \(result.poster != nil ? "あり" : "なし")")

                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration)
                log("AVAsset で読んだ長さ: \(String(format: "%.2f", duration.seconds)) 秒")
                for track in try await asset.load(.tracks) {
                    let format = try await track.load(.formatDescriptions).first
                    let codec = format.map { CMFormatDescriptionGetMediaSubType($0) }.map(fourCC) ?? "?"
                    let range = try await track.load(.timeRange)
                    var line = "  トラック: \(track.mediaType.rawValue) \(codec) \(String(format: "%.2f〜%.2f", range.start.seconds, range.end.seconds)) 秒"
                    if track.mediaType == .audio, let peak = peakLevel(of: track, in: asset) {
                        line += String(format: "・ピーク %.4f", peak)
                    }
                    log(line)
                }
                log("保存先: \(url.path)")
            } catch {
                log("収録失敗: \(error)")
            }
        }
    }

    /// 音声トラックの最大振幅（0〜1）。無音なら 0 に近い。
    private static func peakLevel(of track: AVAssetTrack, in asset: AVAsset) -> Float? {
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        guard reader.startReading() else { return nil }

        var peak: Float = 0
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
            guard let pointer else { continue }
            pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { samples in
                for index in 0..<(length / 4) { peak = max(peak, abs(samples[index])) }
            }
        }
        return peak
    }

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii) ?? "\(code)"
    }

    // MARK: - 画面の書き出し

    /// `--debug-recording-bar <フォルダ>` で、テスト用のウィンドウに本物の収録前のバー・赤い枠・暗転を出し、
    /// 途中でウィンドウを大きくして、前後の画面（ウィンドウの周り）を PNG に書き出す。
    @MainActor
    static func dumpRecordingSetupBarAndQuit() {
        guard let folder = stringArgument(named: "--debug-recording-bar") else { NSApp.terminate(nil); return }
        guard #available(macOS 14.0, *) else { NSApp.terminate(nil); return }

        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let window = NSWindow(
            contentRect: CGRect(x: visible.midX - 350, y: visible.midY - 200, width: 700, height: 420),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "収録テスト"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ResizeTestPattern())
        window.orderFrontRegardless()

        Task { @MainActor in
            defer { NSApp.terminate(nil) }
            // ウィンドウを大きくしても収まる範囲を撮る。
            let region = CGRect(x: visible.midX - 560, y: visible.midY - 380, width: 1120, height: 760)
            do {
                // 暗転が効いているか比べられるよう、バーを出す前の画面も撮っておく。
                try await Task.sleep(nanoseconds: 400_000_000)
                try await captureScreenRegion(region, to: URL(fileURLWithPath: folder).appendingPathComponent("bar-0-plain.png"))

                Task { @MainActor in
                    _ = await RecordingSetupPanel.run(
                        windowID: CGWindowID(window.windowNumber),
                        initialFrame: window.frame,
                        appName: "収録テスト"
                    )
                }

                try await Task.sleep(nanoseconds: 900_000_000)
                try await captureScreenRegion(region, to: URL(fileURLWithPath: folder).appendingPathComponent("bar-1-before.png"))

                window.setFrame(CGRect(x: visible.midX - 500, y: visible.midY - 320, width: 1000, height: 640), display: true)
                try await Task.sleep(nanoseconds: 700_000_000)
                try await captureScreenRegion(region, to: URL(fileURLWithPath: folder).appendingPathComponent("bar-2-resized.png"))
                log("収録前のバーを書き出しました: \(folder)")
            } catch {
                log("失敗: \(error)")
            }
        }
    }

    /// メイン画面の一部（AppKit グローバル座標）を撮って PNG に書き出す。
    @available(macOS 14.0, *)
    @MainActor
    private static func captureScreenRegion(_ region: CGRect, to url: URL) async throws {
        guard let screen = NSScreen.main, let displayID = screen.displayID else { return }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return }

        // ScreenCaptureKit の sourceRect は画面の左上原点。
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = CGRect(
            x: region.minX - screen.frame.minX,
            y: screen.frame.maxY - region.maxY,
            width: region.width,
            height: region.height
        )
        configuration.width = Int(region.width)
        configuration.height = Int(region.height)
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingWindows: []),
            configuration: configuration
        )
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }

    /// `--debug-recording-statusbar <path>` で、収録中のメニューバーの表示を PNG に書き出し、
    /// メニューの項目を出力する。
    @MainActor
    static func dumpRecordingStatusBarAndQuit() {
        guard let path = stringArgument(named: "--debug-recording-statusbar") else { NSApp.terminate(nil); return }
        // --debug-scheduled を付けると、予約中の表示を確かめる。
        if CommandLine.arguments.contains("--debug-scheduled") {
            let start = Date().addingTimeInterval(754)
            RecordingCoordinator.shared.debugSimulateScheduled(
                start: start, stop: start.addingTimeInterval(90 * 60), appName: "Google Chrome"
            )
        } else {
            RecordingCoordinator.shared.debugSimulateRecording(elapsed: 754, appName: "Google Chrome")
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            // ステータスバーのボタンは NSStatusBarWindow に載っている。
            if let window = NSApp.windows.first(where: { String(describing: type(of: $0)).contains("StatusBar") }),
               let view = window.contentView,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                // メニューバーの文字は白なので、暗い背景に重ねて書き出す。
                let image = NSImage(size: view.bounds.size, flipped: false) { rect in
                    NSColor(white: 0.2, alpha: 1).setFill()
                    rect.fill()
                    rep.draw(in: rect)
                    return true
                }
                if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) {
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                log("メニューバーの表示を書き出しました: \(path)")

                @MainActor func findButton(in view: NSView) -> NSStatusBarButton? {
                    if let button = view as? NSStatusBarButton { return button }
                    return view.subviews.lazy.compactMap(findButton(in:)).first
                }
                if let button = findButton(in: view) {
                    log("ボタン: \(button.title)")
                }
                for item in window.value(forKeyPath: "statusItem.menu.itemArray") as? [NSMenuItem] ?? [] {
                    log("  メニュー: \(item.isSeparatorItem ? "----" : item.title)\(item.isEnabled ? "" : "（灰色）")")
                }
            } else {
                log("ステータスバーのウィンドウが見つかりませんでした")
            }
            NSApp.terminate(nil)
        }
    }

    /// 履歴ウィンドウの確認用に、合成した短い動画を履歴へ入れる。
    @MainActor
    static func addSyntheticVideoToHistory(date: Date) async -> URL? {
        guard let result = try? await makeSyntheticRecording(
            seconds: 3,
            quality: .standard,
            pointSize: CGSize(width: 800, height: 500)
        ) else { return nil }
        return try? await HistoryStore.shared.storeRecording(result, hasSystemAudio: true, hasMicrophone: false, date: date)
    }
}
#endif

#if DEBUG
/// サイズ変更テスト用の模様。四隅と中央に印を付け、拡大縮小や切れ方が分かるようにする。
private struct ResizeTestPattern: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(white: 0.92)
                Rectangle().strokeBorder(Color.red, lineWidth: 6)
                ForEach(0..<4) { index in
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 40, height: 40)
                        .position(
                            x: index % 2 == 0 ? 30 : proxy.size.width - 30,
                            y: index < 2 ? 30 : proxy.size.height - 30
                        )
                }
                Text("\(Int(proxy.size.width)) × \(Int(proxy.size.height)) pt")
                    .font(.system(size: 28, weight: .bold).monospacedDigit())
            }
        }
    }
}
#endif

#if DEBUG
// MARK: - 動画エディタ

extension DebugSupport {

    /// 表示時間の違う注釈を 4 つ置く。どの時刻に何が出るかを確かめやすいよう、位置を分けておく。
    ///   矢印: 0〜4 秒 / 四角: 2〜6 秒 / テキスト: 5〜10 秒（最後まで） / モザイク: 1〜7 秒
    @MainActor
    static func addTimedSampleAnnotations(to store: VideoEditorStore) {
        let size = store.pixelSize
        func style(_ color: NSColor) -> AnnotationStyle {
            AnnotationStyle(color: color, lineWidth: 8, fontSize: 40)
        }
        let annotations = store.annotationStore

        let arrow = ArrowAnnotation(
            start: CGPoint(x: size.width * 0.1, y: size.height * 0.15),
            end: CGPoint(x: size.width * 0.35, y: size.height * 0.35),
            style: style(.systemRed)
        )
        annotations.add(arrow)
        store.setRange(arrow.id, start: 0, end: 4)

        let rectangle = RectangleAnnotation(
            start: CGPoint(x: size.width * 0.55, y: size.height * 0.1),
            end: CGPoint(x: size.width * 0.9, y: size.height * 0.4),
            style: style(.systemBlue)
        )
        annotations.add(rectangle)
        store.setRange(rectangle.id, start: 2, end: 6)

        let text = TextAnnotation(
            origin: CGPoint(x: size.width * 0.1, y: size.height * 0.7),
            text: "5 秒から最後まで",
            style: style(.systemGreen),
            maxWidth: size.width * 0.8
        )
        annotations.add(text)
        store.setRange(text.id, start: 5, end: store.duration)

        let pixelate = PixelateAnnotation(
            start: CGPoint(x: size.width * 0.4, y: size.height * 0.45),
            end: CGPoint(x: size.width * 0.6, y: size.height * 0.65),
            style: style(.systemOrange)
        )
        annotations.add(pixelate)
        store.setRange(pixelate.id, start: 1, end: 7)
    }

    /// 確認用の 10 秒の動画を作る。`--debug-video-source <path>` があればそれを使う。
    static func debugVideoURL() async throws -> URL {
        if let index = CommandLine.arguments.firstIndex(of: "--debug-video-source"),
           CommandLine.arguments.indices.contains(index + 1) {
            return URL(fileURLWithPath: CommandLine.arguments[index + 1])
        }
        let result = try await makeSyntheticRecording(
            seconds: 10,
            quality: .standard,
            pointSize: CGSize(width: 1280, height: 720)
        )
        return result.url
    }

    /// `--debug-video-editor <出力フォルダ>` で、注釈を置いた動画エディタを開き、
    /// 1 秒・3 秒・5.5 秒・9 秒の画面を PNG に書き出す。
    @MainActor
    static func dumpVideoEditorAndQuit() {
        guard let index = CommandLine.arguments.firstIndex(of: "--debug-video-editor"),
              CommandLine.arguments.indices.contains(index + 1)
        else { NSApp.terminate(nil); return }
        let folder = URL(fileURLWithPath: CommandLine.arguments[index + 1])

        Task { @MainActor in
            defer { NSApp.terminate(nil) }
            do {
                let url = try await debugVideoURL()
                VideoEditorWindowController.present(url: url)
                try await Task.sleep(nanoseconds: 1_500_000_000)

                guard let window = NSApp.windows.first(where: { $0.isVisible && $0.windowController is VideoEditorWindowController }),
                      let controller = window.windowController as? VideoEditorWindowController
                else {
                    log("動画エディタが開きませんでした")
                    return
                }
                addTimedSampleAnnotations(to: controller.store)
                controller.store.annotationStore.tool = .select

                for time in [1.0, 3.0, 5.5, 9.0] {
                    controller.store.seek(to: time)
                    try await Task.sleep(nanoseconds: 900_000_000)
                    // 四角を選んでおき、タイムラインで選択中の見た目も確かめる。
                    if let rectangle = controller.store.annotationStore.annotations.first(where: { $0 is RectangleAnnotation }) {
                        controller.store.annotationStore.select(rectangle)
                    }
                    try await Task.sleep(nanoseconds: 300_000_000)

                    // AVPlayerLayer の中身は cacheDisplay に写らないので、実際の画面を撮る。
                    guard #available(macOS 14.0, *) else { continue }
                    let shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    guard let scWindow = shareable.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { continue }
                    let configuration = SCStreamConfiguration()
                    configuration.width = Int(scWindow.frame.width)
                    configuration.height = Int(scWindow.frame.height)
                    let image = try await SCScreenshotManager.captureImage(
                        contentFilter: SCContentFilter(desktopIndependentWindow: scWindow),
                        configuration: configuration
                    )
                    let path = folder.appendingPathComponent(String(format: "editor-%04.1f.png", time))
                    try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: path)
                    let hidden = controller.store.annotationStore.hiddenAnnotationIDs.count
                    log("\(time) 秒: 表示中 \(controller.store.annotationStore.annotations.count - hidden) 個 → \(path.path)")
                }
                controller.store.flushSave()
                let saved = HistoryStore.shared.loadVideoDocument(for: url)
                log("保存した編集内容: 注釈 \(saved?.annotations.count ?? 0) 個（\(saved?.annotations.map { "\($0.range.start)〜\($0.range.end)" }.joined(separator: ", ") ?? "")）")
                window.close()
            } catch {
                log("失敗: \(error)")
            }
        }
    }

    /// GIF のコマ数・合計の再生時間・大きさを出し、元の時刻 2・4.5・6.5・8.5 秒にあたるコマを PNG にする。
    private static func inspectGIF(at url: URL, elapsed: Double, folder: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            log("gif: 読めませんでした")
            return
        }
        let count = CGImageSourceGetCount(source)
        var delays: [Double] = []
        for index in 0..<count {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            delays.append((gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0)
        }
        let first = CGImageSourceCreateImageAtIndex(source, 0, nil)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        log("gif: \(count) コマ・合計 \(String(format: "%.2f", delays.reduce(0, +))) 秒・\(first?.width ?? 0) × \(first?.height ?? 0)・\(bytes) バイト・書き出し \(String(format: "%.1f", elapsed)) 秒")

        // 書き出した GIF は 1 秒から始まるので、元の時刻から 1 を引いた位置のコマを探す。
        for original in [2.0, 4.5, 6.5, 8.5] {
            var elapsedInGIF = 0.0
            var index = 0
            while index < count - 1, elapsedInGIF + delays[index] <= original - 1 {
                elapsedInGIF += delays[index]
                index += 1
            }
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            let path = folder.appendingPathComponent(String(format: "gif-%04.1f.png", original))
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: path)
        }
    }

    /// `--debug-video-export <出力フォルダ>` で、注釈を置いた動画を 1〜9 秒にトリムして
    /// MP4 と MOV に書き出し、2・4.5・6.5・8.5 秒（元の時刻）のコマを PNG にする。
    @MainActor
    static func exportVideoAndQuit() {
        guard let index = CommandLine.arguments.firstIndex(of: "--debug-video-export"),
              CommandLine.arguments.indices.contains(index + 1)
        else { NSApp.terminate(nil); return }
        let folder = URL(fileURLWithPath: CommandLine.arguments[index + 1])

        Task { @MainActor in
            defer { NSApp.terminate(nil) }
            do {
                let url = try await debugVideoURL()
                let store = try await VideoEditorStore.load(url: url)
                addTimedSampleAnnotations(to: store)
                store.setTrim(start: 1, end: 9)

                for format in VideoExportFormat.allCases {
                    let output = folder.appendingPathComponent("export.\(format.fileExtension)")
                    let started = Date()
                    try await store.exportVideo(format: format, to: output)
                    let elapsed = Date().timeIntervalSince(started)

                    if format == .gif {
                        try inspectGIF(at: output, elapsed: elapsed, folder: folder)
                        continue
                    }

                    let asset = AVURLAsset(url: output)
                    let duration = try await asset.load(.duration).seconds
                    let videoTracks = try await asset.loadTracks(withMediaType: .video)
                    let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                    let codec = try await videoTracks.first?.load(.formatDescriptions).first
                        .map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "?"
                    let bytes = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int64) ?? 0
                    log("\(format.rawValue): \(String(format: "%.2f", duration)) 秒・映像 \(codec)・音声 \(audioTracks.count) トラック・\(bytes) バイト・書き出し \(String(format: "%.1f", elapsed)) 秒")

                    let generator = AVAssetImageGenerator(asset: asset)
                    generator.requestedTimeToleranceBefore = .zero
                    generator.requestedTimeToleranceAfter = .zero
                    // 書き出した動画は 1 秒から始まるので、元の時刻から 1 を引く。
                    for original in [2.0, 4.5, 6.5, 8.5] where original - 1 < duration {
                        let image = try await generator.image(at: CMTime(seconds: original - 1, preferredTimescale: 600)).image
                        let path = folder.appendingPathComponent(String(format: "%@-%04.1f.png", format.rawValue, original))
                        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: path)
                    }
                }
                log("期待: 2.0 秒=矢印・四角・モザイク / 4.5 秒=四角・モザイク / 6.5 秒=テキスト・モザイク / 8.5 秒=テキストだけ")
            } catch {
                log("失敗: \(error)")
            }
        }
    }
}
#endif

#if DEBUG
// MARK: - 再生速度・保存先

extension DebugSupport {

    /// `--debug-video-playback` で、再生速度と ±3 秒の移動を確かめる。
    @MainActor
    static func checkVideoPlaybackAndQuit() {
        Task { @MainActor in
            defer { NSApp.terminate(nil) }
            do {
                let result = try await makeSyntheticRecording(seconds: 10, quality: .standard, pointSize: CGSize(width: 640, height: 360))
                let store = try await VideoEditorStore.load(url: result.url)
                defer { try? FileManager.default.removeItem(at: result.url) }

                log("速度の選択肢: \(VideoEditorStore.playbackRates.map(VideoEditorStore.rateLabel).joined(separator: " / "))")

                for rate: Float in [0.5, 2, 3] {
                    store.seek(to: 0)
                    try await Task.sleep(nanoseconds: 300_000_000)
                    store.playbackRate = rate
                    let started = Date()
                    store.play()
                    try await Task.sleep(nanoseconds: 1_500_000_000)
                    let advanced = store.player.currentTime().seconds
                    let wall = Date().timeIntervalSince(started)
                    store.pause()
                    log(String(format: "%@: 実時間 %.2f 秒で %.2f 秒進んだ（期待 %.2f 秒）",
                               VideoEditorStore.rateLabel(rate), wall, advanced, wall * Double(rate)))
                }

                store.seek(to: 5)
                try await Task.sleep(nanoseconds: 300_000_000)
                store.skip(seconds: VideoEditorStore.skipInterval)
                log(String(format: "5 秒から → で %.2f 秒（期待 8.00）", store.currentTime))
                store.skip(seconds: -VideoEditorStore.skipInterval)
                store.skip(seconds: -VideoEditorStore.skipInterval)
                log(String(format: "← を 2 回で %.2f 秒（期待 2.00）", store.currentTime))
                store.skip(seconds: -VideoEditorStore.skipInterval)
                log(String(format: "さらに ← で %.2f 秒（期待 0.00・先頭で止まる）", store.currentTime))
                store.tearDown()
            } catch {
                log("失敗: \(error)")
            }
        }
    }

    /// `--debug-save-directory <作業フォルダ>` で、保存先の変更と移動を確かめる。
    /// 本物の履歴に触れないよう、空の作業フォルダを保存先にしてダミーだけを動かし、最後に設定を元に戻す。
    @MainActor
    static func checkSaveDirectoryAndQuit() {
        guard let index = CommandLine.arguments.firstIndex(of: "--debug-save-directory"),
              CommandLine.arguments.indices.contains(index + 1)
        else { NSApp.terminate(nil); return }
        let work = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        let first = work.appendingPathComponent("first", isDirectory: true)
        let second = work.appendingPathComponent("second", isDirectory: true)
        try? FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)

        let store = HistoryStore.shared
        let originalImage = Preferences.saveDirectory(for: .image)
        let originalVideo = Preferences.saveDirectory(for: .video)

        Task { @MainActor in
            defer {
                Preferences.setSaveDirectory(originalImage, for: .image)
                Preferences.setSaveDirectory(originalVideo, for: .video)
                store.reload()
                log("保存先の設定を元に戻しました")
                NSApp.terminate(nil)
            }

            Preferences.setSaveDirectory(first, for: .image)
            Preferences.setSaveDirectory(first, for: .video)
            log("保存先: 画像 \(store.imageDirectory.path) / 動画 \(store.videoDirectory.path)")

            guard let image = sampleTile(index: 2) else { return }
            let imageURL = store.save(image)
            let videoURL = await addSyntheticVideoToHistory(date: Date())
            if let imageURL { store.saveDocument(AnnotationDocument(annotations: [], hasShadow: false, shadowStrength: 1, hasRoundedCorners: false, cornerRoundness: 0, counterStartNumber: 1), for: imageURL) }
            log("作業フォルダに保存: 画像 \(imageURL?.lastPathComponent ?? "失敗") / 動画 \(videoURL?.lastPathComponent ?? "失敗")")
            log("履歴に出ている件数: 画像 \(store.items.filter { $0.kind == .image }.count) / 動画 \(store.items.filter { $0.kind == .video }.count)（期待 1 / 1）")

            let images = await store.moveItems(of: .image, to: second)
            Preferences.setSaveDirectory(second, for: .image)
            let videos = await store.moveItems(of: .video, to: second)
            Preferences.setSaveDirectory(second, for: .video)
            store.reload()
            log("移動: 画像 \(images.moved) 件（失敗 \(images.failed)）/ 動画 \(videos.moved) 件（失敗 \(videos.failed)）")

            let remaining = (try? FileManager.default.contentsOfDirectory(atPath: first.path))?.filter { !$0.hasPrefix(".") } ?? []
            let moved = (try? FileManager.default.contentsOfDirectory(atPath: second.path))?.sorted() ?? []
            log("移動元に残ったファイル: \(remaining.isEmpty ? "なし" : remaining.joined(separator: ", "))")
            log("移動先のファイル: \(moved.joined(separator: ", "))")
            log("移動後に履歴に出ている件数: 画像 \(store.items.filter { $0.kind == .image }.count) / 動画 \(store.items.filter { $0.kind == .video }.count)（期待 1 / 1）")

            // 片付け
            try? FileManager.default.removeItem(at: work)
        }
    }
}
#endif

#if DEBUG
// MARK: - アンドゥ・サムネイル・外部の動画

extension DebugSupport {

    /// `--debug-video-undo` で、表示時間とトリムの変更が ⌘Z / ⇧⌘Z で戻るかを確かめる。
    @MainActor
    static func checkVideoUndoAndQuit() {
        Task { @MainActor in
            defer { NSApp.terminate(nil) }
            do {
                let url = try await debugVideoURL()
                let store = try await VideoEditorStore.load(url: url)
                addTimedSampleAnnotations(to: store)
                let annotations = store.annotationStore
                guard let rectangle = annotations.annotations.first(where: { $0 is RectangleAnnotation }) else { return }
                @MainActor func describe() -> String {
                    let range = store.range(for: rectangle.id)
                    return String(format: "四角 %.1f〜%.1f・トリム %.1f〜%.1f・注釈 %d 個",
                                  range?.start ?? -1, range?.end ?? -1, store.trimStart, store.trimEnd,
                                  annotations.annotations.count)
                }
                var allPassed = true
                @MainActor func check(_ label: String, _ expected: String) {
                    let actual = describe()
                    let passed = actual == expected
                    allPassed = allPassed && passed
                    log("\(passed ? "✓" : "✗") \(label): \(actual)\(passed ? "" : "（期待: \(expected)）")")
                }

                check("はじめ", "四角 2.0〜6.0・トリム 0.0〜10.0・注釈 4 個")

                store.setRange(rectangle.id, start: 3, end: 7)
                check("秒数で 3〜7 に変更", "四角 3.0〜7.0・トリム 0.0〜10.0・注釈 4 個")
                annotations.undo()
                check("⌘Z", "四角 2.0〜6.0・トリム 0.0〜10.0・注釈 4 個")

                // ドラッグは何度も値が変わっても 1 手にまとまる。
                store.beginTimelineDrag()
                for step in 1...10 { store.moveRange(rectangle.id, toStart: 2 + Double(step) * 0.2) }
                store.endTimelineDrag()
                check("バーをドラッグで 4〜8 へ", "四角 4.0〜8.0・トリム 0.0〜10.0・注釈 4 個")
                annotations.undo()
                check("⌘Z 1 回でドラッグ前へ", "四角 2.0〜6.0・トリム 0.0〜10.0・注釈 4 個")

                store.setTrim(start: 1, end: 9)
                check("トリム 1〜9", "四角 2.0〜6.0・トリム 1.0〜9.0・注釈 4 個")
                annotations.undo()
                check("⌘Z", "四角 2.0〜6.0・トリム 0.0〜10.0・注釈 4 個")
                annotations.redo()
                check("⇧⌘Z", "四角 2.0〜6.0・トリム 1.0〜9.0・注釈 4 個")

                // 注釈の操作と表示時間の変更が、新しい順に戻ること。
                // アンドゥ・リドゥで中身は複製に入れ替わるので、今の四角を取り直してから消す。
                if let current = annotations.annotations.first(where: { $0.id == rectangle.id }) {
                    annotations.remove(current)
                }
                check("四角を削除", "四角 2.0〜6.0・トリム 1.0〜9.0・注釈 3 個")
                annotations.undo()
                check("⌘Z で四角が戻る", "四角 2.0〜6.0・トリム 1.0〜9.0・注釈 4 個")
                annotations.undo()
                check("もう 1 回 ⌘Z でトリムが戻る", "四角 2.0〜6.0・トリム 0.0〜10.0・注釈 4 個")

                log(allPassed ? "→ 表示時間とトリムの取り消しは正しく動いています" : "→ 取り消しに誤りがあります")
                store.tearDown()
            } catch {
                log("失敗: \(error)")
            }
        }
    }

    /// `--debug-video-thumbnail <出力フォルダ>` で、注釈を付けた動画の履歴サムネイル（注釈込みのコマ）ができるかを確かめる。
    @MainActor
    static func checkVideoThumbnailAndQuit() {
        guard let index = CommandLine.arguments.firstIndex(of: "--debug-video-thumbnail"),
              CommandLine.arguments.indices.contains(index + 1)
        else { NSApp.terminate(nil); return }
        let folder = URL(fileURLWithPath: CommandLine.arguments[index + 1])

        Task { @MainActor in
            defer { NSApp.terminate(nil) }
            do {
                let url = try await debugVideoURL()
                let store = try await VideoEditorStore.load(url: url)
                addTimedSampleAnnotations(to: store)
                store.tearDown()
                try await Task.sleep(nanoseconds: 1_500_000_000)

                let edited = url.deletingPathExtension().appendingPathExtension("edited.jpg")
                guard FileManager.default.fileExists(atPath: edited.path) else {
                    log("✗ 注釈込みのサムネイルができていません")
                    return
                }
                let copy = folder.appendingPathComponent("thumbnail.jpg")
                try? FileManager.default.removeItem(at: copy)
                try FileManager.default.copyItem(at: edited, to: copy)
                log("✓ 注釈込みのサムネイル: \(copy.path)（注釈がいちばん多い時刻 = 2 秒あたりのコマ。矢印・四角・モザイクが乗るはず）")
            } catch {
                log("失敗: \(error)")
            }
        }
    }

    /// `--debug-open-video <動画> <作業フォルダ>` で、外から開いた動画が履歴へ取り込まれるかを確かめる。
    /// 本物の履歴に触れないよう、動画の保存先を作業フォルダに向けて試し、最後に元へ戻す。
    @MainActor
    static func checkOpenVideoAndQuit() {
        guard let index = CommandLine.arguments.firstIndex(of: "--debug-open-video"),
              CommandLine.arguments.indices.contains(index + 2)
        else { NSApp.terminate(nil); return }
        let source = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        let work = URL(fileURLWithPath: CommandLine.arguments[index + 2])
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        let store = HistoryStore.shared
        let original = Preferences.saveDirectory(for: .video)
        let originalRetention = UserDefaults.standard.object(forKey: "videoHistoryRetentionDays")
        Preferences.setSaveDirectory(work, for: .video)

        Task { @MainActor in
            defer {
                Preferences.setSaveDirectory(original, for: .video)
                if originalRetention == nil { UserDefaults.standard.removeObject(forKey: "videoHistoryRetentionDays") }
                store.reload()
                try? FileManager.default.removeItem(at: work)
                log("保存先の設定を元に戻しました")
                NSApp.terminate(nil)
            }
            do {
                let imported = try await store.importVideo(at: source)
                let files = (try? FileManager.default.contentsOfDirectory(atPath: work.path))?.filter { !$0.hasPrefix(".") }.sorted() ?? []
                log("取り込み先: \(imported.lastPathComponent)")
                log("作業フォルダのファイル: \(files.joined(separator: ", "))")
                log("元のファイルは残っている: \(FileManager.default.fileExists(atPath: source.path))")
                if let item = store.items.first(where: { $0.url.lastPathComponent == imported.lastPathComponent }) {
                    log("✓ 履歴に出ている: 種類=\(item.kind == .video ? "動画" : "画像")・\(item.sizeDescription)・長さ \(item.duration.map { String(format: "%.1f 秒", $0) } ?? "?")")
                } else {
                    log("✗ 履歴に出ていません")
                }
                let editor = try await VideoEditorStore.load(url: imported)
                log("✓ 動画エディタで読み込めた: \(Int(editor.pixelSize.width)) × \(Int(editor.pixelSize.height))・\(String(format: "%.1f", editor.duration)) 秒")
                editor.tearDown()
            } catch {
                log("失敗: \(error)")
            }
        }
    }
}
#endif

#if DEBUG
// MARK: - 収録の予約

extension DebugSupport {

    /// `--debug-scheduled-record <作業フォルダ>` で、テスト用のウィンドウに対して収録の予約を実際に動かす。
    /// ① 3 秒後に開始・4 秒後に自動終了 ② 予約の取り消し ③ 今すぐ開始、を順に確かめる。
    /// 本物の履歴・マイク・クリップボードには影響を残さないよう、保存先を作業フォルダにし、
    /// 音声とマイクを切り、クリップボードは元に戻す。
    @MainActor
    static func checkScheduledRecordingAndQuit() {
        guard let folder = stringArgument(named: "--debug-scheduled-record") else { NSApp.terminate(nil); return }
        let work = URL(fileURLWithPath: folder)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        let originalDirectory = Preferences.saveDirectory(for: .video)
        let originalSystemAudio = Preferences.recordsSystemAudio
        let originalMicrophone = Preferences.recordsMicrophone
        let originalCountdown = Preferences.recordingCountdown
        let originalAfterCapture = Preferences.afterCaptureAction
        let savedPasteboard = NSPasteboard.general.pasteboardItems?.map { item -> [NSPasteboard.PasteboardType: Data] in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        } ?? []

        Preferences.setSaveDirectory(work, for: .video)
        Preferences.recordsSystemAudio = false
        Preferences.recordsMicrophone = false
        Preferences.recordingCountdown = false
        Preferences.afterCaptureAction = .copyOnly

        let window = NSWindow(
            contentRect: CGRect(x: 300, y: 300, width: 640, height: 400),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "予約テスト"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ResizeTestPattern())
        window.orderFrontRegardless()

        let coordinator = RecordingCoordinator.shared
        let windowID = CGWindowID(window.windowNumber)

        func describe() -> String {
            var text = "\(coordinator.state)"
            if coordinator.state == .scheduled { text += "（開始まで \(Int(coordinator.remainingUntilStart.rounded())) 秒）" }
            if coordinator.state == .recording { text += "（経過 \(Int(coordinator.elapsed)) 秒）" }
            return text
        }

        /// 状態が idle に戻るまで見張り、変わるたびに記録する。
        func watch(limit: Double) async {
            var last = ""
            let started = Date()
            while Date().timeIntervalSince(started) < limit {
                let now = describe()
                if now != last {
                    log(String(format: "  %5.1f 秒: %@", Date().timeIntervalSince(started), now))
                    last = now
                }
                if coordinator.state == .idle, Date().timeIntervalSince(started) > 0.5 { return }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }

        Task { @MainActor in
            defer {
                Preferences.setSaveDirectory(originalDirectory, for: .video)
                Preferences.recordsSystemAudio = originalSystemAudio
                Preferences.recordsMicrophone = originalMicrophone
                Preferences.recordingCountdown = originalCountdown
                Preferences.afterCaptureAction = originalAfterCapture
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects(savedPasteboard.map { types in
                    let item = NSPasteboardItem()
                    for (type, data) in types { item.setData(data, forType: type) }
                    return item
                })
                HistoryStore.shared.reload()
                try? FileManager.default.removeItem(at: work)
                log("設定・クリップボードを元に戻しました")
                NSApp.terminate(nil)
            }

            // ① 3 秒後に開始して、その 4 秒後に自動で終了する。
            log("① 3 秒後に開始・4 秒後に自動終了")
            let start = Date().addingTimeInterval(3)
            let schedule = RecordingSchedule(start: start, stop: start.addingTimeInterval(4))
            Task { @MainActor in
                try? await coordinator.proceed(windowID: windowID, appName: "予約テスト", frame: window.frame, schedule: schedule)
            }
            await watch(limit: 15)
            try? await Task.sleep(nanoseconds: 500_000_000)
            HistoryStore.shared.reload()
            let videos = HistoryStore.shared.items.filter { $0.kind == .video }
            if let video = videos.first {
                log("  → 保存された動画: \(video.url.lastPathComponent)・\(String(format: "%.1f", video.duration ?? 0)) 秒（期待 4 秒前後）")
            } else {
                log("  → ✗ 動画が保存されていません")
            }

            // ② 予約して、すぐ取り消す。
            log("② 予約してから取り消す")
            Task { @MainActor in
                try? await coordinator.proceed(
                    windowID: windowID, appName: "予約テスト", frame: window.frame,
                    schedule: RecordingSchedule(start: Date().addingTimeInterval(30), stop: nil)
                )
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            log("  取り消す前: \(describe())")
            coordinator.cancelSchedule()
            await watch(limit: 3)

            // ③ 予約してから「今すぐ開始」し、2 秒後に手で止める。
            log("③ 予約してから今すぐ開始")
            Task { @MainActor in
                try? await coordinator.proceed(
                    windowID: windowID, appName: "予約テスト", frame: window.frame,
                    schedule: RecordingSchedule(start: Date().addingTimeInterval(60), stop: nil)
                )
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            coordinator.startScheduledNow()
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            log("  2.5 秒後: \(describe())")
            coordinator.stop()
            await watch(limit: 5)
            HistoryStore.shared.reload()
            log("  → 作業フォルダの動画: \(HistoryStore.shared.items.filter { $0.kind == .video }.count) 本（期待 2 本）")
            window.close()
        }
    }
}
#endif
