import Foundation
import Testing
@testable import FocusApp

/// 夜の振り返りの勝ち負け（GHO-04。2026-10-02 オーナー決定：集中・デトックス・ポイント、相手は先週の同じ曜日の自分。
/// 2026-10-03 にデトックスを開けた時間に変更、DTX-05）。
struct ReviewVerdictTests {
    private let calendar = tokyoCalendar
    private let started = BlockEvent(occurredAt: jst("2026-10-01T09:00"), timeZoneId: "Asia/Tokyo", kind: .started)

    private func detox(_ dayStart: String, until: String, sessions: [FocusSession], unlocked: (String, String)? = nil) -> DetoxDay {
        let segments = sessions.flatMap { $0.activeSegments(now: jst(until)) }
        var events = [started]
        if let unlocked {
            events += [BlockEvent(occurredAt: jst(unlocked.0), timeZoneId: "Asia/Tokyo", kind: .unlocked, unlockMinutes: 60),
                       BlockEvent(occurredAt: jst(unlocked.1), timeZoneId: "Asia/Tokyo", kind: .reblocked)]
        }
        return DetoxDay.make(.init(dayStart: jst(dayStart), dayEnd: jst(dayStart).addingTimeInterval(86400), until: jst(until),
                                   events: events, focus: segments.map { DateInterval(start: $0.start, end: $0.end) },
                                   detoxTimers: [], sleep: [], gameWindows: []))
    }

    private func review(today: [FocusSession], lastWeek: [FocusSession], lastWeekDetox: DetoxDay?,
                        todayUnlocked: (String, String)? = nil) -> ReviewContent {
        let home = HomeSnapshot.make(now: jst("2026-10-19T22:30"), calendar: calendar, todaySessions: today, plan: nil,
                                     lastWeekSessions: lastWeek,
                                     detox: detox("2026-10-19T04:00", until: "2026-10-19T22:30", sessions: today,
                                                  unlocked: todayUnlocked),
                                     lastWeekDetox: lastWeekDetox)
        return ReviewContent.make(home: home, sessions: today, snapshot: nil)
    }

    @Test func threeItemsAgainstLastWeek() throws {
        let today = [session("2026-10-19T09:00", "2026-10-19T12:00")]
        let lastWeek = [session("2026-10-12T09:00", "2026-10-12T11:00")]
        // 今日は1時間開けた。先週は一度も開けていない
        let r = review(today: today, lastWeek: lastWeek,
                       lastWeekDetox: detox("2026-10-12T04:00", until: "2026-10-13T04:00", sessions: lastWeek),
                       todayUnlocked: ("2026-10-19T20:00", "2026-10-19T21:00"))
        #expect(r.verdicts.map(\.item) == [.focus, .opened, .points])
        let byItem = Dictionary(uniqueKeysWithValues: r.verdicts.map { ($0.item, $0) })
        #expect(byItem[.focus]?.result == .win)      // 3時間 vs 2時間
        #expect(byItem[.opened]?.result == .lose)    // 開けた 1時間 vs 0分 → 少ない先週の勝ち
        #expect(byItem[.points]?.theirs != nil)
    }

    @Test func noLastWeekMeansNoVerdicts() {
        let r = review(today: [session("2026-10-19T09:00", "2026-10-19T10:00")], lastWeek: [], lastWeekDetox: nil)
        #expect(r.verdicts.isEmpty)
    }

    /// 使い始めの週：先週の集中はあるが、ブロックの記録が丸1日分ない → 開けた時間とポイントは比べない
    @Test func incompleteLastWeekDetoxIsNoRecord() throws {
        let lastWeek = [session("2026-10-12T09:00", "2026-10-12T10:00")]
        let r = review(today: [session("2026-10-19T09:00", "2026-10-19T10:00")], lastWeek: lastWeek, lastWeekDetox: nil)
        let byItem = Dictionary(uniqueKeysWithValues: r.verdicts.map { ($0.item, $0) })
        #expect(byItem[.focus]?.result == .draw)
        #expect(byItem[.opened]?.result == .noRecord)
        #expect(byItem[.points]?.result == .noRecord)
    }

    @Test func comparesAtTheShownPrecision() {
        // 時間は分、ポイントは小数1桁でそろえる
        // どちらも「1時間」と出るので引き分け。1分違えば負け
        #expect(ReviewContent.Verdict(item: .focus, mine: 3600, theirs: 3659).result == .draw)
        #expect(ReviewContent.Verdict(item: .focus, mine: 3600, theirs: 3660).result == .lose)
        #expect(ReviewContent.Verdict(item: .opened, mine: 119, theirs: 89).result == .draw)
        #expect(ReviewContent.Verdict(item: .points, mine: 12.31, theirs: 12.34).result == .draw)
        #expect(ReviewContent.Verdict(item: .points, mine: 12.4, theirs: 12.3).result == .win)
    }

    /// 目標との差は今までどおり別に出す（先週の自分は勝ち負けの表に移した）
    @Test func goalDiffStaysSeparate() {
        let plan = PlanDraft(blocks: [PlanBlockDraft(start: jst("2026-10-19T09:00"), minutes: 120, category: DefaultCategories.all[0])])
        let home = HomeSnapshot.make(now: jst("2026-10-19T22:30"), calendar: calendar, todaySessions: [], plan: plan,
                                     lastWeekSessions: [session("2026-10-12T09:00", "2026-10-12T10:00")])
        let r = ReviewContent.make(home: home, sessions: [], snapshot: nil)
        #expect(r.opponents.map(\.opponent) == [.goal])
    }

    /// 先週は2時間開け、今日は開けていない → 開けた時間もポイントも勝ち
    @Test func detoxAndPointsCanWin() {
        let today = [session("2026-10-19T09:00", "2026-10-19T11:00")]
        let lastWeek = [session("2026-10-12T09:00", "2026-10-12T11:00")]
        let lastWeekOpened = detox("2026-10-12T04:00", until: "2026-10-13T04:00", sessions: lastWeek,
                                   unlocked: ("2026-10-12T13:00", "2026-10-12T15:00"))
        let r = review(today: today, lastWeek: lastWeek, lastWeekDetox: lastWeekOpened)
        let byItem = Dictionary(uniqueKeysWithValues: r.verdicts.map { ($0.item, $0) })
        #expect(byItem[.focus]?.result == .draw)
        #expect(byItem[.opened]?.result == .win)
        #expect(byItem[.points]?.result == .win)
    }

    /// 先週タイマーを使っていなくても、ブロックの記録が丸1日分あれば比べる（先週の集中は0分）
    @Test func lastWeekWithoutTimersStillCompares() {
        let r = review(today: [session("2026-10-19T09:00", "2026-10-19T10:00")], lastWeek: [],
                       lastWeekDetox: detox("2026-10-12T04:00", until: "2026-10-13T04:00", sessions: []))
        let byItem = Dictionary(uniqueKeysWithValues: r.verdicts.map { ($0.item, $0) })
        #expect(byItem[.focus]?.theirs == 0)
        #expect(byItem[.focus]?.result == .win)
        #expect(byItem[.opened]?.result != .noRecord)
    }
}
