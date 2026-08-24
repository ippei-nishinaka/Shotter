import AppKit

/// 画像とその上の注釈レイヤーを Core Graphics で描画するキャンバス。
///
/// - ビューは `isFlipped = true`。したがって CGContext の座標系は「左上原点・y 下向き」となり、
///   注釈が保持している画像ピクセル座標と向きが一致する。
/// - 書き出し時（AnnotationRenderer.flatten）も同じ向きに揃えてあるため、
///   画面表示と書き出しで同一の描画コードを共有できる。
@MainActor
final class AnnotationCanvasView: NSView {

    var store: AnnotationStore? {
        didSet {
            recomputeLayout()
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }

    /// 画像を表示している矩形（ビュー座標）。
    private(set) var imageRect: CGRect = .zero

    /// ビューのポイント数 ÷ 画像ピクセル数。
    private(set) var displayScale: CGFloat = 1

    override var isFlipped: Bool { true }

    override var acceptsFirstResponder: Bool { true }

    private let canvasInset: CGFloat = 16

    /// ドラッグ中の未確定の注釈。マウスアップで store へ確定させる。
    private var draft: (any DragCreatableAnnotation)?

    /// テキスト入力中に画像の上へ重ねる NSTextView。
    private var textEditor: NSTextView?
    private var editingText: TextAnnotation?

    /// 選択ツールでのドラッグ状態。
    private enum SelectionDrag {
        case none
        case move(previous: CGPoint)
        case resize(handle: AnnotationHandle.Kind)
    }

    private var selectionDrag: SelectionDrag = .none

    /// ドラッグで実際に動かしたときだけアンドゥ履歴を積むためのフラグ。
    private var hasRecordedUndoForDrag = false

    /// つまみの半径（ビューのポイント。拡大率によらず一定にする）。
    private let handleRadius: CGFloat = 4.5

    // MARK: - レイアウト

    override func layout() {
        super.layout()
        recomputeLayout()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        recomputeLayout()
        needsDisplay = true
    }

    private func recomputeLayout() {
        guard let store, store.imageSize.width > 0, store.imageSize.height > 0 else {
            imageRect = .zero
            displayScale = 1
            return
        }

        let available = CGSize(
            width: max(bounds.width - canvasInset * 2, 1),
            height: max(bounds.height - canvasInset * 2, 1)
        )

        // 等倍（＝撮影時のポイントサイズ）を超えて拡大はしない。
        let naturalScale = store.pointSize.width > 0
            ? store.pointSize.width / store.imageSize.width
            : 1
        let fitScale = min(
            available.width / store.imageSize.width,
            available.height / store.imageSize.height
        )
        displayScale = min(fitScale, naturalScale)

        let size = CGSize(
            width: (store.imageSize.width * displayScale).rounded(),
            height: (store.imageSize.height * displayScale).rounded()
        )
        imageRect = CGRect(
            x: ((bounds.width - size.width) / 2).rounded(),
            y: ((bounds.height - size.height) / 2).rounded(),
            width: size.width,
            height: size.height
        )
    }

    // MARK: - 描画

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()

        guard let store, !imageRect.isEmpty else { return }

        context.interpolationQuality = .high
        drawSourceImage(store.sourceImage, in: context)
        drawImageBorder()
        drawAnnotationLayer(store, in: context)
        drawSelectionOverlay(store)
    }

