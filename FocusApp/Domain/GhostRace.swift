import Foundation

/// 記録の区間（セッションや計画ブロックの時間帯）。
struct TimeSegment: Hashable {
    var start: Date
    var end: Date
    var countsAsFocus: Bool
    /// デトックスのタイマーのグループ（DTX-03 の上限に使う）。集中・上乗せなしのカテゴリは nil
    var detoxGroup: DetoxGroup? = nil
    /// 手動の記録（TMR-13）の区間。点は0.8倍
    var isDeclared = false
    /// ゲーム・SNS の時間（BLK-10）のカテゴリ。デトックスにも数えない（裏のグラフの線の色、2026-10-11）
    var isUnblock = false

    /// `until` までに含まれる秒数。
    func seconds(until date: Date) -> Int {
        max(0, Int(min(end, date).timeIntervalSince(start)))
    }

    /// `dayStart`（一日の始まり）より前を切り落とす。前の日に始めて区切りをまたいだタイマーの、新しい日の分（2026-10-03）
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

/// 先週の同じ曜日の自分。区間は同じ時刻でそろえて（7日ずらして）今日に重ねてある（GHO-02）。
struct GhostSummary: Hashable {
    var segments: [TimeSegment]

    func focusSeconds(at date: Date) -> Int { segments.focusSeconds(until: date) }

    var wholeDayFocusSeconds: Int { segments.focusSeconds(until: .distantFuture) }
}

extension GhostSummary {
    /// 先週の記録を、同じ時刻でそろえて今日に重ねる（GHO-02、glossary.md「同じ時刻でそろえる」）。
    /// 先週の日の始まりより前・終わりより後は切る（始まりより前は0、終わりより後は先週のその日の合計になる）。記録がなければ nil。
    /// - lastWeekDay: 先週の日の始まり〜終わり（先週の区切りで数えたまま）
    /// - shift: 先週の日を今日に重ねるずれ（日の名前の日の 0:00 どうしの差。ふつうは7日）
    init?(lastWeek sessions: [FocusSession], lastWeekDay: DateInterval, shift: TimeInterval) {
        guard !sessions.isEmpty else { return nil }
        // 前の日に始めて区切りをまたいだ分も入れる（区切りより前は切る、2026-10-03）
        segments = sessions
            .flatMap { $0.activeSegments(now: $0.endAt ?? $0.startAt) }
            .compactMap { $0.starting(at: lastWeekDay.start) }
            .compactMap { segment in
                let end = min(segment.end, lastWeekDay.end)
                guard end > segment.start else { return nil }
                return TimeSegment(start: segment.start.addingTimeInterval(shift), end: end.addingTimeInterval(shift),
                                   countsAsFocus: segment.countsAsFocus, detoxGroup: segment.detoxGroup,
                                   isDeclared: segment.isDeclared)
            }
    }

}
