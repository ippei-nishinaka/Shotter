import AppKit

/// 選択された領域。ウィンドウを選んだ場合は角丸のマスクをかけたいので区別する。
struct SelectionResult {
    /// AppKit グローバル座標。
    let rect: CGRect
    /// ウィンドウを選んで撮ったか。
    let isWindow: Bool
}

/// 選択の仕方。
enum CaptureMode {
    /// ドラッグで矩形を選ぶ。
    case area
    /// カーソル下のウィンドウを選ぶ。
    case window

    var toggled: CaptureMode { self == .area ? .window : .area }
}

/// 全ディスプレイにオーバーレイを出し、範囲またはウィンドウの選択を受け付ける。
@MainActor
final class AreaSelectionController: NSObject, SelectionOverlayViewDelegate {

    private var windows: [SelectionOverlayWindow] = []
    private var completion: ((SelectionResult?) -> Void)?

    private var mode: CaptureMode = .area
    private var candidateWindows: [CapturedWindow] = []

    var isActive: Bool { !windows.isEmpty }

    /// - Parameter completion: 選択結果。キャンセル時は nil。
    func begin(
        snapshots: [DisplaySnapshot],
        mode: CaptureMode = .area,
        completion: @escaping (SelectionResult?) -> Void
    ) {
        guard !isActive else { return }
        self.completion = completion
        self.mode = mode
        // モード切り替え（Space）に備えて、どちらのモードでも先に取得しておく。
        self.candidateWindows = WindowLister.onScreenWindows()

        for snapshot in snapshots {
            let window = SelectionOverlayWindow(snapshot: snapshot)
            window.overlayView.delegate = self
            window.overlayView.mode = mode
            windows.append(window)
        }

        // 前面に出す前に描画を済ませておく。
        // 空のウィンドウが 1 フレーム表示されて、そのあと画像が入る…という
        // 二段階の見え方になるのを防ぐ。
        for window in windows {
            window.contentView?.layoutSubtreeIfNeeded()
            window.display()
        }

        // 複数ディスプレイで表示がずれないよう、描画が済んでからまとめて出す。
        for window in windows {
            window.orderFrontRegardless()
        }

        NSApp.activate(ignoringOtherApps: true)

        // マウスカーソルのあるディスプレイのウィンドウをキーにして Esc を受け取れるようにする。
        // すでに前面に出しているので、再度 order させない makeKey を使う。
        let mouseLocation = NSEvent.mouseLocation
        let keyWindow = windows.first { $0.frame.contains(mouseLocation) } ?? windows.first
        keyWindow?.makeKey()
        keyWindow?.makeFirstResponder(keyWindow?.overlayView)

        if mode == .window {
            updateHoveredWindow(at: mouseLocation)
        }
    }

    func cancel() {
        finish(with: nil)
    }

    // MARK: - SelectionOverlayViewDelegate

    func overlayView(_ view: SelectionOverlayView, didUpdateSelection rect: CGRect?) {
        for window in windows {
            window.overlayView.globalSelection = rect
        }
    }

    func overlayView(_ view: SelectionOverlayView, didFinishSelection rect: CGRect) {
        finish(with: SelectionResult(rect: rect, isWindow: false))
    }

    func overlayViewDidCancel(_ view: SelectionOverlayView) {
        finish(with: nil)
    }

    func overlayView(_ view: SelectionOverlayView, didHoverAt globalPoint: CGPoint) {
        guard mode == .window else { return }
        updateHoveredWindow(at: globalPoint)
    }

    func overlayViewDidConfirmHover(_ view: SelectionOverlayView) {
        guard mode == .window, let rect = view.globalSelection else { return }
        finish(with: SelectionResult(rect: rect, isWindow: true))
    }

    /// Space が押されたら、カーソル下のウィンドウをその場で撮る。
    /// （以前はモード切り替えだけで、そのあとクリックが必要だった）
    func overlayViewDidRequestWindowCapture(_ view: SelectionOverlayView) {
        let point = NSEvent.mouseLocation
        guard let hovered = candidateWindows.first(where: { $0.frame.contains(point) }) else {
            NSSound.beep()
            return
        }
        finish(with: SelectionResult(rect: hovered.frame, isWindow: true))
    }

    /// カーソルの下にある一番手前のウィンドウを選択状態にする。
    private func updateHoveredWindow(at point: CGPoint) {
        let hovered = candidateWindows.first { $0.frame.contains(point) }

        for window in windows {
            window.overlayView.globalSelection = hovered?.frame
            window.overlayView.hoverLabel = hovered?.ownerName
        }
    }

    // MARK: - Private

    private func finish(with result: SelectionResult?) {
        guard let completion else { return }
        self.completion = nil

        for window in windows {
            window.overlayView.delegate = nil
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()

        completion(result)
    }
}
