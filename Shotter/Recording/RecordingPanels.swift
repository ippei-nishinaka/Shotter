import AppKit
import SwiftUI

/// ボーダーレスでもキー入力（Return / Esc）を受け取れるパネル。
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private func makeOverlayPanel(contentRect: CGRect, acceptsInput: Bool) -> NSPanel {
    let panel = KeyablePanel(
        contentRect: contentRect,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = acceptsInput
    panel.level = .statusBar
    panel.isReleasedWhenClosed = false
    panel.ignoresMouseEvents = !acceptsInput
    panel.animationBehavior = .none
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    return panel
}

// MARK: - 選択肢

/// 「音」の選択肢。システム音声を録るかどうかと、拾う範囲を 1 つにまとめて見せる。
enum RecordingSoundChoice: Hashable, CaseIterable, Identifiable {
    case none
    case application
    case entireMac

    var id: Self { self }

    /// - Parameter appName: 収録するアプリの名前。まだ分からない場面（設定画面）では nil。
    func title(appName: String?) -> String {
        switch self {
        case .none:        return "入れない"
        case .application: return appName.map { "\($0) の音だけ" } ?? "収録するアプリの音だけ"
        case .entireMac:   return "Mac で鳴る音すべて"
        }
    }

    @MainActor
    static var current: RecordingSoundChoice {
        get {
            guard Preferences.recordsSystemAudio else { return .none }
            return Preferences.systemAudioScope == .entireMac ? .entireMac : .application
        }
        set {
            Preferences.recordsSystemAudio = newValue != .none
            if newValue != .none {
                Preferences.systemAudioScope = newValue == .entireMac ? .entireMac : .application
            }
        }
    }
}

/// 「マイク」の選択肢。使わない／既定のマイク／機器を 1 つのポップアップで選ぶ。
/// 値は機器の ID。使わないときは `off`、既定のマイクは空文字。
@MainActor
enum MicrophoneChoice {
    static let off = "-"
    static let systemDefault = ""

    static var current: String {
        get {
            guard Preferences.recordsMicrophone else { return off }
            return Preferences.microphoneDeviceID ?? systemDefault
        }
        set {
            Preferences.recordsMicrophone = newValue != off
            if newValue != off {
                Preferences.microphoneDeviceID = newValue == systemDefault ? nil : newValue
            }
        }
    }
}

/// マイクのポップアップの中身。収録前のバーと設定画面で共有する。
struct MicrophonePickerItems: View {
    let devices: [MicrophoneDevice]

    var body: some View {
        Text("使わない").tag(MicrophoneChoice.off)
        Divider()
        Text("既定のマイク").tag(MicrophoneChoice.systemDefault)
        ForEach(devices) { device in
            Text(device.name).tag(device.id)
        }
    }
}

// MARK: - 収録前のバー

/// 収録前のバーの状態。変更はその場で設定に保存し、次回も同じ状態で出す。
@MainActor
final class RecordingSetupModel: ObservableObject {

    @Published var sound = RecordingSoundChoice.current {
        didSet { RecordingSoundChoice.current = sound }
    }

    @Published var microphone = MicrophoneChoice.current {
        didSet { MicrophoneChoice.current = microphone }
    }

    @Published var showsCursor = Preferences.showsCursorInRecording {
        didSet { Preferences.showsCursorInRecording = showsCursor }
    }

    @Published var quality = Preferences.recordingQuality {
        didSet { Preferences.recordingQuality = quality }
    }

    let appName: String
    /// ウィンドウの大きさを変えると更新する。
    @Published var pixelSizeDescription: String
    let microphones = MicrophoneCapture.availableDevices()

    init(appName: String, pixelSizeDescription: String) {
        self.appName = appName
        self.pixelSizeDescription = pixelSizeDescription
    }

    var footnote: String {
        let size = quality.sizeEstimateDescription(
            systemAudio: sound != .none,
            microphone: microphone != MicrophoneChoice.off
        )
        let stop = "止めるときは \(Preferences.recordingHotKey.displayString) か、メニューバーの「● 収録中」から"
        return "\(size)　·　\(stop)"
    }
}

struct RecordingSetupView: View {

    @ObservedObject var model: RecordingSetupModel
    let onStart: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "record.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(model.appName) のウィンドウを収録します")
                        .font(.system(size: 16, weight: .bold))
                    Text("赤い枠の中が収録されます（\(model.pixelSizeDescription)）。大きさを変えると枠も追従します。")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 18) {
                Picker("音", selection: $model.sound) {
                    ForEach(RecordingSoundChoice.allCases) { choice in
                        Text(choice.title(appName: model.appName)).tag(choice)
                    }
                }
                .fixedSize()
                .help("「\(model.appName) の音だけ」なら、他のアプリの通知音などは入りません")

                Picker("マイク", selection: $model.microphone) {
                    MicrophonePickerItems(devices: model.microphones)
                }
                .fixedSize()

                Picker("画質", selection: $model.quality) {
                    ForEach(RecordingQuality.allCases) { quality in
                        Text(quality.title).tag(quality)
                    }
                }
                .fixedSize()
                .help(model.quality.detail)
            }

            HStack(spacing: 10) {
                Toggle("マウスポインタを写す", isOn: $model.showsCursor)
                    .toggleStyle(.checkbox)
                    .fixedSize()

                Spacer(minLength: 24)

                Button("キャンセル", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .fixedSize()

                Button(action: onStart) {
                    Label("収録開始", systemImage: "record.circle.fill")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .fixedSize()
            }

            Text(model.footnote)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .fixedSize()
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.red.opacity(0.75), lineWidth: 2)
        )
    }
}

