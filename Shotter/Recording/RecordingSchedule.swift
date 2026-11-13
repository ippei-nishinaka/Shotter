import Foundation

/// 収録の予約。開始・終了の時刻（日付込み）。
struct RecordingSchedule: Equatable {
    /// nil ならすぐに始める。
    var start: Date?
    /// nil なら手で止めるまで続ける。
    var stop: Date?

    static let immediate = RecordingSchedule(start: nil, stop: nil)

    /// 時刻（時・分）だけを見て、基準より後でいちばん近いその時刻にする。
    /// 「14:00」を 15:00 に選んだら翌日の 14:00 になる。
    static func nextOccurrence(of timeOfDay: Date, after reference: Date) -> Date {
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.hour, .minute], from: timeOfDay)
        let candidate = calendar.date(
            bySettingHour: parts.hour ?? 0,
            minute: parts.minute ?? 0,
            second: 0,
            of: reference
        ) ?? reference
        return candidate > reference ? candidate : calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
    }

    /// 次の 5 分きざみの時刻（予約の初期値）。13:02 なら 13:05。
    static func nextRoundTime(after date: Date = Date(), step: Int = 5) -> Date {
        let calendar = Calendar.current
        let minute = calendar.component(.minute, from: date)
        let rounded = (minute / step + 1) * step
        let base = calendar.date(bySetting: .second, value: 0, of: date) ?? date
        return calendar.date(byAdding: .minute, value: rounded - minute, to: base) ?? date
    }

    /// 「14:00」。日をまたぐ場合は「明日 14:00」。
    static func timeText(_ date: Date, relativeTo reference: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "H:mm"
        let text = formatter.string(from: date)
        return Calendar.current.isDate(date, inSameDayAs: reference) ? text : "明日 \(text)"
    }

    /// 「1 時間 12 分」「3 分」「45 秒」。
    static func durationText(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.up)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return minutes > 0 ? "\(hours) 時間 \(minutes) 分" : "\(hours) 時間" }
        if minutes > 0 { return "\(minutes) 分" }
        return "\(total) 秒"
    }
}
