import AppKit

/// 注釈 1 つ分の見た目の設定。
struct AnnotationStyle {
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 4
    var fontSize: CGFloat = 24

    /// 矢印の形。
    var arrowHead: ArrowHeadStyle = .filled

    /// 線の種類。
    var dash: StrokeDashStyle = .solid

    /// 角丸の半径（画像ピクセル）。0 なら直角。四角・ハイライト・強調で使う。
    var cornerRadius: CGFloat = 0

    /// テキストの書体設定。
    var text = TextTraits()

    /// モザイクか、ぼかしか。
    var pixelateMode: PixelateAnnotation.Mode = .pixelate

    /// モザイク／ぼかしの強さの倍率。
    var pixelateIntensity: CGFloat = 1

    /// CGContext へ渡す前にカラースペースを sRGB へ揃える。
    /// カタログ色（systemRed など）をそのまま cgColor 化すると書き出し先で色が変わることがある。
    var resolvedColor: CGColor {
        (color.usingColorSpace(.sRGB) ?? color).cgColor
    }
}

/// キャンバス上に描かれる注釈。
///
/// 座標はすべて「画像ピクセル座標・左上原点」で保持する。
/// 画面表示と書き出しで同じ描画コードを使えるようにするため、
/// 描画は CGContext に対して行う。
protocol Annotation: AnyObject {
    var id: UUID { get }
    var style: AnnotationStyle { get set }

    /// 選択ツールでの移動。
    func translate(by offset: CGVector)

    /// 選択ハンドルやヒットテストに使う外接矩形（画像座標）。
    var boundingBox: CGRect { get }

    /// - Parameter context: 画像ピクセル座標系（左上原点）に変換済みのコンテキスト。
    /// - Parameter environment: 下地の画像など、描画に必要な周辺情報。
    func draw(in context: CGContext, environment: AnnotationRenderEnvironment)

    func hitTest(_ point: CGPoint) -> Bool

    /// アンドゥ用のスナップショットを作るための複製。
    func copy() -> Annotation
}

/// 描画時に注釈から参照できる情報。モザイクやスポットライトが下地を必要とするため用意している。
struct AnnotationRenderEnvironment {
    /// 注釈を載せる元画像（ピクセル）。
    let sourceImage: CGImage
    /// 画像のピクセルサイズ。
    let imageSize: CGSize
    /// 連番に表示する番号。描画直前に並び順から算出する。
    var counterNumbers: [UUID: Int] = [:]
    /// 連番の開始番号。途中の手順から振り始めたいときに変更する。
    var counterStartNumber: Int = 1
}

/// ドラッグで作られる注釈。マウスダウンで生成し、ドラッグ中に終点を更新していく。
protocol DragCreatableAnnotation: Annotation {
    /// - Parameter constrained: Shift キーが押されているか（角度や縦横比を固定する）。
    func updateDrag(to point: CGPoint, constrained: Bool)

    /// クリックしただけなど、小さすぎるものを確定させないための判定。
    var isValidForCommit: Bool { get }
}

/// リサイズ用のつまみ。位置は画像ピクセル座標。
struct AnnotationHandle {

    enum Kind {
        /// 線・矢印の端点。
        case start
        case end
        /// 矢印の曲がり具合をつまむ点。
        case bend
        /// 外接矩形の四隅と辺の中央。
        case topLeft
        case top
        case topRight
        case right
        case bottomRight
        case bottom
        case bottomLeft
        case left
    }

    let kind: Kind
    let position: CGPoint
}

/// つまみを掴んで形を変えられる注釈。
protocol ResizableAnnotation: Annotation {
    var handles: [AnnotationHandle] { get }
    func moveHandle(_ kind: AnnotationHandle.Kind, to point: CGPoint, constrained: Bool)
}
