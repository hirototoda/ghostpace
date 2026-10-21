import Foundation

/// 一日の区切りの履歴の1行（docs/design/data-model.md「DayBoundaryChange」、GHO-17）。
/// 「この日（fromDayKey）から、この時刻（endMinutes）で区切る」
struct DayBoundaryChange: Hashable, Sendable {
    var fromDayKey: String
    /// その日の区切り（その日の終わり）を、日の名前の日の 0:00 からの分で。22:00 → 1320、翌4:00 → 1680
    var endMinutes: Int
    var timeZoneId: String = "Asia/Tokyo"
    var updatedAt: Date = .distantPast
}

/// 区切りで分けた1日（docs/product/glossary.md「その日の区切り」「日の名前」）。
struct BoundaryDay: Hashable, Sendable {
    /// 日の名前（例 2026-10-21）。一日の中にある 12:00 の暦の日
    var key: String
    /// 日の名前の日の 0:00。表示の日付と、ほかの日と「同じ時刻でそろえる」基準（GHO-02）
    var date: Date
    /// 一日の始まり（前の日の区切り）
    var start: Date
    /// その日の区切り（終わり。この時刻からは次の日）
    var end: Date
    /// その日の区切り（日の名前の日の 0:00 からの分）
    var endMinutes: Int
    /// 区切りの履歴より前の日（2026-10-21 の版より前。朝4:00区切りの今までの数え方のまま）
    var isLegacy: Bool

    var interval: DateInterval { DateInterval(start: start, end: end) }
    var duration: TimeInterval { end.timeIntervalSince(start) }

    func contains(_ time: Date) -> Bool { start <= time && time < end }
}

/// 一日の区切り（docs/decisions/0023-day-boundary-evening.md）。区切りの履歴から、日ごとの区切りを決める。
/// 日の範囲は「前の日の区切り〜その日の区切り」。区切りは端末の暦（注入された Calendar）の壁時計の時刻で決める。
/// 履歴が0件、または一番古い行より前の日は、朝4:00区切り（今までの dayKey と同じ）
struct DayBoundary: Sendable {
    /// 朝の計画を出す時刻（朝4:00。区切りの設定とは関係なく決まっている、PLN-01）
    static let morningHour = 4
    /// 区切りの履歴より前の日の区切り（翌4:00）
    static let legacyEndMinutes = 28 * 60
    /// 初期の区切り（22:00）
    static let defaultEndMinutes = 22 * 60
    /// 選べる範囲と刻み（20:00〜翌4:00、30分きざみ）
    static let minEndMinutes = 20 * 60
    static let maxEndMinutes = 28 * 60
    static let stepMinutes = 30
    /// 設定で選べる区切り（17個）
    static let choices = Array(stride(from: minEndMinutes, through: maxEndMinutes, by: stepMinutes))

    /// 範囲の外・30分きざみでない値は、近い30分きざみに丸めて範囲に収める（data-model.md）
    static func normalized(_ minutes: Int) -> Int {
        let step = Double(stepMinutes)
        let rounded = Int((Double(minutes) / step).rounded()) * stepMinutes
        return min(max(rounded, minEndMinutes), maxEndMinutes)
    }

    let calendar: Calendar
    /// fromDayKey の順に並べた行（同じ fromDayKey は更新日時が新しいものだけ）
    let rows: [(key: String, minutes: Int)]

    init(calendar: Calendar, changes: [DayBoundaryChange] = []) {
        self.calendar = calendar
        var newest: [String: DayBoundaryChange] = [:]
        for change in changes where newest[change.fromDayKey].map({ change.updatedAt >= $0.updatedAt }) ?? true {
            newest[change.fromDayKey] = change
        }
        rows = newest.values.sorted { $0.fromDayKey < $1.fromDayKey }.map { ($0.fromDayKey, Self.normalized($0.endMinutes)) }
    }

    // MARK: 日の名前と暦の日