/// 選んだウィンドウの真ん中に収録前のバーを出し、開始かキャンセルかを待つ。
///
/// 見落とさないよう、ほかの画面は暗くして対象のウィンドウだけを明るく残し、赤い枠で囲む。
/// 待っている間にウィンドウを動かしたり大きさを変えたりしても、枠・暗転の穴・バーが追いかける。
@MainActor
enum RecordingSetupPanel {

    /// - Returns: 「収録開始」ならその時点のウィンドウの位置と大きさ、キャンセルなら nil。
    static func run(windowID: CGWindowID, initialFrame: CGRect, appName: String) async -> CGRect? {
        let model = RecordingSetupModel(appName: appName, pixelSizeDescription: sizeText(for: initialFrame))
        var targetFrame = initialFrame

        let dimmers = NSScreen.screens.map { ScreenDimPanel(screen: $0) }
        let border = TargetBorderPanel()
        for dimmer in dimmers { dimmer.update(hole: targetFrame) }
        border.update(frame: targetFrame)
        dimmers.forEach { $0.orderFront() }
        border.orderFront()

        var panel: NSPanel?
        var tracker: Timer?

        let started: Bool = await withCheckedContinuation { continuation in
            var finished = false
            let finish: (Bool) -> Void = { started in
                guard !finished else { return }
                finished = true
                continuation.resume(returning: started)
            }

            let hosting = NSHostingView(
                rootView: RecordingSetupView(
                    model: model,
                    onStart: { finish(true) },
                    onCancel: { finish(false) }
                )
            )
            hosting.layoutSubtreeIfNeeded()
            let size = hosting.fittingSize
            hosting.frame = CGRect(origin: .zero, size: size)
            hosting.autoresizingMask = [.width, .height]

            let created = makeOverlayPanel(contentRect: frame(for: size, centeredOn: targetFrame), acceptsInput: true)
            created.contentView = hosting
            panel = created

            NSApp.activate(ignoringOtherApps: true)
            created.makeKeyAndOrderFront(nil)

            // 表示した直後に SwiftUI の大きさが確定することがあるので、もう一度中身に合わせる。
            DispatchQueue.main.async {
                hosting.layoutSubtreeIfNeeded()
                created.setFrame(frame(for: hosting.fittingSize, centeredOn: targetFrame), display: true)
            }

            // ウィンドウの動きを追いかける。閉じられたら収録できないのでキャンセル扱いにする。
            tracker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                MainActor.assumeIsolated {
                    guard let latest = WindowLister.frame(of: windowID) else {
                        finish(false)
                        return
                    }
                    guard latest != targetFrame else { return }
                    targetFrame = latest
                    border.update(frame: latest)
                    for dimmer in dimmers { dimmer.update(hole: latest) }
                    model.pixelSizeDescription = sizeText(for: latest)
                    // 寸法の桁が変わると文の長さも変わるので、中身に合わせて大きさも取り直す。
                    hosting.layoutSubtreeIfNeeded()
                    created.setFrame(frame(for: hosting.fittingSize, centeredOn: latest), display: true)
                }
            }
        }

        tracker?.invalidate()
        panel?.orderOut(nil)
        border.orderOut()
        dimmers.forEach { $0.orderOut() }
        return started ? targetFrame : nil
    }

    private static func sizeText(for frame: CGRect) -> String {
        let scale = screen(containing: frame)?.backingScaleFactor ?? 2
        return "\(Int(frame.width * scale)) × \(Int(frame.height * scale))"
    }

    /// ウィンドウの真ん中に置く。画面からはみ出す場合は画面の内側へ寄せる。
    private static func frame(for size: CGSize, centeredOn target: CGRect) -> CGRect {
        let visible = screen(containing: target)?.visibleFrame ?? target
        let margin: CGFloat = 12
        var origin = CGPoint(x: target.midX - size.width / 2, y: target.midY - size.height / 2)
        origin.x = min(max(origin.x, visible.minX + margin), visible.maxX - size.width - margin)
        origin.y = min(max(origin.y, visible.minY + margin), visible.maxY - size.height - margin)
        return CGRect(origin: origin, size: size).integral
    }

    private static func screen(containing rect: CGRect) -> NSScreen? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
    }
}

