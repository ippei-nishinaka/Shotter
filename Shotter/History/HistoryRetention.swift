import Foundation

/// 履歴をどれだけ保持するか。
enum HistoryRetention: Int, CaseIterable, Identifiable {
    /// 履歴を残さない。
    case disabled = 0
    case threeDays = 3
    case oneWeek = 7
    case twoWeeks = 14
    case oneMonth = 30
    /// 自動削除しない。
    case forever = -1

    static let `default` = HistoryRetention.twoWeeks

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .disabled:  return "保存しない"
        case .threeDays: return "3 日"
        case .oneWeek:   return "1 週間"
        case .twoWeeks:  return "2 週間"
        case .oneMonth:  return "1 か月"
        case .forever:   return "自動削除しない"
        }
    }

    var keepsHistory: Bool { self != .disabled }

    /// この日時より古いファイルは削除する。自動削除しない場合は nil。
    func expirationDate(from now: Date = Date()) -> Date? {
        guard rawValue > 0 else { return nil }
        return now.addingTimeInterval(-Double(rawValue) * 24 * 60 * 60)
    }
}