    /// 選択中の注釈の外枠とリサイズつまみ。
    /// 画像の拡大率に関係なく一定の大きさで出したいので、ビュー座標のまま描く。
    private func drawSelectionOverlay(_ store: AnnotationStore) {
        guard store.tool == .select, let selected = store.selectedAnnotation else { return }

        let box = viewRect(from: selected.boundingBox).insetBy(dx: -2, dy: -2)
        let outline = NSBezierPath(rect: box)
        outline.lineWidth = 1
        outline.setLineDash([4, 3], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        outline.stroke()

        guard let resizable = selected as? ResizableAnnotation else { return }
        for handle in resizable.handles {
            let center = viewPoint(from: handle.position)
            let dot = NSBezierPath(ovalIn: CGRect(
                x: center.x - handleRadius,
                y: center.y - handleRadius,
                width: handleRadius * 2,
                height: handleRadius * 2
            ))
            NSColor.white.setFill()
            dot.fill()
            NSColor.controlAccentColor.setStroke()
            dot.lineWidth = 1.5
            dot.stroke()
        }
    }

    private func drawSourceImage(_ image: CGImage, in context: CGContext) {
        // flipped ビューでは CGImage が上下反転して描かれるため、画像矩形の中で y 軸を戻す。
        context.saveGState()
        context.translateBy(x: 0, y: imageRect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(
            image,
            in: CGRect(x: imageRect.minX, y: 0, width: imageRect.width, height: imageRect.height)
        )
        context.restoreGState()
    }

    private func drawImageBorder() {
        NSColor.separatorColor.setStroke()
        let border = NSBezierPath(rect: imageRect.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        border.stroke()
    }

    private func drawAnnotationLayer(_ store: AnnotationStore, in context: CGContext) {
        context.saveGState()
        context.clip(to: imageRect)
        context.translateBy(x: imageRect.minX, y: imageRect.minY)
        context.scaleBy(x: displayScale, y: displayScale)
        var annotations = store.annotations
        if let draft { annotations.append(draft) }
        AnnotationRenderer.drawAnnotations(
            annotations,
            in: context,
            environment: store.renderEnvironment
        )
        context.restoreGState()
    }

    // MARK: - マウス操作

    override func mouseDown(with event: NSEvent) {
        guard let store else { return }

        // 編集中にキャンバスをクリックしたら、まず入力を確定させる。
        if textEditor != nil {
            endTextEditing(commit: true)
            return
        }

        let viewPoint = convert(event.locationInWindow, from: nil)
        guard imageRect.contains(viewPoint) else { return }

        if store.tool == .text {
            beginTextEditing(at: clampedImagePoint(from: viewPoint), store: store)
            return
        }

        if store.tool == .select {
            handleSelectionMouseDown(event, viewPoint: viewPoint, store: store)
            return
        }

        draft = AnnotationFactory.makeDraft(at: clampedImagePoint(from: viewPoint), store: store)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if case .none = selectionDrag {} else {
            handleSelectionDrag(event)
            return
        }
        guard let draft else { return }
        draft.updateDrag(to: clampedImagePoint(for: event), constrained: event.modifierFlags.contains(.shift))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if case .none = selectionDrag {} else {
            selectionDrag = .none
            return
        }
        guard let store, let draft else { return }
        self.draft = nil

        draft.updateDrag(to: clampedImagePoint(for: event), constrained: event.modifierFlags.contains(.shift))
        if draft.isValidForCommit {
            store.add(draft)
        }
        needsDisplay = true
    }

    override func resetCursorRects() {
        guard let store, store.tool != .select, !imageRect.isEmpty else { return }
        addCursorRect(imageRect, cursor: .crosshair)
    }

    /// 画像の外へドラッグしても座標が画像内に収まるようにする。
    private func clampedImagePoint(from viewPoint: CGPoint) -> CGPoint {
        guard let store else { return .zero }
        return Geometry.clamp(
            imagePoint(from: viewPoint),
            to: CGRect(origin: .zero, size: store.imageSize)
        )
    }

    private func clampedImagePoint(for event: NSEvent) -> CGPoint {
        clampedImagePoint(from: convert(event.locationInWindow, from: nil))
    }

    // MARK: - 座標変換

    /// ビュー座標 → 画像ピクセル座標（左上原点）。
    func imagePoint(from viewPoint: CGPoint) -> CGPoint {
        guard displayScale > 0 else { return .zero }
        return CGPoint(
            x: (viewPoint.x - imageRect.minX) / displayScale,
            y: (viewPoint.y - imageRect.minY) / displayScale
        )
    }

    /// 画像ピクセル座標 → ビュー座標。
    func viewPoint(from imagePoint: CGPoint) -> CGPoint {
        CGPoint(
            x: imagePoint.x * displayScale + imageRect.minX,
            y: imagePoint.y * displayScale + imageRect.minY
        )
    }

    /// 画像ピクセル座標の矩形 → ビュー座標の矩形。
    func viewRect(from imageRect: CGRect) -> CGRect {
        CGRect(
            x: imageRect.minX * displayScale + self.imageRect.minX,
            y: imageRect.minY * displayScale + self.imageRect.minY,
            width: imageRect.width * displayScale,
            height: imageRect.height * displayScale
        )
    }

    /// イベント位置を画像ピクセル座標へ変換する。
    func imagePoint(for event: NSEvent) -> CGPoint {
        imagePoint(from: convert(event.locationInWindow, from: nil))
    }
}

// MARK: - テキスト入力

extension AnnotationCanvasView: NSTextViewDelegate {

    /// 編集中かどうか。ウィンドウ側から確定させたいときに使う。
    var isEditingText: Bool { textEditor != nil }

    func beginTextEditing(at point: CGPoint, store: AnnotationStore) {
        beginTextEditing(
            with: TextAnnotation(
                origin: point,
                text: "",
                style: store.currentStyle,
                maxWidth: max(store.imageSize.width - point.x, store.fontSize * 4)
            ),
            store: store
        )
    }

    /// 既存のテキスト注釈を編集し直す（ダブルクリック時）。
    func beginTextEditing(with annotation: TextAnnotation, store: AnnotationStore) {
        editingText = annotation

        let textView = NSTextView(frame: textEditorFrame(for: annotation))
        textView.delegate = self
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = true
        textView.backgroundColor = NSColor.black.withAlphaComponent(0.25)
        textView.insertionPointColor = annotation.style.color
        textView.textColor = annotation.style.color
        textView.font = TextAnnotation.font(ofSize: annotation.style.fontSize * displayScale)
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false

        textView.string = annotation.text

        addSubview(textView)
        textEditor = textView
        window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: annotation.text.count, length: 0))
        textDidChange(Notification(name: NSText.didChangeNotification))
    }

    func endTextEditing(commit: Bool) {
        guard let textView = textEditor, let annotation = editingText else { return }
        textEditor = nil
        editingText = nil

        let entered = textView.string
        textView.removeFromSuperview()
        window?.makeFirstResponder(self)

        guard commit, !entered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            needsDisplay = true
            return
        }

        annotation.text = entered
        store?.add(annotation)
        needsDisplay = true
    }

