import AppKit
import Combine

/// 編集中の 1 枚分の状態（画像・注釈・ツール設定・アンドゥ履歴）を持つ。
@MainActor
final class AnnotationStore: ObservableObject {

    /// 撮影された元画像（ピクセル）。
    let sourceImage: CGImage

    /// 画像のピクセルサイズ。注釈の座標系はこのサイズを基準にする。
    let imageSize: CGSize

    /// 画像の論理サイズ（ポイント）。ウィンドウの初期サイズ算出に使う。
    let pointSize: CGSize

    @Published var tool: AnnotationTool = .arrow {
        didSet {
            // 描画ツールに切り替えたら選択は解除する。
            if tool != .select { selectedID = nil }
        }
    }

    @Published var color: NSColor = .systemRed {
        didSet { applyStyleToSelection(recordUndo: true) }
    }

    @Published var lineWidth: CGFloat = 4 {
        didSet { applyStyleToSelection(recordUndo: false) }
    }

    @Published var fontSize: CGFloat = 24 {
        didSet { applyStyleToSelection(recordUndo: false) }
    }

    /// 選択ツールで選ばれている注釈。
    @Published var selectedID: UUID?

    /// ツールバーから選択中の注釈へスタイルを反映させる際の再入防止。
    private var isSyncingStyle = false

    /// モザイクツールの種類（モザイク／ぼかし）。
    @Published var pixelateMode: PixelateAnnotation.Mode = .pixelate

    @Published private(set) var annotations: [Annotation] = []
    @Published private(set) var undoStack: [[Annotation]] = []
    @Published private(set) var redoStack: [[Annotation]] = []

    /// 画像の周りに影を付けるか。注釈の座標系には影響しない（描画時だけ余白を足す）。
    @Published var hasShadow: Bool = Preferences.addsShadow {
        didSet {
            guard hasShadow != oldValue else { return }
            Preferences.addsShadow = hasShadow
            didChange()
        }
    }

    /// OCR の実行中フラグと結果。結果が入るとシートが開く。
    @Published var isRecognizingText = false
    @Published var recognizedTextResult: RecognizedTextResult?

    /// 注釈の内容が変わるたびに増える。キャンバスの再描画トリガーに使う。
    @Published private(set) var revision: Int = 0

    var selectedAnnotation: Annotation? {
        annotations.first { $0.id == selectedID }
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var isEmpty: Bool { annotations.isEmpty }

    /// 画像 1 ポイントあたりのピクセル数。影のサイズを実寸に換算するのに使う。
    var pixelScale: CGFloat {
        guard pointSize.width > 0 else { return 2 }
        return imageSize.width / pointSize.width
    }

    /// 影を付けたときに画像の周りへ足す余白（ピクセル）。
    var shadowPadding: CGFloat {
        hasShadow ? ShadowStyle.padding * pixelScale : 0
    }

    /// 書き出される画像全体のサイズ（影の余白を含む）。
    var outputSize: CGSize {
        CGSize(
            width: imageSize.width + shadowPadding * 2,
            height: imageSize.height + shadowPadding * 2
        )
    }

    var currentStyle: AnnotationStyle {
        AnnotationStyle(color: color, lineWidth: lineWidth, fontSize: fontSize)
    }

    var renderEnvironment: AnnotationRenderEnvironment {
        AnnotationRenderEnvironment(sourceImage: sourceImage, imageSize: imageSize)
    }

    init(image: CGImage, pointSize: CGSize) {
        self.sourceImage = image
        self.imageSize = CGSize(width: image.width, height: image.height)
        self.pointSize = pointSize
    }

    // MARK: - 編集

    func add(_ annotation: Annotation) {
        pushUndoSnapshot()
        annotations.append(annotation)
        didChange()
    }

    func remove(_ annotation: Annotation) {
        guard let index = annotations.firstIndex(where: { $0 === annotation }) else { return }
        pushUndoSnapshot()
        annotations.remove(at: index)
        if selectedID == annotation.id { selectedID = nil }
        didChange()
    }

    func deleteSelection() {
        guard let selectedAnnotation else { return }
        remove(selectedAnnotation)
    }

    /// 選択を切り替える。ツールバーの色・太さは選択した注釈の値に追従させる。
    func select(_ annotation: Annotation?) {
        selectedID = annotation?.id

        guard let annotation else {
            didChange()
            return
        }

        isSyncingStyle = true
        color = annotation.style.color
        lineWidth = annotation.style.lineWidth
        fontSize = annotation.style.fontSize
        isSyncingStyle = false

        didChange()
    }

    private func applyStyleToSelection(recordUndo: Bool) {
        guard !isSyncingStyle, let selectedAnnotation else { return }
        if recordUndo { pushUndoSnapshot() }

        selectedAnnotation.style.color = color
        selectedAnnotation.style.lineWidth = lineWidth
        selectedAnnotation.style.fontSize = fontSize
        didChange()
    }

    func removeAll() {
        guard !annotations.isEmpty else { return }
        pushUndoSnapshot()
        annotations.removeAll()
        selectedID = nil
        didChange()
    }

    /// ドラッグ中など、確定前の変更を通知したいときに呼ぶ（履歴には積まない）。
    func didChange() {
        revision &+= 1
    }

    /// 既存の注釈を書き換える前に呼び、履歴に現在の状態を積む。
    func beginMutation() {
        pushUndoSnapshot()
    }

    // MARK: - アンドゥ / リドゥ

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(annotations.map { $0.copy() })
        annotations = previous
        dropSelectionIfMissing()
        didChange()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations.map { $0.copy() })
        annotations = next
        dropSelectionIfMissing()
        didChange()
    }

    // MARK: - 文字認識

    /// 注釈を含まない元画像に対して OCR をかける（注釈が誤認識されないように）。
    func recognizeText() async {
        guard !isRecognizingText else { return }
        isRecognizingText = true
        defer { isRecognizingText = false }

        do {
            let result = try await TextRecognizer.recognize(in: sourceImage)
            recognizedTextResult = RecognizedTextResult(
                text: result.isEmpty ? "" : result.joined,
                lineCount: result.lines.count
            )
        } catch {
            recognizedTextResult = RecognizedTextResult(text: "", lineCount: 0)
        }
    }

    private func dropSelectionIfMissing() {
        guard let selectedID, !annotations.contains(where: { $0.id == selectedID }) else { return }
        self.selectedID = nil
    }

    private func pushUndoSnapshot() {
        undoStack.append(annotations.map { $0.copy() })
        redoStack.removeAll()
    }
}

/// OCR の結果。シート表示のため Identifiable にしている。
struct RecognizedTextResult: Identifiable {
    let id = UUID()
    let text: String
    let lineCount: Int

    var isEmpty: Bool { text.isEmpty }
}
