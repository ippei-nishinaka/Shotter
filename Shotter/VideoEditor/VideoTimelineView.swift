import AppKit
import SwiftUI

/// 「1:02.3」「1:02:03.4」の形で時刻を書く・読む。
enum Timecode {

    static func format(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let tenths = Int((clamped * 10).rounded())
        let hours = tenths / 36_000
        let minutes = (tenths % 36_000) / 600
        let secs = (tenths % 600) / 10
        let fraction = tenths % 10
        return hours > 0
            ? String(format: "%d:%02d:%02d.%d", hours, minutes, secs, fraction)
            : String(format: "%d:%02d.%d", minutes, secs, fraction)
    }

    /// 「1:02.3」「62.3」「1:02:03」のどれでも読めるようにする。
    static func parse(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":").map(String.init)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part), value >= 0 else { return nil }
            total = total * 60 + value
        }
        return total
    }
}

/// 時刻の入力欄に使うフォーマッタ。
final class TimecodeFormatter: Formatter {
    override func string(for obj: Any?) -> String? {
        (obj as? Double).map(Timecode.format)
    }

    override func getObjectValue(
        _ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?,
        for string: String,
        errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) -> Bool {
        guard let value = Timecode.parse(string) else { return false }
        obj?.pointee = value as NSNumber
        return true
    }
}

/// 動画エディタの下側。再生ボタン・目盛り・トリム・注釈ごとの表示時間を並べる。
struct VideoTimelineView: View {

    @ObservedObject var store: VideoEditorStore
    @ObservedObject var annotations: AnnotationStore

    /// タイムラインの拡大率。長い動画で短い注釈を扱うときに上げる。
    @State private var zoom: Double = 1

    private let laneHeight: CGFloat = 22
    private let rulerHeight: CGFloat = 26
    private let horizontalPadding: CGFloat = 12

