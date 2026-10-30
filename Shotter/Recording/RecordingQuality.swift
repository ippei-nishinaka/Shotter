import CoreGraphics
import Foundation

/// 収録の画質プリセット。
///
/// 「長時間」は 8 時間収録しても 8GB 程度に収まるよう、映像と音声を合わせて
/// 約 2.1 Mbps に抑えている（8GB ÷ 8 時間 ≒ 2.2 Mbps が上限）。
enum RecordingQuality: String, CaseIterable, Identifiable {
    case high
    case standard
    case longDuration

    static let `default` = RecordingQuality.standard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .high:         return "高画質"
        case .standard:     return "標準"
        case .longDuration: return "長時間"
        }
    }

    var detail: String {
        switch self {
        case .high:         return "Retina の解像度そのまま（長辺 4096 まで）・60fps"
        case .standard:     return "ポイント解像度（長辺 2560 まで）・30fps"
        case .longDuration: return "ポイント解像度（長辺 1920 まで）・30fps"
        }
    }

    var framesPerSecond: Int {
        switch self {
        case .high:                   return 60
        case .standard, .longDuration: return 30
        }
    }

    /// 映像の平均ビットレート（bps）。
    var videoBitRate: Int {
        switch self {
        case .high:         return 12_000_000
        case .standard:     return 5_000_000
        case .longDuration: return 1_900_000
        }
    }

    /// システム音声（ステレオ）の AAC ビットレート。
    var systemAudioBitRate: Int {
        self == .longDuration ? 96_000 : 128_000
    }

    /// マイク（モノラル）の AAC ビットレート。
    var microphoneBitRate: Int {
        self == .longDuration ? 64_000 : 96_000
    }

    /// 書き出す映像の長辺の上限（ピクセル）。
    private var maxLongSide: CGFloat {
        switch self {
        case .high:         return 4096
        case .standard:     return 2560
        case .longDuration: return 1920
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
    func estimatedBytesPerHour(systemAudio: Bool, microphone: Bool) -> Double {
        var bitRate = videoBitRate
        if systemAudio { bitRate += systemAudioBitRate }
        if microphone { bitRate += microphoneBitRate }
        return Double(bitRate) * 3600 / 8
    }

    /// 「1 時間あたり 約 0.9GB」のような説明。どの画質でも同じ書き方にする。
    func sizeEstimateDescription(systemAudio: Bool, microphone: Bool) -> String {
        let perHour = estimatedBytesPerHour(systemAudio: systemAudio, microphone: microphone)
        return "1 時間あたり 約 \(Self.gigabytes(perHour))"
    }

    private static func gigabytes(_ bytes: Double) -> String {
        String(format: "%.1fGB", bytes / 1_000_000_000)
    }

    private static func even(_ value: CGFloat) -> CGFloat {
        max(2, (value / 2).rounded(.down) * 2)
    }
}
