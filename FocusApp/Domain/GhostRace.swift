import Foundation

/// 記録の区間（セッションや計画ブロックの時間帯）。
struct TimeSegment: Hashable {
    var start: Date
    var end: Date
    var countsAsFocus: Bool
    /// デトックスのタイマーのグループ（DTX-03 の上限に使う）。集中・上乗せなしのカテゴリは nil
    var detoxGroup: DetoxGroup? = nil
    /// 押し忘れの申告（TMR-13）の区間。点は0.8倍
    var isDeclared = false

    /// `until` までに含まれる秒数。
    func seconds(until date: Date) -> Int {
        max(0, Int(min(end, date).timeIntervalSince(start)))
    }

    /// `dayStart`（4:00）より前を切り落とす。前の日に始めて4:00をまたいだタイマーの、新しい日の分（2026-10-03）
    func starting(at dayStart: Date) -> TimeSegment? {
        guard end > dayStart else { return nil }
        var segment = self
        segment.start = max(start, dayStart)
        return segment
    }
}

extension [TimeSegment] {
    /// `date` までの集中時間の合計（進行中の区間はその時刻までの分）。
    func focusSeconds(until date: Date) -> Int {
        filter(\.countsAsFocus).reduce(0) { $0 + $1.seconds(until: date) }
    }

    func detoxSeconds(until date: Date) -> Int {
        filter { !$0.countsAsFocus }.reduce(0) { $0 + $1.seconds(until: date) }
    }
}

/// 先週の同じ曜日の自分。区間は日付境界からの経過時間で今日に揃えてある（GHO-02）。
struct GhostSummary: Hashable {
    var segments: [TimeSegment]

    func focusSeconds(at date: Date) -> Int { segments.focusSeconds(until: date) }

    var wholeDayFocusSeconds: Int { segments.focusSeconds(until: .distantFuture) }
}

extension GhostSummary {
    /// 先週の記録を、日付境界からの経過時間で今日に揃える（GHO-02）。24時間を超える部分は切る。記録がなければ nil。
    init?(lastWeek sessions: [FocusSession], lastWeekStart: Date, todayStart: Date) {
        guard !sessions.isEmpty else { return nil }
        let offset = todayStart.timeIntervalSince(lastWeekStart)
        let limit = lastWeekStart.addingTimeInterval(24 * 3600)
        // 前の日に始めて4:00をまたいだ分も入れる（4:00より前は切る、2026-10-03）
        segments = sessions
            .flatMap { $0.activeSegments(now: $0.endAt ?? $0.startAt) }
            .compactMap { $0.starting(at: lastWeekStart) }
            .compactMap { segment in
                let end = min(segment.end, limit)
                guard end > segment.start else { return nil }
                return TimeSegment(start: segment.start.addingTimeInterval(offset), end: end.addingTimeInterval(offset),
                                   countsAsFocus: segment.countsAsFocus, detoxGroup: segment.detoxGroup)
            }
    }
}
