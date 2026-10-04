import Foundation

/// 1日の区切り（4:00）。docs/decisions/0005-day-boundary-4am.md
enum DayBoundary {
    static let hour = 4

    /// `date` を含む1日の始まり（その日の4:00。0:00〜3:59 なら前日の4:00）。
    static func dayStart(containing date: Date, calendar: Calendar) -> Date {
        let shifted = date.addingTimeInterval(-Double(hour) * 3600)
        let midnight = calendar.startOfDay(for: shifted)
        return calendar.date(byAdding: .hour, value: hour, to: midnight) ?? midnight
    }

    /// 日付境界を適用した日付（例: 2026-10-19）。
    static func dayKey(containing date: Date, calendar: Calendar) -> String {
        let start = dayStart(containing: date, calendar: calendar)
        let parts = calendar.dateComponents([.year, .month, .day], from: start)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// 7日前（先週の同じ曜日）の1日の始まり。暦で数える（夏時間でもずれない）。
    static func sameDayLastWeek(_ dayStart: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: -7, to: dayStart) ?? dayStart.addingTimeInterval(-7 * 86400)
    }
}

extension Calendar {
    /// アプリで使う暦（グレゴリオ暦）。タイムゾーンは呼ぶたびに渡す（旅行などで変わるため）。
    static func app(timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}
