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

            if store.tool == .pixelate {
                pixelateModeGroup
            }

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

    private var toolGroup: some View {
        HStack(spacing: 2) {
            ForEach(AnnotationTool.allCases) { tool in
                ToolButton(
                    tool: tool,
                    isSelected: store.tool == tool,
                    action: { store.tool = tool }
                )
            }
        }
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

    /// テキストツールのときはフォントサイズ、それ以外は線幅を出す。
    @ViewBuilder
    private var lineWidthGroup: some View {
        if store.tool == .text {
            sliderGroup(
                symbol: "textformat.size",
                value: $store.fontSize,
                range: 10...96,
                help: "フォントサイズ",
                detailText: "テキストと連番の大きさを変えます。"
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

    private var pixelateModeGroup: some View {
        Picker("種類", selection: $store.pixelateMode) {
            ForEach(PixelateAnnotation.Mode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 130)
        .instantTooltip(
            title: "隠し方を選ぶ",
            detail: "モザイク（四角い粒）とぼかし（にじませる）を切り替えます。"
        )
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
        }
        .controlSize(.regular)
        .fixedSize()
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

    /// SF Symbol が無い OS でも欠けないように代替名へフォールバックする。
    private static func symbolImage(for tool: AnnotationTool) -> NSImage {
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
