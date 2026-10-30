import AppKit
import AVFoundation
import SwiftUI

/// AVPlayerLayer をそのまま背後のレイヤーにしたビュー。
final class PlayerLayerView: NSView {

    let playerLayer = AVPlayerLayer()

    init(player: AVPlayer) {
        super.init(frame: .zero)
        wantsLayer = true
        playerLayer.player = player
        // 枠はキャンバス側で動画と同じ縦横比に合わせるので、引き伸ばしで構わない。
        playerLayer.videoGravity = .resize
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func makeBackingLayer() -> CALayer { playerLayer }

    override var isFlipped: Bool { true }
}

/// 動画プレイヤーの上に、静止画と同じ注釈キャンバスを透明にして重ねたもの。
///
/// キャンバスは下地を描かず、動画を置く矩形（imageRect）を教えてくれるので、
/// そこにプレイヤーを合わせる。描く・選ぶ・動かすといった操作は静止画とまったく同じ。
final class VideoCanvasContainerView: NSView {

    let playerView: PlayerLayerView
    let canvas = AnnotationCanvasView()

    init(player: AVPlayer) {
        playerView = PlayerLayerView(player: player)
        super.init(frame: .zero)

        canvas.drawsSourceImage = false
        canvas.autoresizingMask = [.width, .height]
        canvas.onImageRectChange = { [weak self] rect in
            self?.playerView.frame = rect
        }

        addSubview(playerView)
        addSubview(canvas)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        canvas.frame = bounds
    }
}

struct VideoCanvasRepresentable: NSViewRepresentable {

    @ObservedObject var store: AnnotationStore
    let player: AVPlayer
    let onCanvasMouseDown: () -> Void

    func makeNSView(context: Context) -> VideoCanvasContainerView {
        let view = VideoCanvasContainerView(player: player)
        view.canvas.store = store
        view.canvas.onMouseDown = onCanvasMouseDown
        return view
    }

    func updateNSView(_ nsView: VideoCanvasContainerView, context: Context) {
        nsView.canvas.store = store
        nsView.canvas.refreshTextEditingStyle()
        nsView.canvas.needsDisplay = true
    }
}
