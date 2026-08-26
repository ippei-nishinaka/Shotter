import AppKit
import SwiftUI

/// AppKit のキャンバスを SwiftUI 階層に差し込むためのラッパー。
struct AnnotationCanvasRepresentable: NSViewRepresentable {

    @ObservedObject var store: AnnotationStore

    func makeNSView(context: Context) -> AnnotationCanvasView {
        let view = AnnotationCanvasView()
        view.store = store
        return view
    }

    func updateNSView(_ nsView: AnnotationCanvasView, context: Context) {
        nsView.store = store
        nsView.needsDisplay = true
    }
}

/// エディタウィンドウの中身。上がツールバー、下がキャンバス。
struct EditorView: View {

    @ObservedObject var store: AnnotationStore
    let onCopy: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            EditorToolbarView(store: store, onCopy: onCopy, onSave: onSave)
            Divider()

            let options = ToolOptionsBar(store: store)
            if options.hasContent {
                options
                Divider()
            }

            AnnotationCanvasRepresentable(store: store)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // ツールチップはツールバーの外側（キャンバスの上）に描く。
        .instantTooltipContainer()
        .sheet(item: $store.recognizedTextResult) { result in
            RecognizedTextSheet(result: result) {
                store.recognizedTextResult = nil
            }
        }
    }
}

/// ツール選択・色・線幅・アンドゥ・コピーを並べたツールバー。
struct EditorToolbarView: View {

    @ObservedObject var store: AnnotationStore
    let onCopy: () -> Void
    let onSave: () -> Void