    /// 入力量に合わせて高さを伸ばす。
    private func textEditorFrame(for annotation: TextAnnotation) -> CGRect {
        let origin = viewPoint(from: annotation.origin)
        let lineHeight = annotation.style.fontSize * displayScale * 1.35
        return CGRect(
            x: origin.x,
            y: origin.y,
            width: max(annotation.maxWidth * displayScale, lineHeight * 3),
            height: lineHeight
        )
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard let textView = textEditor, let layoutManager = textView.layoutManager,
              let container = textView.textContainer
        else { return }

        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        var frame = textView.frame
        frame.size.height = max(used.height, frame.height)
        textView.frame = frame
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            endTextEditing(commit: true)
            return true
        }
        return false
    }
}

// MARK: - 選択ツール

extension AnnotationCanvasView {

    private func handleSelectionMouseDown(_ event: NSEvent, viewPoint: CGPoint, store: AnnotationStore) {
        hasRecordedUndoForDrag = false
        let imagePoint = clampedImagePoint(from: viewPoint)

        // 1. 選択中の注釈のつまみを掴んだか。
        if let resizable = store.selectedAnnotation as? ResizableAnnotation,
           let handle = grabbedHandle(of: resizable, at: viewPoint) {
            selectionDrag = .resize(handle: handle)
            return
        }

        // 2. 手前にあるものから順にヒットテストする。
        if let hit = store.annotations.reversed().first(where: { $0.hitTest(imagePoint) }) {
            // テキストはダブルクリックで再編集。
            if event.clickCount == 2, let text = hit as? TextAnnotation {
                store.remove(text)
                beginTextEditing(with: text, store: store)
                return
            }

            store.select(hit)
            selectionDrag = .move(previous: imagePoint)
            needsDisplay = true
            return
        }

        // 3. 何もない場所なら選択解除。
        store.select(nil)
        selectionDrag = .none
        needsDisplay = true
    }

    private func handleSelectionDrag(_ event: NSEvent) {
        guard let store, let selected = store.selectedAnnotation else { return }
        let point = clampedImagePoint(for: event)

        switch selectionDrag {
        case .move(let previous):
            guard previous != point else { return }
            recordUndoOnceForDrag(store)
            selected.translate(by: CGVector(dx: point.x - previous.x, dy: point.y - previous.y))
            selectionDrag = .move(previous: point)

        case .resize(let handle):
            guard let resizable = selected as? ResizableAnnotation else { return }
            recordUndoOnceForDrag(store)
            resizable.moveHandle(handle, to: point, constrained: event.modifierFlags.contains(.shift))

        case .none:
            return
        }

        store.didChange()
        needsDisplay = true
    }

    /// クリックしただけで履歴が増えないよう、実際に動かした最初の 1 回だけ積む。
    private func recordUndoOnceForDrag(_ store: AnnotationStore) {
        guard !hasRecordedUndoForDrag else { return }
        hasRecordedUndoForDrag = true
        store.beginMutation()
    }

    private func grabbedHandle(
        of annotation: ResizableAnnotation,
        at location: CGPoint
    ) -> AnnotationHandle.Kind? {
        let tolerance = handleRadius + 3
        for handle in annotation.handles {
            let center = viewPoint(from: handle.position)
            if hypot(location.x - center.x, location.y - center.y) <= tolerance {
                return handle.kind
            }
        }
        return nil
    }
}
