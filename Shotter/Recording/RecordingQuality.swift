import CoreGraphics
import Foundation

/// 収録の画質プリセット。
///
/// 「低画質」は 8 時間収録しても 8GB 程度に収まるよう、映像と音声を合わせて
/// 約 2.1 Mbps に抑えている（8GB ÷ 8 時間 ≒ 2.2 Mbps が上限）。
enum RecordingQuality: String, CaseIterable, Identifiable {
    case high
    case standard
    /// 以前は「長時間」という名前だった。保存済みの設定を読めるよう rawValue はそのままにする。
    case low = "longDuration"

    static let `default` = RecordingQuality.standard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .high:         return "高画質"
        case .standard:     return "標準"
        case .low:          return "低画質"
        }
    }

    var detail: String {
        switch self {
        case .high:         return "Retina の解像度そのまま（長辺 4096 まで）・60fps"
        case .standard:     return "ポイント解像度（長辺 2560 まで）・30fps"
        case .low:          return "ポイント解像度（長辺 1920 まで）・30fps・8 時間でも 8GB 程度"
        }
    }

    var framesPerSecond: Int {
        switch self {
        case .high:            return 60
        case .standard, .low:  return 30
        }
    }

    /// 映像の平均ビットレートの上限（bps）。大きなウィンドウはここで頭打ちにする。
    var maxVideoBitRate: Int {
        switch self {
        case .high:         return 12_000_000
        case .standard:     return 5_000_000
        case .low:          return 1_900_000
        }
    }

    /// 1 ピクセル・1 フレームあたりに割り当てるビット数。
    /// 上限に届く大きさ（高画質は Retina の 3024×1964 前後、標準は 2560×1440、低画質は 1920×1080）
    /// で、ちょうど従来の固定ビットレートになるように決めている。
    private var bitsPerPixel: Double {
        switch self {
        case .high:         return 0.034
        case .standard:     return 0.045
        case .low:          return 0.031
        }
    }

    /// 小さなウィンドウでも文字が潰れないよう、これより下げない（bps）。
    private static let minimumVideoBitRate = 500_000

    /// 書き出す映像のピクセルサイズに応じた平均ビットレート（bps）。
    /// 小さなウィンドウほど少なくし、無駄にファイルを大きくしない。
    func videoBitRate(forPixelSize pixelSize: CGSize) -> Int {
        let pixels = Double(pixelSize.width * pixelSize.height)
        let proportional = Int(pixels * Double(framesPerSecond) * bitsPerPixel)
        return min(max(proportional, Self.minimumVideoBitRate), maxVideoBitRate)
    }

    /// システム音声（ステレオ）の AAC ビットレート。
    var systemAudioBitRate: Int {
        self == .low ? 96_000 : 128_000
    }

    /// マイク（モノラル）の AAC ビットレート。
    var microphoneBitRate: Int {
        self == .low ? 64_000 : 96_000
    }

    /// 書き出す映像の長辺の上限（ピクセル）。
    private var maxLongSide: CGFloat {
        switch self {
        case .high:         return 4096
        case .standard:     return 2560
        case .low:          return 1920
        }
    }

    /// ウィンドウの大きさ（ポイント）と画面の拡大率から、書き出す映像のピクセルサイズを決める。
    /// エンコーダの都合で幅・高さは偶数にそろえる。
    func outputPixelSize(forPointSize pointSize: CGSize, scale: CGFloat) -> CGSize {
        let pixelScale = self == .high ? scale : 1
        var width = pointSize.width * pixelScale
        var height = pointSize.height * pixelScale

        let longSide = max(width, height)
        if longSide > maxLongSide {
            let ratio = maxLongSide / longSide
            width *= ratio
            height *= ratio
        }

        return CGSize(width: Self.even(width), height: Self.even(height))
    }

    /// 1 時間あたりのおおよそのファイルサイズ（バイト）。
    /// - Parameter pixelSize: 書き出す映像の大きさ。nil なら上限のビットレートで見積もる。
    func estimatedBytesPerHour(pixelSize: CGSize?, systemAudio: Bool, microphone: Bool) -> Double {
        var bitRate = pixelSize.map(videoBitRate(forPixelSize:)) ?? maxVideoBitRate
        if systemAudio { bitRate += systemAudioBitRate }
        if microphone { bitRate += microphoneBitRate }
        return Double(bitRate) * 3600 / 8
    }

    /// 「1 時間あたり 約 0.9GB」のような説明。
    /// - Parameter pixelSize: 収録するウィンドウから決まる映像の大きさ。
    ///   まだウィンドウが決まっていない（設定画面）ときは nil にすると「最大 約 …」と書く。
    func sizeEstimateDescription(pixelSize: CGSize?, systemAudio: Bool, microphone: Bool) -> String {
        let perHour = estimatedBytesPerHour(pixelSize: pixelSize, systemAudio: systemAudio, microphone: microphone)
        let prefix = pixelSize == nil ? "最大 " : ""
        return "1 時間あたり \(prefix)約 \(Self.byteText(perHour))"
    }

    /// 1GB 以上は「2.4GB」、未満は 10MB 単位で「270MB」。
    /// 小さなウィンドウでは大きさによる差が GB の小数 1 桁だと見えないため。
    private static func byteText(_ bytes: Double) -> String {
        if bytes >= 1_000_000_000 {
            return String(format: "%.1fGB", bytes / 1_000_000_000)
        }
        let megabytes = max(10, (bytes / 10_000_000).rounded() * 10)
        return "\(Int(megabytes))MB"
    }

    private static func even(_ value: CGFloat) -> CGFloat {
        max(2, (value / 2).rounded(.down) * 2)
    }
}
