import Foundation

/// 注釈 1 つを表示する時間（秒）。start 以上 end 未満のあいだ表示する。
struct AnnotationTimeRange: Codable, Equatable {
    var start: Double
    var end: Double

    func contains(_ time: Double) -> Bool {
        time >= start && time < end
    }

    var duration: Double { end - start }
}

/// 動画 1 本分の編集内容。履歴の動画と対になる JSON サイドカーに保存する。
///
/// 注釈は静止画と同じ `AnnotationSnapshot` で持ち、表示する時間を ID ごとに添える。
/// 動画そのものには焼き込まないので、あとから開き直しても引き続き編集できる。
struct VideoDocument: Codable {

    struct TimedAnnotation: Codable {
        var annotation: AnnotationSnapshot
        var range: AnnotationTimeRange
    }

    var annotations: [TimedAnnotation]
    /// 書き出す範囲（トリム）。
    var trimStart: Double
    var trimEnd: Double
    var counterStartNumber: Int
}

extension AnnotationSnapshot {
    /// 注釈の ID。表示時間との対応付けに使う。
    var id: UUID {
        switch self {
        case .arrow(let id, _, _, _, _),
             .rectangle(let id, _, _, _, _),
             .ellipse(let id, _, _, _, _):
            return id
        case .line(let id, _, _, _),
             .highlight(let id, _, _, _),
             .pixelate(let id, _, _, _),
             .spotlight(let id, _, _, _):
            return id
        case .freehand(let id, _, _),
             .counter(let id, _, _):
            return id
        case .text(let id, _, _, _, _):
            return id
        }
    }
}
