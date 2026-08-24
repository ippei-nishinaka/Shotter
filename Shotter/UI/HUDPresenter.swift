import AppKit

/// 画面下部に短時間だけ表示される通知バッジ。
/// アプリをアクティブにせずに出したいので nonactivatingPanel を使う。
@MainActor
enum HUDPresenter {

    private static var panels: [NSPanel] = []

    static func show(_ message: String, symbolName: String? = nil, duration: TimeInterval = 1.4) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let screen else { return }

        let content = makeContentView(message: message, symbolName: symbolName)
        let size = content.fittingSize

        let origin = CGPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.visibleFrame.minY + 90
        )

        let panel = NSPanel(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = content

        panels.append(panel)
        panel.orderFrontRegardless()

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            await withCheckedContinuation { continuation in
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.25
                    panel.animator().alphaValue = 0
                } completionHandler: {
                    continuation.resume()
                }
            }
            panel.orderOut(nil)
            panels.removeAll { $0 === panel }
        }
    }

    private static func makeContentView(message: String, symbolName: String?) -> NSView {
        let container = NSVisualEffectView()
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        if let symbolName,
           let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            image.isTemplate = true
            let imageView = NSImageView(image: image)
            imageView.contentTintColor = .labelColor
            stack.addArrangedSubview(imageView)
        }

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        stack.addArrangedSubview(label)

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        container.frame = CGRect(origin: .zero, size: stack.fittingSize)
        return container
    }
}
