import AppKit
import SwiftUI

/// 撮影直後に画面隅へ出すサムネイル。
/// クリックすると注釈エディタが開き、一定時間で自動的に消える。
@MainActor
final class CaptureThumbnailModel: ObservableObject {

    /// 残り時間の割合（1 → 0）。
    @Published private(set) var remaining: Double = 1
    @Published var isHovering = false

    let image: NSImage
    let duration: TimeInterval

    private var countdown: Task<Void, Never>?
    private var onExpire: (() -> Void)?

    init(image: NSImage, duration: TimeInterval) {
        self.image = image
        self.duration = duration
    }

    func start(onExpire: @escaping () -> Void) {
        self.onExpire = onExpire
        countdown?.cancel()
        countdown = Task { @MainActor [weak self] in
            let tick: TimeInterval = 0.05
            var elapsed: TimeInterval = 0

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(tick * 1_000_000_000))
                guard let self else { return }

                // マウスが乗っている間はカウントダウンを止める。
                if self.isHovering { continue }

                elapsed += tick
                self.remaining = max(0, 1 - elapsed / self.duration)
                if self.remaining <= 0 {
                    self.onExpire?()
                    return
                }
            }
        }
    }

    func stop() {
        countdown?.cancel()
        countdown = nil
    }
}

struct CaptureThumbnailView: View {

    @ObservedObject var model: CaptureThumbnailModel
    let onOpenEditor: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            thumbnail
            message
            progressBar
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Material.regular)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            if model.isHovering {
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.white, Color.black.opacity(0.55))
                }
                .buttonStyle(.plain)
                .padding(4)
                .help("閉じる")
            }
        }
        .frame(width: 220)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpenEditor)
        .onHover { model.isHovering = $0 }
    }

    private var thumbnail: some View {
        Image(nsImage: model.image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 200, height: 125)
            .background(Color.black.opacity(0.25))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
            )
    }

    private var message: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("クリップボードにコピーしました", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.green)

            Label(
                model.isHovering ? "クリックして注釈エディタを開く" : "クリックで編集（残り \(secondsLeft) 秒）",
                systemImage: "pencil.tip.crop.circle"
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var progressBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(model.isHovering ? Color.accentColor : Color.secondary)
                    .frame(width: proxy.size.width * model.remaining)
            }
        }
        .frame(height: 3)
    }

    private var secondsLeft: Int {
        max(1, Int((model.remaining * model.duration).rounded(.up)))
    }
}

/// サムネイルパネルの表示・破棄を管理する。
@MainActor
enum CaptureThumbnailPresenter {

    private static var panel: NSPanel?
    private static var model: CaptureThumbnailModel?

    static func show(
        image: CGImage,
        pointSize: CGSize,
        duration: TimeInterval = 10,
        onOpenEditor: @escaping () -> Void
    ) {
        dismiss()

        let nsImage = NSImage(cgImage: image, size: pointSize)
        let model = CaptureThumbnailModel(image: nsImage, duration: duration)
        self.model = model

        let hosting = NSHostingView(
            rootView: CaptureThumbnailView(
                model: model,
                onOpenEditor: {
                    dismiss()
                    onOpenEditor()
                },
                onDismiss: { dismiss() }
            )
        )
        hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)

        let panel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = hosting
        panel.setFrame(frame(for: hosting.fittingSize), display: false)

        self.panel = panel
        panel.orderFrontRegardless()

        model.start { dismiss() }
    }

    static func dismiss() {
        model?.stop()
        model = nil

        guard let panel else { return }
        self.panel = nil

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }

    /// フェードを待たず即座に隠す。新しい撮影を始める直前など、
    /// 「消えている」ことがすぐ確定していてほしい場面で使う。
    static func dismissImmediately() {
        model?.stop()
        model = nil

        guard let panel else { return }
        self.panel = nil
        panel.orderOut(nil)
    }

    /// マウスのあるディスプレイの右下に置く。
    private static func frame(for size: CGSize) -> CGRect {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]

        let visible = screen.visibleFrame
        let margin: CGFloat = 20

        return CGRect(
            x: visible.maxX - size.width - margin,
            y: visible.minY + margin,
            width: size.width,
            height: size.height
        )
    }
}
