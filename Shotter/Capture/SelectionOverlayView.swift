import AppKit

@MainActor
protocol SelectionOverlayViewDelegate: AnyObject {
    func overlayView(_ view: SelectionOverlayView, didUpdateSelection rect: CGRect?)
    func overlayView(_ view: SelectionOverlayView, didFinishSelection rect: CGRect)
    func overlayViewDidCancel(_ view: SelectionOverlayView)

    /// ウィンドウモードでカーソルが動いたとき。
    func overlayView(_ view: SelectionOverlayView, didHoverAt globalPoint: CGPoint)
    /// ウィンドウモードでクリックされたとき。
    func overlayViewDidConfirmHover(_ view: SelectionOverlayView)
    /// Space キーで範囲選択とウィンドウ選択を切り替えたとき。
    func overlayViewDidToggleMode(_ view: SelectionOverlayView)
}

/// フリーズ画像の上に重ねる、範囲選択のための描画＋マウス処理レイヤー。
/// 座標はすべて AppKit グローバル座標（左下原点）でやり取りする。
@MainActor
final class SelectionOverlayView: NSView {

    weak var delegate: SelectionOverlayViewDelegate?

    /// 選択範囲（グローバル座標）。ディスプレイをまたぐ場合も含め全オーバーレイで共有する。
    var globalSelection: CGRect? {
        didSet {
            guard globalSelection != oldValue else { return }
            needsDisplay = true
        }
    }

    /// このビューが載っているディスプレイの拡大率。寸法表示をピクセルに換算するのに使う。
    var backingScale: CGFloat = 2

    /// 範囲選択かウィンドウ選択か。
    var mode: CaptureMode = .area {
        didSet { needsDisplay = true }
    }

    /// ウィンドウモードで表示するアプリ名。
    var hoverLabel: String? {
        didSet {
            guard hoverLabel != oldValue else { return }
            needsDisplay = true
        }
    }

    private var anchorPoint: CGPoint?
    private var hoverPoint: CGPoint?
    private var trackingArea: NSTrackingArea?

    private let dimColor = NSColor.black.withAlphaComponent(0.42)
    private let strokeColor = NSColor.white
    private let badgeBackground = NSColor.black.withAlphaComponent(0.78)

    // MARK: - Responder

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - Mouse