    /// プリセットの色。右端のカラーピッカーで任意の色も選べる。
    private static let presetColors: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen,
        .systemBlue, .systemPurple, .black, .white,
    ]

    var body: some View {
        HStack(spacing: 8) {
            toolGroup
            Divider().frame(height: 20)
            colorGroup
            Divider().frame(height: 20)
            lineWidthGroup

            Spacer(minLength: 12)

            historyGroup
            Divider().frame(height: 20)
            actionGroup
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    // MARK: - グループ

    /// ツールと見た目のオプションを同じ間隔で並べる。
    /// 別々の HStack に分けると、そこだけ間隔が広く見えてしまう。
    private var toolGroup: some View {
        HStack(spacing: 2) {
            ForEach(AnnotationTool.allCases) { tool in
                ToolButton(
                    tool: tool,
                    isSelected: store.tool == tool,
                    action: { store.tool = tool }
                )
            }
            shadowToggle
            cornerToggle
        }
    }

    /// 画像の周りに影を付けるトグル。描画ツールではないので枠を分けている。
    private var shadowToggle: some View {
        Button {
            store.hasShadow.toggle()
        } label: {
            Image(nsImage: ShadowToggleIcon.image)
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
                .frame(width: 26, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(store.hasShadow ? Color.accentColor.opacity(0.9) : .clear)
                )
        }
        .buttonStyle(.plain)
        .instantTooltip(
            title: "影（Shadow）",
            shortcut: "S",
            detail: "画像の周りに余白と影を付けます。ウィンドウを撮ったときに見栄えがします。",
            forceVisible: isTooltipForced("影（Shadow）")
        )
    }

    /// 画像の角を丸めるトグル。
    private var cornerToggle: some View {
        Button {
            store.hasRoundedCorners.toggle()
        } label: {
            Image(nsImage: RoundedCornerToggleIcon.image)
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
                .frame(width: 26, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(store.hasRoundedCorners ? Color.accentColor.opacity(0.9) : .clear)
                )
                .foregroundStyle(store.hasRoundedCorners ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .instantTooltip(
            title: "角を丸める（Round）",
            shortcut: "R",
            detail: "画像の四隅を丸くします。ウィンドウを撮ったときは元から丸いので、範囲キャプチャ向けです。",
            forceVisible: isTooltipForced("角を丸める（Round）")
        )
    }

    private var colorGroup: some View {
        HStack(spacing: 3) {
            ForEach(Array(Self.presetColors.enumerated()), id: \.offset) { _, color in
                ColorSwatch(
                    color: color,
                    isSelected: store.color.isVisuallyEqual(to: color),
                    action: { store.color = color }
                )
                .instantTooltip(
                    title: "色を変える",
                    detail: "選択中の注釈があれば、その色も変わります。"
                )
            }
            ColorPicker("色", selection: colorBinding, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 46)
                .instantTooltip(
                    title: "任意の色を選ぶ",
                    detail: "カラーピッカーから好きな色を指定できます。"
                )
        }
    }

    /// テキストのサイズはオプション行にあるので、ここでは出さない。
    @ViewBuilder
    private var lineWidthGroup: some View {
        if store.tool == .text {
            EmptyView()
        } else if store.tool == .counter {
            sliderGroup(
                symbol: "textformat.size",
                value: $store.fontSize,
                range: 10...96,
                help: "丸数字の大きさ",
                detailText: "ナンバリングの丸数字の大きさを変えます。"
            )
        } else {
            sliderGroup(
                symbol: "lineweight",
                value: $store.lineWidth,
                range: 1...24,
                help: "線の太さ",
                detailText: "矢印・枠線・フリーハンドの太さを変えます。"
            )
        }
    }

    private func sliderGroup(
        symbol: String,
        value: Binding<CGFloat>,
        range: ClosedRange<CGFloat>,
        help: String,
        detailText: String
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
            Slider(value: value, in: range)
                .frame(width: 90)
            Text("\(Int(value.wrappedValue))")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .trailing)
        }
        .instantTooltip(title: help, detail: detailText, forceVisible: isTooltipForced(help))
    }

    private var historyGroup: some View {
        HStack(spacing: 2) {
            IconButton(
                systemName: "arrow.uturn.backward",
                title: "元に戻す",
                shortcut: "⌃Z",
                detail: "直前の操作を取り消します。⌘Z でも同じです。",
                isEnabled: store.canUndo
            ) {
                store.undo()
            }

            IconButton(
                systemName: "arrow.uturn.forward",
                title: "やり直す",
                shortcut: "⌃Y",
                detail: "取り消した操作をやり直します。⌃⇧Z / ⇧⌘Z でも同じです。",
                isEnabled: store.canRedo
            ) {
                store.redo()
            }

            IconButton(
                systemName: "delete.left",
                title: "選択中の注釈を削除",
                shortcut: "Delete",
                detail: "選択ツール（E）で選んだ注釈を 1 つ削除します。",
                isEnabled: store.selectedAnnotation != nil
            ) {
                store.deleteSelection()
            }

            IconButton(
                systemName: "trash",
                title: "すべての注釈を削除",
                detail: "この画像に描いた注釈をまとめて消します。⌃Z で元に戻せます。",
                isEnabled: !store.isEmpty
            ) {
                store.removeAll()
            }
        }
    }

    private var actionGroup: some View {
        HStack(spacing: 8) {
            Button {
                Task { await store.recognizeText() }
            } label: {
                if store.isRecognizingText {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16)
                } else {
                    Image(systemName: "text.viewfinder")
                }
            }
            .instantTooltip(
                title: "文字を読み取る",
                detail: "画像の中の文字を認識してテキストにします（日本語・英語）。",
                forceVisible: isTooltipForced("文字を読み取る")
            )

            Button(action: onCopy) {
                Label("コピー", systemImage: "doc.on.doc")
            }
            .instantTooltip(
                title: "クリップボードにコピー",
                shortcut: "⌘C",
                detail: "注釈を焼き込んだ画像をコピーします。"
            )

            Button(action: onSave) {
                Label("保存", systemImage: "square.and.arrow.down")
            }
            .instantTooltip(
                title: "ファイルに保存",
                shortcut: "⌘S",
                detail: "PNG または JPEG を選んで保存します。"
            )

            menuButton
        }
        .controlSize(.regular)
        .fixedSize()
    }

    /// 履歴・設定・About をまとめたメニュー。
    private var menuButton: some View {
        Menu {
            Button("履歴…") { HistoryWindowController.show() }
            Button("設定…") { SettingsWindowController.show() }
            Divider()
            Button("Shotter について") { AboutWindowController.show() }
        } label: {
            Image(systemName: "line.3.horizontal")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .instantTooltip(
            title: "メニュー",
            detail: "履歴・設定・アプリ情報を開きます。",
            forceVisible: isTooltipForced("メニュー")
        )
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: store.color) },
            set: { store.color = NSColor($0) }
        )
    }
}

// MARK: - 部品

private struct ToolButton: View {

