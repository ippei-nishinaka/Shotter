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

    /// 直前に描いた注釈。選択していないときは、色やオプションの変更をこれに反映する。
    @Published private(set) var lastAddedID: UUID?

    /// ツールバーから選択中の注釈へスタイルを反映させる際の再入防止。
    private var isSyncingStyle = false

    /// モザイクツールの種類（モザイク／ぼかし）。
    @Published var pixelateMode: PixelateAnnotation.Mode = .pixelate

    // MARK: - ツールごとのオプション

    @Published var arrowHeadStyle: ArrowHeadStyle = .filled {
        didSet { applyOptionsToSelection() }
    }

    @Published var lineDashStyle: StrokeDashStyle = .solid {
        didSet { applyOptionsToSelection() }
    }

    /// 四角（枠）の角を丸めるか。
    @Published var roundsOutline = false { didSet { applyOptionsToSelection() } }
    /// 四角（塗り）の角を丸めるか。
    @Published var roundsBlock = false { didSet { applyOptionsToSelection() } }
    /// ハイライトの角を丸めるか。
    @Published var roundsHighlight = false { didSet { applyOptionsToSelection() } }
    /// 強調で明るく残す部分の角を丸めるか。
    @Published var roundsFocus = false { didSet { applyOptionsToSelection() } }

    /// モザイク／ぼかしの強さ。
    @Published var pixelateIntensity: CGFloat = 1 {
        didSet { applyOptionsToSelection() }
    }

    @Published var textTraits = TextTraits() {
        didSet { applyOptionsToSelection() }
    }

    /// 影の強さ（0.3〜2.0 くらいを想定）。
    @Published var shadowStrength: CGFloat = 1 {
        didSet { didChange() }
    }

    /// 画像の角を丸めるときの半径（ポイント）。
    @Published var cornerRoundness: CGFloat = ImageMask.roundedCornerRadius {
        didSet {
            guard cornerRoundness != oldValue else { return }
            roundedImageCache = nil
            didChange()
        }
    }

    /// 図形の角を丸めるときの半径（画像ピクセル）。
    private var shapeCornerRadius: CGFloat { 8 * pixelScale }

    @Published private(set) var annotations: [Annotation] = []
    @Published private(set) var undoStack: [[Annotation]] = []
    @Published private(set) var redoStack: [[Annotation]] = []

    /// 画像の周りに影を付けるか。注釈の座標系には影響しない（描画時だけ余白を足す）。
    ///
    /// 初期値は設定の「最初から影を付ける」に従う。
    /// エディタでの切り替えはこの 1 枚だけに効き、設定そのものは変えない。
    @Published var hasShadow: Bool = Preferences.addsShadowByDefault {
        didSet {
            guard hasShadow != oldValue else { return }
            didChange()
        }
    }

    /// 画像の角を丸めるか。
    /// ウィンドウキャプチャは撮影時点で実際の形に切り抜かれているので、
    /// 主に範囲キャプチャで使うオプション。
    @Published var hasRoundedCorners: Bool = Preferences.roundsCornersByDefault {
        didSet {
            guard hasRoundedCorners != oldValue else { return }
            roundedImageCache = nil
            didChange()
        }
    }

    private var roundedImageCache: CGImage?

    /// 実際に描画・書き出しに使う画像。角丸オプションが入っていれば丸めたもの。
    ///
    /// 影は「描いた図形の形」から作られるため、先に丸めた画像を用意しておく必要がある
    /// （clip してから影付きで描くと、影自体も clip されて消えてしまう）。
    var renderImage: CGImage {
        guard hasRoundedCorners else { return sourceImage }
        if let roundedImageCache { return roundedImageCache }

        let image = ImageMask.roundedCorners(
            sourceImage,
            radius: cornerRoundness * pixelScale
        ) ?? sourceImage
        roundedImageCache = image
        return image
    }

    /// OCR の実行中フラグと結果。結果が入るとシートが開く。
    @Published var isRecognizingText = false
    @Published var recognizedTextResult: RecognizedTextResult?

    /// 注釈の内容が変わるたびに増える。キャンバスの再描画トリガーに使う。
    @Published private(set) var revision: Int = 0

    var selectedAnnotation: Annotation? {
        annotations.first { $0.id == selectedID }
    }

    /// 色やオプションの変更を反映する相手。
    /// 選択中のものがあればそれ、無ければ直前に描いたもの。
    private var styleTarget: Annotation? {
        if let selectedAnnotation { return selectedAnnotation }
        guard let lastAddedID else { return nil }
        return annotations.first { $0.id == lastAddedID }
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
        hasShadow ? ShadowStyle.padding * pixelScale * max(shadowStrength, 1) : 0
    }

    /// 書き出される画像全体のサイズ（影の余白を含む）。
    var outputSize: CGSize {
        CGSize(
            width: imageSize.width + shadowPadding * 2,
            height: imageSize.height + shadowPadding * 2
        )
    }

    var currentStyle: AnnotationStyle {
        var style = AnnotationStyle(color: color, lineWidth: lineWidth, fontSize: fontSize)
        style.arrowHead = arrowHeadStyle
        style.dash = lineDashStyle
        style.text = textTraits
        style.pixelateIntensity = pixelateIntensity
        style.cornerRadius = roundsCorners(for: tool) ? shapeCornerRadius : 0
        return style
    }

    /// そのツールで「角を丸める」が有効か。
    func roundsCorners(for tool: AnnotationTool) -> Bool {
        switch tool {
        case .rectangle:       return roundsOutline
        case .filledRectangle: return roundsBlock
        case .highlight:       return roundsHighlight
        case .spotlight:       return roundsFocus
        default:               return false
        }
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
        lastAddedID = annotation.id
        didChange()
    }

    func remove(_ annotation: Annotation) {
        guard let index = annotations.firstIndex(where: { $0 === annotation }) else { return }
        pushUndoSnapshot()
        annotations.remove(at: index)
        if selectedID == annotation.id { selectedID = nil }
        if lastAddedID == annotation.id { lastAddedID = nil }
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
        arrowHeadStyle = annotation.style.arrowHead
        lineDashStyle = annotation.style.dash
        textTraits = annotation.style.text
        pixelateIntensity = annotation.style.pixelateIntensity
        isSyncingStyle = false

        didChange()
    }

    private func applyStyleToSelection(recordUndo: Bool) {
        guard !isSyncingStyle, let target = styleTarget else { return }
        if recordUndo { pushUndoSnapshot() }

        target.style.color = color
        target.style.lineWidth = lineWidth
        target.style.fontSize = fontSize
        didChange()
    }

    /// ツールごとのオプションを選択中の注釈へ反映する。
    /// 角丸だけは注釈の種類ごとに設定が分かれているので、実際の型を見て決める。
    private func applyOptionsToSelection() {
        guard !isSyncingStyle else { return }
        guard let target = styleTarget else {
            didChange()
            return
        }

        target.style.arrowHead = arrowHeadStyle
        target.style.dash = lineDashStyle
        target.style.text = textTraits
        target.style.pixelateIntensity = pixelateIntensity
        target.style.cornerRadius = roundsCorners(forAnnotation: target) ? shapeCornerRadius : 0
        didChange()
    }

    private func roundsCorners(forAnnotation annotation: Annotation) -> Bool {
        switch annotation {
        case let rectangle as RectangleAnnotation:
            return rectangle.isFilled ? roundsBlock : roundsOutline
        case is HighlightAnnotation:
            return roundsHighlight
        case is SpotlightAnnotation:
            return roundsFocus
        default:
            return false
        }
    }

    func removeAll() {
        guard !annotations.isEmpty else { return }
        pushUndoSnapshot()
        annotations.removeAll()
        selectedID = nil
        lastAddedID = nil
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
        if let selectedID, !annotations.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
        if let lastAddedID, !annotations.contains(where: { $0.id == lastAddedID }) {
            self.lastAddedID = nil
        }
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