    var body: some View {
        VStack(spacing: 0) {
            transportBar
            Divider()
            GeometryReader { proxy in
                let width = max(proxy.size.width, proxy.size.width * zoom)
                ScrollView(zoom > 1 ? [.horizontal, .vertical] : [.vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            lanes(width: width)
                        } header: {
                            ruler(width: width)
                        }
                    }
                    .frame(width: width)
                    .overlay(alignment: .topLeading) { playhead(width: width) }
                }
            }
            Divider()
            selectionBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - 上段（再生・時刻・トリム）

    private var transportBar: some View {
        HStack(spacing: 10) {
            Button(action: store.togglePlayback) {
                Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 18)
            }
            .help(store.isPlaying ? "一時停止（Space）" : "再生（Space）")

            // 何秒動くのか・どのキーなのかが見て分かるよう、文字とキーを並べて出す。
            Button { store.skip(seconds: -VideoEditorStore.skipInterval) } label: {
                Label("3 秒戻る  ←", systemImage: "gobackward")
            }
            .help("3 秒戻ります（← キー）")
            Button { store.skip(seconds: VideoEditorStore.skipInterval) } label: {
                Label("3 秒進む  →", systemImage: "goforward")
            }
            .help("3 秒進みます（→ キー）")

            Button { store.step(frames: -1) } label: { Image(systemName: "backward.frame.fill") }
                .help("1 コマ戻る（⇧←）")
            Button { store.step(frames: 1) } label: { Image(systemName: "forward.frame.fill") }
                .help("1 コマ進む（⇧→）")

            Text("\(Timecode.format(store.currentTime)) / \(Timecode.format(store.duration))")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)

            Picker("速度", selection: $store.playbackRate) {
                ForEach(VideoEditorStore.playbackRates, id: \.self) { rate in
                    Text(VideoEditorStore.rateLabel(rate)).tag(rate)
                }
            }
            .fixedSize()
            .help("再生速度（0.25 倍〜3 倍）")

            Spacer(minLength: 12)

            HStack(spacing: 6) {
                Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                Slider(value: $zoom, in: 1...maxZoom)
                    .frame(width: 110)
                Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
            }
            .help("タイムラインの拡大")

            Divider().frame(height: 16)

            Text("トリム")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Button("再生位置から") { store.setTrim(start: store.currentTime, end: store.trimEnd) }
                .help("書き出しを、今の再生位置から始めます")
            Button("再生位置まで") { store.setTrim(start: store.trimStart, end: store.currentTime) }
                .help("書き出しを、今の再生位置で終えます")
            Button("リセット") { store.setTrim(start: 0, end: store.duration) }
                .disabled(!store.isTrimmed)
        }
        .controlSize(.small)
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 6)
    }

    /// 短い動画ではあまり拡大しても仕方がないので、長さに応じて上限を決める（0.5 秒が 40pt くらいまで）。
    private var maxZoom: Double {
        max(2, min(400, store.duration / 10))
    }

    // MARK: - 目盛り

    private func xPosition(_ time: Double, width: CGFloat) -> CGFloat {
        let usable = width - horizontalPadding * 2
        return horizontalPadding + usable * CGFloat(time / max(store.duration, 0.001))
    }

    private func time(at x: CGFloat, width: CGFloat) -> Double {
        let usable = max(width - horizontalPadding * 2, 1)
        return Double((x - horizontalPadding) / usable) * store.duration
    }

    private func ruler(width: CGFloat) -> some View {
        let interval = tickInterval(width: width)
        return ZStack(alignment: .topLeading) {
            Color(nsColor: .controlBackgroundColor)

            Canvas { context, size in
                var tick = 0.0
                while tick <= store.duration + 0.0001 {
                    let x = xPosition(tick, width: width)
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: size.height - 8))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(path, with: .color(.secondary), lineWidth: 1)
                    context.draw(
                        Text(Self.tickLabel(tick, interval: interval))
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundColor(.secondary),
                        at: CGPoint(x: x + 3, y: 3),
                        anchor: .topLeading
                    )
                    tick += interval
                }
            }

            trimShade(width: width, height: rulerHeight)
            trimHandle(isStart: true, width: width)
            trimHandle(isStart: false, width: width)
        }
        .frame(width: width, height: rulerHeight)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if store.isPlaying { store.pause() }
                    store.seek(to: time(at: value.location.x, width: width))
                }
        )
        .help("クリック・ドラッグで再生位置を動かします")
    }

    /// 目盛りの文字が重ならない間隔（約 80pt おき）を選ぶ。
    private func tickInterval(width: CGFloat) -> Double {
        let candidates: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200]
        let secondsPerPoint = store.duration / Double(max(width - horizontalPadding * 2, 1))
        return candidates.first { $0 / secondsPerPoint >= 80 } ?? 7200
    }

    private static func tickLabel(_ seconds: Double, interval: Double) -> String {
        if interval < 1 { return Timecode.format(seconds) }
        let total = Int(seconds.rounded())
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    /// 書き出さない範囲を暗くする。
    private func trimShade(width: CGFloat, height: CGFloat) -> some View {
        let start = xPosition(store.trimStart, width: width)
        let end = xPosition(store.trimEnd, width: width)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.black.opacity(0.28))
                .frame(width: max(0, start), height: height)
            Rectangle()
                .fill(Color.black.opacity(0.28))
                .frame(width: max(0, width - end), height: height)
                .offset(x: end)
        }
        .allowsHitTesting(false)
    }

    @State private var trimDragOrigin: Double?

    private func trimHandle(isStart: Bool, width: CGFloat) -> some View {
        let time = isStart ? store.trimStart : store.trimEnd
        return RoundedRectangle(cornerRadius: 2)
            .fill(Color.yellow)
            .frame(width: 6, height: rulerHeight)
            .offset(x: xPosition(time, width: width) - (isStart ? 0 : 6))
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let origin = trimDragOrigin ?? time
                        if trimDragOrigin == nil { trimDragOrigin = time }
                        let delta = self.time(at: value.translation.width + horizontalPadding, width: width)
                        if isStart {
                            store.setTrim(start: origin + delta, end: store.trimEnd)
                        } else {
                            store.setTrim(start: store.trimStart, end: origin + delta)
                        }
                    }
                    .onEnded { _ in trimDragOrigin = nil }
            )
            .help(isStart ? "書き出しの開始位置（ドラッグで調整）" : "書き出しの終了位置（ドラッグで調整）")
    }

    private func playhead(width: CGFloat) -> some View {
        Rectangle()
            .fill(Color.red)
            .frame(width: 1.5)
            .frame(maxHeight: .infinity)
            .offset(x: xPosition(store.currentTime, width: width))
            .allowsHitTesting(false)
    }

    // MARK: - 注釈のレーン

    @ViewBuilder
    private func lanes(width: CGFloat) -> some View {
        if annotations.annotations.isEmpty {
            Text("動画の上に注釈を描くと、ここに表示時間のバーが並びます（描いた位置から \(Int(VideoEditorStore.defaultAnnotationDuration)) 秒間）。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 10)
                .frame(width: width, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(annotations.annotations, id: \.id) { annotation in
                    if let range = store.range(for: annotation.id) {
                        AnnotationLane(
                            annotation: annotation,
                            range: range,
                            isSelected: annotations.selectedID == annotation.id,
                            width: width,
                            height: laneHeight,
                            xPosition: { xPosition($0, width: width) },
                            timeDelta: { dx in Double(dx / max(width - horizontalPadding * 2, 1)) * store.duration },
                            onSelect: { store.selectFromTimeline(annotation.id) },
                            onMove: { store.moveRange(annotation.id, toStart: $0) },
                            onResize: { start, end in store.setRange(annotation.id, start: start, end: end) }
                        )
                    }
                }
            }
            .padding(.vertical, 4)
            .frame(width: width, alignment: .leading)
            .background(alignment: .topLeading) {
                trimShade(width: width, height: CGFloat(annotations.annotations.count) * (laneHeight + 2) + 8)
            }
        }
    }

    // MARK: - 下段（選んだ注釈の表示時間）

    @ViewBuilder
    private var selectionBar: some View {
        HStack(spacing: 8) {
            if let id = annotations.selectedID, let range = store.range(for: id) {
                Text("選択中の注釈を表示する時間")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                TextField("開始", value: startBinding(id, range), formatter: TimecodeFormatter())
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
                Text("〜")
                TextField("終了", value: endBinding(id, range), formatter: TimecodeFormatter())
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
                Text("（\(String(format: "%.1f", range.duration)) 秒）")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)

                Button("再生位置から") { store.setStartToCurrentTime(id) }
                    .help("表示を今の再生位置から始めます（[ キー）")
                Button("再生位置まで") { store.setEndToCurrentTime(id) }
                    .help("表示を今の再生位置で終えます（] キー）")
                Button("最後まで") { store.setRange(id, start: range.start, end: store.duration) }
            } else {
                Text("注釈を選ぶと、表示する時間を秒単位で指定できます。バーの両端をドラッグしても変えられます。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .controlSize(.small)
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 6)
        .frame(height: 32)
    }

    private func startBinding(_ id: UUID, _ range: AnnotationTimeRange) -> Binding<Double> {
        Binding(
            get: { store.range(for: id)?.start ?? range.start },
            set: { store.setRange(id, start: $0, end: store.range(for: id)?.end ?? range.end) }
        )
    }

    private func endBinding(_ id: UUID, _ range: AnnotationTimeRange) -> Binding<Double> {
        Binding(
            get: { store.range(for: id)?.end ?? range.end },
            set: { store.setRange(id, start: store.range(for: id)?.start ?? range.start, end: $0) }
        )
    }
}

/// 注釈 1 つ分の表示時間のバー。本体をドラッグで移動、両端をドラッグで伸び縮み。
private struct AnnotationLane: View {

    let annotation: Annotation
    let range: AnnotationTimeRange
    let isSelected: Bool
    let width: CGFloat
    let height: CGFloat
    let xPosition: (Double) -> CGFloat
    let timeDelta: (CGFloat) -> Double
    let onSelect: () -> Void
    let onMove: (Double) -> Void
    let onResize: (Double, Double) -> Void

    /// ドラッグを始めたときの表示時間。移動量はここからの差で計算する。
    @State private var dragOrigin: AnnotationTimeRange?

    private let edgeWidth: CGFloat = 6

    var body: some View {
        let start = xPosition(range.start)
        let barWidth = max(xPosition(range.end) - start, edgeWidth * 2 + 2)

        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color(nsColor: annotation.style.color).opacity(isSelected ? 0.55 : 0.32))
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color(nsColor: annotation.style.color).opacity(0.8),
                              lineWidth: isSelected ? 2 : 1)

            label
                .padding(.horizontal, edgeWidth + 2)

            HStack(spacing: 0) {
                edgeHandle { delta, origin in onResize(origin.start + delta, origin.end) }
                Spacer(minLength: 0)
                edgeHandle { delta, origin in onResize(origin.start, origin.end + delta) }
            }
        }
        .frame(width: barWidth, height: height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    let origin = dragOrigin ?? range
                    if dragOrigin == nil {
                        dragOrigin = range
                        onSelect()
                    }
                    onMove(origin.start + timeDelta(value.translation.width))
                }
                .onEnded { _ in dragOrigin = nil }
        )
        .simultaneousGesture(TapGesture().onEnded(onSelect))
        .offset(x: start)
        .frame(width: width, height: height, alignment: .leading)
        .help("\(Timecode.format(range.start)) 〜 \(Timecode.format(range.end))")
    }

    private var label: some View {
        HStack(spacing: 4) {
            if let tool = AnnotationTool(drawing: annotation) {
                Image(systemName: tool.symbolName)
                Text(title(for: tool))
            }
        }
        .font(.system(size: 10, weight: .medium))
        .lineLimit(1)
        .foregroundStyle(.primary)
    }

    private func title(for tool: AnnotationTool) -> String {
        if let text = annotation as? TextAnnotation {
            let firstLine = text.text.split(separator: "\n").first.map(String.init) ?? ""
            return "\(tool.title)「\(firstLine)」"
        }
        return tool.title
    }

    private func edgeHandle(_ resize: @escaping (Double, AnnotationTimeRange) -> Void) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .frame(width: edgeWidth)
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let origin = dragOrigin ?? range
                        if dragOrigin == nil {
                            dragOrigin = range
                            onSelect()
                        }
                        resize(timeDelta(value.translation.width), origin)
                    }
                    .onEnded { _ in dragOrigin = nil }
            )
    }
}