    let tool: AnnotationTool
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(nsImage: Self.symbolImage(for: tool))
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
                .frame(width: 26, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isSelected ? Color.accentColor.opacity(0.9) : .clear)
                )
                .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .instantTooltip(
            title: "\(tool.title)（\(tool.englishName)）",
            shortcut: String(tool.shortcutKey).uppercased(),
            detail: tool.hint,
            forceVisible: isTooltipForced(tool.rawValue)
        )
    }

    /// SF Symbol では意味が伝わらないツールだけ自前で描き、それ以外は SF Symbol を使う。
    private static func symbolImage(for tool: AnnotationTool) -> NSImage {
        if let custom = ToolIcon.custom(for: tool) { return custom }

        if let image = NSImage(systemSymbolName: tool.symbolName, accessibilityDescription: tool.title) {
            return image
        }
        return NSImage(systemSymbolName: tool.fallbackSymbolName, accessibilityDescription: tool.title)
            ?? NSImage(size: NSSize(width: 14, height: 14))
    }
}

private struct ColorSwatch: View {

    let color: NSColor
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(nsColor: color))
                .frame(width: 14, height: 14)
                .overlay(
                    Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5)
                )
                .overlay(
                    Circle()
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .padding(-3)
                        .opacity(isSelected ? 1 : 0)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct IconButton: View {

    let systemName: String
    let title: String
    var shortcut: String?
    var detail: String?
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        // .disabled() を使うとホバーも切れてツールチップが出なくなるため、
        // 見た目を薄くして動作だけ止める。
        Button(action: { if isEnabled { action() } }) {
            Image(systemName: systemName)
                .frame(width: 26, height: 24)
                .opacity(isEnabled ? 1 : 0.3)
        }
        .buttonStyle(.plain)
        .instantTooltip(
            title: title,
            shortcut: shortcut,
            detail: detail,
            forceVisible: isTooltipForced(title)
        )
    }
}

/// 動作確認用。`--debug-tooltip <キー>` を付けて起動したときだけ true。
private func isTooltipForced(_ key: String) -> Bool {
    #if DEBUG
    return DebugSupport.isTooltipForced(key)
    #else
    return false
    #endif
}

extension NSColor {

    /// プリセット選択の見た目上の一致判定。カラースペースを揃えてから比較する。
    func isVisuallyEqual(to other: NSColor) -> Bool {
        guard let a = usingColorSpace(.sRGB), let b = other.usingColorSpace(.sRGB) else {
            return self == other
        }
        let tolerance: CGFloat = 0.01
        return abs(a.redComponent - b.redComponent) < tolerance
            && abs(a.greenComponent - b.greenComponent) < tolerance
            && abs(a.blueComponent - b.blueComponent) < tolerance
    }
}

/// OCR の結果を出すシート。そのまま編集してからコピーできる。
struct RecognizedTextSheet: View {

    let result: RecognizedTextResult
    let onClose: () -> Void

    @State private var text: String = ""
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "text.viewfinder")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 1) {
                    Text("読み取った文字")
                        .font(.headline)
                    Text(result.isEmpty
                         ? "文字を検出できませんでした"
                         : "\(result.lineCount) 行を認識しました。編集してからコピーできます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            TextEditor(text: $text)
                .font(.system(size: 13, design: .monospaced))
                .frame(width: 520, height: 240)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                )

            HStack {
                if didCopy {
                    Label("コピーしました", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                Spacer()
                Button("閉じる", action: onClose)
                Button("コピー") {
                    Pasteboard.copy(text: text)
                    didCopy = true
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.isEmpty)
            }
        }
        .padding(18)
        .onAppear { text = result.text }
    }
}


/// 影トグル用のアイコン。
///
/// SF Symbol の "shadow" は何を表しているのか分かりにくかったので、
/// 実際に影の付いた角丸四角形を描いて「影」だと一目で分かるようにしている。
/// ライト／ダークどちらのツールバーでも、選択時の青い背景の上でも読めるよう、
/// 白いカード＋グレーの輪郭＋濃いめの影という構成にしている。
private enum ShadowToggleIcon {

    static let image: NSImage = {
        let size = NSSize(width: 20, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return true }

            let card = CGRect(x: 2.5, y: 6.5, width: 11, height: 8.5)
            let path = CGPath(roundedRect: card, cornerWidth: 2, cornerHeight: 2, transform: nil)

            context.saveGState()
            context.setShadow(
                offset: CGSize(width: 2.2, height: -2.6),
                blur: 3.4,
                color: CGColor(gray: 0, alpha: 0.7)
            )
            context.addPath(path)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fillPath()
            context.restoreGState()

            context.addPath(path)
            context.setStrokeColor(CGColor(gray: 0.5, alpha: 1))
            context.setLineWidth(0.8)
            context.strokePath()

            return true
        }
        image.isTemplate = false
        return image
    }()
}