    override func mouseEntered(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override func mouseExited(with event: NSEvent) {
        hoverPoint = nil
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        hoverPoint = convert(event.locationInWindow, from: nil)

        switch mode {
        case .area:
            NSCursor.crosshair.set()
            if globalSelection == nil { needsDisplay = true }
        case .window:
            NSCursor.pointingHand.set()
            delegate?.overlayView(self, didHoverAt: globalPoint(for: event))
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard mode == .area else {
            delegate?.overlayViewDidConfirmHover(self)
            return
        }
        anchorPoint = globalPoint(for: event)
        delegate?.overlayView(self, didUpdateSelection: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .area, let anchorPoint else { return }
        let rect = ScreenGeometry.rect(from: anchorPoint, to: globalPoint(for: event))
        delegate?.overlayView(self, didUpdateSelection: rect)
    }

    override func mouseUp(with event: NSEvent) {
        guard mode == .area, let anchorPoint else { return }
        self.anchorPoint = nil

        let rect = ScreenGeometry.rect(from: anchorPoint, to: globalPoint(for: event))
        // ドラッグせずクリックしただけの場合はキャンセル扱いにする。
        guard rect.width >= 4, rect.height >= 4 else {
            delegate?.overlayViewDidCancel(self)
            return
        }
        delegate?.overlayView(self, didFinishSelection: rect)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Escape
            delegate?.overlayViewDidCancel(self)
        case 49: // Space
            delegate?.overlayViewDidToggleMode(self)
        default:
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        delegate?.overlayViewDidCancel(self)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        dimColor.setFill()

        guard let selection = localSelectionRect(), selection.width >= 1, selection.height >= 1 else {
            bounds.fill()
            if mode == .area { drawCrosshair() }
            drawHint()
            return
        }

        // even-odd で選択範囲だけ暗転から抜く。
        let path = NSBezierPath(rect: bounds)
        path.append(NSBezierPath(rect: selection))
        path.windingRule = .evenOdd
        path.fill()

        drawSelectionBorder(selection)

        switch mode {
        case .area:
            drawSizeBadge(for: selection)
        case .window:
            drawWindowBadge(for: selection)
        }
    }

    /// ウィンドウモードで、アプリ名と寸法を選択範囲の中央に出す。
    private func drawWindowBadge(for rect: CGRect) {
        let width = Int((rect.width * backingScale).rounded())
        let height = Int((rect.height * backingScale).rounded())
        let text = "\(hoverLabel ?? "ウィンドウ")  \(width) × \(height)"

        let size = badgeSize(for: text)
        var origin = CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        origin.x = min(max(origin.x, bounds.minX + 4), max(bounds.maxX - size.width - 4, bounds.minX + 4))
        origin.y = min(max(origin.y, bounds.minY + 4), max(bounds.maxY - size.height - 4, bounds.minY + 4))

        drawBadge(text: text, at: origin)
    }

    private func drawSelectionBorder(_ rect: CGRect) {
        NSColor.black.withAlphaComponent(0.55).setStroke()
        let outer = NSBezierPath(rect: rect.insetBy(dx: -1, dy: -1))
        outer.lineWidth = 1
        outer.stroke()

        strokeColor.setStroke()
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 1
        border.stroke()
    }

    private func drawCrosshair() {
        guard let hoverPoint else { return }

        NSColor.white.withAlphaComponent(0.55).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        path.move(to: CGPoint(x: bounds.minX, y: hoverPoint.y.rounded() + 0.5))
        path.line(to: CGPoint(x: bounds.maxX, y: hoverPoint.y.rounded() + 0.5))
        path.move(to: CGPoint(x: hoverPoint.x.rounded() + 0.5, y: bounds.minY))
        path.line(to: CGPoint(x: hoverPoint.x.rounded() + 0.5, y: bounds.maxY))
        path.stroke()
    }

    private func drawHint() {
        guard hoverPoint != nil else { return }
        let text = mode == .area
            ? "ドラッグして範囲を選択　·　Space でウィンドウ選択　·　Esc でキャンセル"
            : "ウィンドウをクリックして撮影　·　Space で範囲選択　·　Esc でキャンセル"
        let size = badgeSize(for: text)
        let origin = CGPoint(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2
        )
        drawBadge(text: text, at: origin)
    }

    private func drawSizeBadge(for rect: CGRect) {
        let width = Int((rect.width * backingScale).rounded())
        let height = Int((rect.height * backingScale).rounded())
        let text = "\(width) × \(height)"
        let size = badgeSize(for: text)

        var origin = CGPoint(x: rect.minX, y: rect.minY - size.height - 8)
        if origin.y < bounds.minY + 4 {
            origin.y = rect.minY + 8   // 下に置けなければ選択範囲の内側へ
        }
        origin.x = min(max(origin.x, bounds.minX + 4), bounds.maxX - size.width - 4)

        drawBadge(text: text, at: origin)
    }

    // MARK: - Badge helpers

    private var badgeAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
    }

    private func badgeSize(for text: String) -> CGSize {
        let textSize = (text as NSString).size(withAttributes: badgeAttributes)
        return CGSize(width: ceil(textSize.width) + 16, height: ceil(textSize.height) + 8)
    }

    private func drawBadge(text: String, at origin: CGPoint) {
        let size = badgeSize(for: text)
        let box = CGRect(origin: origin, size: size)

        badgeBackground.setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()

        let textSize = (text as NSString).size(withAttributes: badgeAttributes)
        let textOrigin = CGPoint(
            x: box.midX - textSize.width / 2,
            y: box.midY - textSize.height / 2
        )
        (text as NSString).draw(at: textOrigin, withAttributes: badgeAttributes)
    }

    // MARK: - Coordinate helpers

    private func globalPoint(for event: NSEvent) -> CGPoint {
        guard let window else { return event.locationInWindow }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    private func localSelectionRect() -> CGRect? {
        guard let globalSelection, let window else { return nil }
        let frame = window.frame
        return globalSelection.offsetBy(dx: -frame.minX, dy: -frame.minY)
    }
}