/// 収録対象のウィンドウを囲む赤い枠。クリックは素通しする。
@MainActor
private final class TargetBorderPanel {

    private let panel = makeOverlayPanel(contentRect: .zero, acceptsInput: false)

    init() {
        panel.contentView = NSHostingView(
            rootView: RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.red, lineWidth: 4)
        )
    }

    func update(frame target: CGRect) {
        panel.setFrame(target.insetBy(dx: -4, dy: -4), display: true)
    }

    func orderFront() { panel.orderFrontRegardless() }
    func orderOut() { panel.orderOut(nil) }
}

/// 1 画面ぶんを暗くし、収録するウィンドウの部分だけ穴を開けて明るく残す。クリックは素通しする
/// （暗くなっている間も、ウィンドウの大きさを変えられるように）。
@MainActor
private final class ScreenDimPanel {

    /// 穴あきの暗転をレイヤーで描く（透明なパネルでも確実に描かれるように）。
    private final class DimView: NSView {
        private let shape = CAShapeLayer()

        var hole: CGRect = .zero { didSet { updatePath() } }

        override init(frame: NSRect) {
            super.init(frame: frame)
            shape.fillColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.5)
            shape.fillRule = .evenOdd
            wantsLayer = true
        }

        /// init の時点ではまだレイヤーが無いので、作られるときに暗転の形を載せる。
        override func makeBackingLayer() -> CALayer {
            let layer = CALayer()
            layer.addSublayer(shape)
            return layer
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layout() {
            super.layout()
            updatePath()
        }

        private func updatePath() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            shape.frame = bounds
            let path = CGMutablePath()
            path.addRect(bounds)
            path.addRoundedRect(in: hole, cornerWidth: 10, cornerHeight: 10)
            shape.path = path
            CATransaction.commit()
        }
    }

    private let panel: NSPanel
    private let view = DimView()
    private let screenFrame: CGRect

    init(screen: NSScreen) {
        screenFrame = screen.frame
        panel = makeOverlayPanel(contentRect: screen.frame, acceptsInput: false)
        panel.hasShadow = false
        panel.contentView = view
    }

    /// - Parameter hole: 明るく残す範囲（AppKit グローバル座標）。
    func update(hole: CGRect) {
        view.hole = hole.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
    }

    func orderFront() { panel.orderFrontRegardless() }
    func orderOut() { panel.orderOut(nil) }
}

// MARK: - カウントダウン

@MainActor
private final class CountdownModel: ObservableObject {
    @Published var remaining: Int
    init(remaining: Int) { self.remaining = remaining }
}

private struct CountdownView: View {
    @ObservedObject var model: CountdownModel

    var body: some View {
        VStack(spacing: 4) {
            Text("\(model.remaining)")
                .font(.system(size: 64, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
            Text("Esc でキャンセル")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(width: 150, height: 150)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.black.opacity(0.7))
        )
    }
}

/// ウィンドウの中央に 3・2・1 を出す。
@MainActor
enum RecordingCountdownPanel {

    /// - Returns: 最後まで数えたら true、Esc でキャンセルされたら false。
    static func run(seconds: Int, over target: CGRect) async -> Bool {
        let model = CountdownModel(remaining: seconds)
        let size = CGSize(width: 150, height: 150)
        let panel = makeOverlayPanel(
            contentRect: CGRect(x: target.midX - size.width / 2, y: target.midY - size.height / 2,
                                width: size.width, height: size.height),
            acceptsInput: true
        )
        panel.hasShadow = false
        panel.contentView = NSHostingView(rootView: CountdownView(model: model))
        panel.makeKeyAndOrderFront(nil)

        var isCancelled = false
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event } // Escape
            isCancelled = true
            return nil
        }
        defer {
            if let monitor { NSEvent.removeMonitor(monitor) }
            panel.orderOut(nil)
        }

        for remaining in stride(from: seconds, to: 0, by: -1) {
            model.remaining = remaining
            // Esc にすぐ反応できるよう、1 秒を細かく刻んで待つ。
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if isCancelled { return false }
            }
        }
        return !isCancelled
    }
}
