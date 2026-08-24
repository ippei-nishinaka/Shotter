import AppKit

/// 1 ディスプレイを覆う範囲選択用ウィンドウ。
/// 背景にフリーズ画像を敷き、その上に SelectionOverlayView を重ねる。
@MainActor
final class SelectionOverlayWindow: NSWindow {

    let overlayView: SelectionOverlayView

    init(snapshot: DisplaySnapshot) {
        overlayView = SelectionOverlayView()
        overlayView.backingScale = snapshot.scale

        super.init(
            contentRect: snapshot.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = false
        // メニューバーや Dock よりも前面に出す。
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let container = NSView(frame: CGRect(origin: .zero, size: snapshot.frame.size))
        container.autoresizingMask = [.width, .height]

        let imageView = NSImageView(frame: container.bounds)
        imageView.image = NSImage(cgImage: snapshot.image, size: snapshot.frame.size)
        imageView.imageScaling = .scaleAxesIndependently
        imageView.autoresizingMask = [.width, .height]
        container.addSubview(imageView)

        overlayView.frame = container.bounds
        overlayView.autoresizingMask = [.width, .height]
        container.addSubview(overlayView)

        contentView = container
    }

    override var canBecomeKey: Bool { true }

    override var canBecomeMain: Bool { true }
}
