import Foundation

/// その日の朝に終わった睡眠（DTX-02、digital-detox.md「睡眠」）。朝の計画の上に出す。
struct SleepLine: Equatable, Sendable {
    enum Source: String, Sendable {
        /// ヘルスケアの記録
        case health
        /// 設定の「睡眠の時刻」（ヘルスケアに記録がない日）
        case setting
        /// 手で直した（ヘルスケアで置き換えない）
        case manual

        /// 知らない値は手で直したものとして読む（置き換えない）
        init(raw: String) { self = Source(rawValue: raw) ?? .manual }

        var label: String {
            switch self {
            case .health: "ヘルスケア"
            case .setting: "設定の時刻"
            case .manual: "手で直した"
            }
        }
    }

    var start: Date
    var end: Date
    var source: Source
    /// 手で直す前の時刻（第4版、DTX-02・03）。最初に手で直したときの直前の値。手で直していない・第4版より前に直した日は nil
    var original: DateInterval? = nil

    var interval: DateInterval { DateInterval(start: start, end: max(start, end)) }

    /// 手で直す前より長くした分（寝た時刻から直す前の長さを超えた所）。ポイントでは0.5pt と睡眠の点の低いほうで数える
    /// （digital-detox.md「睡眠の点」）。長くしていなければ nil
    var extendedPart: DateInterval? {
        guard source == .manual, let original else { return nil }
        let from = start.addingTimeInterval(original.duration)
        return from < end ? DateInterval(start: from, end: end) : nil
    }

    /// 時刻だけを選んだ寝た時刻を、起きた時刻より前に合わせる（23:30 なら前の夜。24時間より前には戻さない）
    static func normalizedStart(_ start: Date, end: Date) -> Date {
        var start = start
        while start >= end { start = start.addingTimeInterval(-24 * 3600) }
        while end.timeIntervalSince(start) >= 24 * 3600 { start = start.addingTimeInterval(24 * 3600) }
        return start
    }

    /// 設定の睡眠の時刻（0:00 からの分）をその日に当てはめる。寝る時刻が起きる時刻より遅ければ前の夜
    /// - dayStart: その日の 4:00
    static func fromSetting(startMinutes: Int, endMinutes: Int, dayStart: Date, calendar: Calendar) -> SleepLine {
        let day = calendar.startOfDay(for: dayStart)
        let end = calendar.date(byAdding: .minute, value: endMinutes, to: day) ?? day
        var start = calendar.date(byAdding: .minute, value: startMinutes, to: day) ?? day
        if start >= end { start = calendar.date(byAdding: .day, value: -1, to: start) ?? start }
        return SleepLine(start: start, end: end, source: .setting)
    }
}

/// ヘルスケアの睡眠の記録から、その日の朝に終わった睡眠を選ぶ（DTX-02）。
enum SleepPicker {
    /// これ以上あいたら別のまとまり
    static let gapLimit: TimeInterval = 3600

    /// 前の日の18:00〜その日の14:00 に入っている記録を、1時間以上あかずに続くまとまりにし、一番長いもの（同じなら遅く終わった方）。
    /// 昼寝などの短いまとまりは選ばれない。なければ nil
    static func pick(_ samples: [DateInterval], dayStart: Date, calendar: Calendar) -> DateInterval? {
        let (from, to) = searchRange(dayStart: dayStart, calendar: calendar)
        let inRange = samples.filter { $0.end > from && $0.start < to }.sorted { $0.start < $1.start }
        var clusters: [DateInterval] = []
        for sample in inRange {
            if let last = clusters.last, sample.start.timeIntervalSince(last.end) < gapLimit {
                clusters[clusters.count - 1] = DateInterval(start: last.start, end: max(last.end, sample.end))
            } else {
                clusters.append(sample)
            }
        }
        return clusters.max { $0.duration != $1.duration ? $0.duration < $1.duration : $0.end < $1.end }
    }

    /// 探す範囲：前の日の18:00〜その日の14:00（その日＝dayStart の暦の日）
    static func searchRange(dayStart: Date, calendar: Calendar) -> (Date, Date) {
        let day = calendar.startOfDay(for: dayStart)
        return (calendar.date(byAdding: .hour, value: -6, to: day) ?? day, calendar.date(byAdding: .hour, value: 14, to: day) ?? day)
    }
}