    /// 暦の日（0:00）の日の名前
    func key(of date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// 日の名前の日の 0:00。読めない名前なら nil
    func date(ofKey key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private func shifted(_ day: Date, by days: Int) -> Date {
        calendar.date(byAdding: .day, value: days, to: day) ?? day.addingTimeInterval(Double(days) * 86400)
    }

    /// 暦の日 `day`（0:00）から `minutes` 分の壁時計の時刻（1440 以上は翌日）
    func wallClock(_ day: Date, minutes: Int) -> Date {
        let base = shifted(day, by: Int((Double(minutes) / 1440).rounded(.down)))
        let rest = ((minutes % 1440) + 1440) % 1440
        return calendar.date(bySettingHour: rest / 60, minute: rest % 60, second: 0, of: base)
            ?? base.addingTimeInterval(Double(rest * 60))
    }

    // MARK: 履歴

    /// 区切りの履歴より前の日か（朝4:00区切りの今までの数え方）
    func isLegacy(key: String) -> Bool {
        guard let first = rows.first else { return true }
        return key < first.key
    }

    /// その日の区切り（日の名前の日の 0:00 からの分）
    func endMinutes(key: String) -> Int {
        rows.last { $0.key <= key }?.minutes ?? Self.legacyEndMinutes
    }

    /// 一番新しい行の区切り（設定の画面に出す値）。行がなければ初期値
    var latestEndMinutes: Int { rows.last?.minutes ?? Self.defaultEndMinutes }

    // MARK: 日

    /// 暦の日 `date`（0:00）を名前に持つ日
    func day(onDate date: Date) -> BoundaryDay {
        let date = calendar.startOfDay(for: date)
        let key = key(of: date)
        let previous = shifted(date, by: -1)
        let minutes = endMinutes(key: key)
        return BoundaryDay(key: key, date: date,
                           start: wallClock(previous, minutes: endMinutes(key: self.key(of: previous))),
                           end: wallClock(date, minutes: minutes), endMinutes: minutes, isLegacy: isLegacy(key: key))
    }

    /// 日の名前の日。読めない名前なら nil
    func day(key: String) -> BoundaryDay? {
        date(ofKey: key).map { day(onDate: $0) }
    }

    /// `time` を含む日（区切りより後は次の日）
    func day(containing time: Date) -> BoundaryDay {
        let today = calendar.startOfDay(for: time)
        let candidate = day(onDate: today)
        if time < candidate.start { return day(onDate: shifted(today, by: -1)) }
        if time >= candidate.end { return day(onDate: shifted(today, by: 1)) }
        return candidate
    }

    /// `day` から `offset` 日ずらした日（暦の日で数える）
    func day(_ offset: Int, from day: BoundaryDay) -> BoundaryDay {
        self.day(onDate: shifted(day.date, by: offset))
    }

    // MARK: よく使う形

    func dayStart(containing time: Date) -> Date { day(containing: time).start }
    func dayKey(containing time: Date) -> String { day(containing: time).key }

    /// 一日の始まり `dayStart` の日から `offset` 日ずらした日の始まり
    func dayStart(_ offset: Int, from dayStart: Date) -> Date {
        day(offset, from: day(containing: dayStart)).start
    }

    /// 一日の始まり `dayStart` の日の終わり（その日の区切り）
    func dayEnd(ofDayStarting dayStart: Date) -> Date { day(containing: dayStart).end }

    /// 先週の同じ曜日（7日前の日の名前）の始まり
    func sameDayLastWeek(_ dayStart: Date) -> Date { self.dayStart(-7, from: dayStart) }

    /// その日の朝4:00（日の名前の日の 4:00）。この時刻から朝の計画を出し、睡眠を保存する（PLN-01、DTX-02）
    func morningStart(of day: BoundaryDay) -> Date {
        max(wallClock(day.date, minutes: Self.morningHour * 60), day.start)
    }

    /// 朝の計画を出せる時刻か（朝4:00以降。区切り〜3:59 は出さない）
    func isMorning(_ time: Date) -> Bool {
        time >= morningStart(of: day(containing: time))
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