/// 角丸トグル用のアイコン。
///
/// 角丸の四角をそのまま描くと「四角（枠）」ツールと紛らわしいので、
/// デザインツールでよく使われる「角の弧だけを見せる」形にしている。
/// テンプレート画像なので、選択時は白、通常時はラベル色に自動で色が付く。
private enum RoundedCornerToggleIcon {

    static let image: NSImage = {
        let size = NSSize(width: 20, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return true }

            // 左上の角だけを、丸みを強調して描く。
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 4, y: 3))
            path.addLine(to: CGPoint(x: 4, y: 9))
            path.addArc(
                tangent1End: CGPoint(x: 4, y: 15),
                tangent2End: CGPoint(x: 10, y: 15),
                radius: 6
            )
            path.addLine(to: CGPoint(x: 16, y: 15))

            context.addPath(path)
            context.setStrokeColor(CGColor(gray: 0, alpha: 1))
            context.setLineWidth(1.8)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.strokePath()

            // 角が「丸められている」ことが伝わるよう、元の直角を点線で薄く添える。
            let ghost = CGMutablePath()
            ghost.move(to: CGPoint(x: 4, y: 9))
            ghost.addLine(to: CGPoint(x: 4, y: 15))
            ghost.addLine(to: CGPoint(x: 10, y: 15))

            context.addPath(ghost)
            context.setStrokeColor(CGColor(gray: 0, alpha: 0.35))
            context.setLineWidth(1)
            context.setLineDash(phase: 0, lengths: [1.6, 1.6])
            context.strokePath()

            return true
        }
        image.isTemplate = true
        return image
    }()
}


/// SF Symbol では何のツールか伝わりにくいものを自前で描く。
///
/// テンプレート画像なので色は自動で付く。ただし塗りの濃さ（アルファ）は
/// そのまま残るため、モザイクの粒や強調の暗転を濃淡で表現できる。
private enum ToolIcon {

    static func custom(for tool: AnnotationTool) -> NSImage? {
        switch tool {
        case .pixelate:  return mosaic
        case .spotlight: return focus
        default:         return nil
        }
    }

    /// モザイク: 濃さの違う粗いブロックを敷き詰めて「粒状に潰す」ことを示す。
    private static let mosaic: NSImage = {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return true }

            let origin = CGPoint(x: 3, y: 3)
            let cell = CGSize(width: 3.5, height: 4)
            let alphas: [[CGFloat]] = [
                [1.00, 0.30, 0.70, 0.25],
                [0.35, 0.90, 0.20, 0.65],
                [0.75, 0.25, 0.55, 1.00],
            ]

            for (row, values) in alphas.enumerated() {
                for (column, alpha) in values.enumerated() {
                    context.setFillColor(CGColor(gray: 0, alpha: alpha))
                    context.fill(CGRect(
                        x: origin.x + CGFloat(column) * cell.width,
                        y: origin.y + CGFloat(row) * cell.height,
                        width: cell.width,
                        height: cell.height
                    ))
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }()

    /// 強調: 周囲を暗くし、真ん中だけ明るく抜けている状態を示す。
    private static let focus: NSImage = {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return true }

            let outer = CGRect(x: 2.5, y: 2.5, width: 15, height: 13)
            let inner = CGRect(x: 6.5, y: 6, width: 7, height: 6)

            // even-odd で内側を抜き、周囲だけを薄く塗る＝暗転の表現。
            let path = CGMutablePath()
            path.addRect(outer)
            path.addRoundedRect(in: inner, cornerWidth: 1.5, cornerHeight: 1.5)

            context.addPath(path)
            context.setFillColor(CGColor(gray: 0, alpha: 0.45))
            context.fillPath(using: .evenOdd)

            // 明るく残る部分の輪郭をはっきりさせる。
            context.addPath(
                CGPath(roundedRect: inner, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)
            )
            context.setStrokeColor(CGColor(gray: 0, alpha: 1))
            context.setLineWidth(1.3)
            context.strokePath()

            return true
        }
        image.isTemplate = true
        return image
    }()
}
