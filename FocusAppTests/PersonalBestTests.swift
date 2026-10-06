import Foundation
import SwiftData
import Testing
@testable import FocusApp

/// 自己ベストの期間・今日と比べる・ラップ表（ANA-06）と、ポイントの推移のさかのぼり（ANA-04）
@MainActor
struct PersonalBestTests {
    private func model(_ t: TestStore) -> AppModel {
        AppModel(store: t.store, clock: t.clock, timeZone: { tokyo }, settings: MemorySettings(),
                 blocking: FakeBlocking(), blockStore: MemoryBlockStore(), blockLog: MemoryBlockEventLog())
    }

    /// 集中のタイマーの記録を入れる（その日の dayKey は開始時刻から）
    private func record(_ t: TestStore, _ start: String, _ end: String) throws {
        let category = try t.category("勉強")
        let record = FocusSessionRecord(dayKey: DayBoundary.dayKey(containing: jst(start), calendar: tokyoCalendar),
                                        timeZoneId: "Asia/Tokyo", planBlockId: nil, categoryId: category.id,
                                        countsAsFocus: category.countsAsFocus, projectId: nil, startAt: jst(start),
                                        plannedEndAt: nil, plannedDurationSec: nil, at: jst(start))
        record.endAt = jst(end)
        // アプリと同じく store を通して保存する（保存の番号が進み、覚えたポイントを数え直す）
        try t.store.write { t.context.insert(record) }
    }

    // MARK: 期間の区切り

    /// 週は月曜から、月は1日から。どちらも朝4:00で区切り、今日は入れない
    @Test func periodStartsOnMondayAndTheFirst() {
        let thursday = jst("2026-10-22T04:00")
        #expect(BestPeriods.start(.week, today: thursday, calendar: tokyoCalendar) == jst("2026-10-19T04:00"))
        #expect(BestPeriods.start(.month, today: thursday, calendar: tokyoCalendar) == jst("2026-10-01T04:00"))
        #expect(BestPeriods.start(.all, today: thursday, calendar: tokyoCalendar) == nil)
        // 日曜は前の月曜から（日曜始まりではない）
        #expect(BestPeriods.start(.week, today: jst("2026-10-18T04:00"), calendar: tokyoCalendar) == jst("2026-10-12T04:00"))
        // 月曜・1日は期間の初日が今日（今日は入れないので、まだ記録がない）
        #expect(BestPeriods.start(.week, today: jst("2026-10-19T04:00"), calendar: tokyoCalendar) == jst("2026-10-19T04:00"))
        #expect(BestPeriods.start(.month, today: jst("2026-10-01T04:00"), calendar: tokyoCalendar) == jst("2026-10-01T04:00"))
    }

    /// 今週・今月・全期間で、それぞれ一番多い日。今日は入れない
    @Test func bestOfEachPeriodSkipsToday() throws {
        let t = try TestStore(now: jst("2026-10-22T12:00"))
        try t.seeded()
        try record(t, "2026-09-28T09:00", "2026-09-28T13:00")  // 9月（全期間のベスト）
        try record(t, "2026-10-13T09:00", "2026-10-13T12:00")  // 先週（今月のベスト）
        try record(t, "2026-10-20T09:00", "2026-10-20T10:00")  // 今週の火曜
        try record(t, "2026-10-21T09:00", "2026-10-21T11:00")  // 今週の水曜（今週のベスト）
        try record(t, "2026-10-22T05:00", "2026-10-22T11:00")  // 今日（入れない）
        let m = model(t)
        #expect(m.periodBest(.week)?.pointsDay == jst("2026-10-21T04:00"))
        #expect(m.periodBest(.week)?.focus?.focusDay == jst("2026-10-21T04:00"))
        #expect(m.periodBest(.week)?.focus?.focusSeconds == 2 * 3600)
        #expect(m.periodBest(.month)?.pointsDay == jst("2026-10-13T04:00"))
        #expect(m.periodBest(.all)?.pointsDay == jst("2026-09-28T04:00"))
        #expect(m.periodBest(.all)?.focus?.focusSeconds == 4 * 3600)
    }

    /// 今週に記録のある日がなければ nil（月曜は必ずこうなる）
    @Test func noBestOnMonday() throws {
        let t = try TestStore(now: jst("2026-10-19T12:00"))
        try t.seeded()
        try record(t, "2026-10-18T09:00", "2026-10-18T10:00")  // 前の週の日曜
        try record(t, "2026-10-19T09:00", "2026-10-19T11:00")  // 今日
        let m = model(t)
        #expect(m.periodBest(.week) == nil)
        #expect(m.periodBest(.month)?.pointsDay == jst("2026-10-18T04:00"))
    }

    /// 日曜の 3:59 は土曜（前の週ではなく今週の中）、4:00 からは日曜
    @Test func sundayBeforeFourIsSaturday() throws {
        let t = try TestStore(now: jst("2026-10-19T03:59"))  // まだ日曜（10/18）
        try t.seeded()
        try record(t, "2026-10-18T09:00", "2026-10-18T10:00")
        let m = model(t)
        // 今日は日曜なので入れない。今週（10/12〜）にほかの記録はない
        #expect(m.periodBest(.week) == nil)
        t.clock.set(jst("2026-10-19T04:00"))
        // 月曜になると日曜は前の週。今週はまだない
        #expect(m.periodBest(.week) == nil)
        #expect(m.periodBest(.month)?.pointsDay == jst("2026-10-18T04:00"))
    }

    /// 全期間は使い始めから全部（180日より前も入る）
    @Test func allTimeHasNoDayLimit() throws {
        let t = try TestStore(now: jst("2026-10-22T12:00"))
        try t.seeded()
        try record(t, "2026-01-05T09:00", "2026-01-05T13:00")
        try record(t, "2026-10-21T09:00", "2026-10-21T10:00")
        #expect(model(t).periodBest(.all)?.pointsDay == jst("2026-01-05T04:00"))
    }

    /// 過ぎた日のポイントは覚えておくが、記録を足したら数え直す
    @Test func newRecordsAreCountedAfterCaching() throws {
        let t = try TestStore(now: jst("2026-10-22T12:00"))
        try t.seeded()
        try record(t, "2026-10-20T09:00", "2026-10-20T10:00")
        try record(t, "2026-10-21T09:00", "2026-10-21T10:30")
        let m = model(t)
        #expect(m.periodBest(.week)?.pointsDay == jst("2026-10-21T04:00"))
        try record(t, "2026-10-20T13:00", "2026-10-20T15:00")
        #expect(m.periodBest(.week)?.pointsDay == jst("2026-10-20T04:00"))
        #expect(m.periodBest(.week)?.focus?.focusSeconds == 3 * 3600)
    }

    // MARK: ラップ表

    /// 区間ごとの増えた分と累計。今の区間は同じ時刻までで比べ、まだ来ていない区間は今日の欄を空ける
    @Test func lapRowsCompareUpToNow() {
        let today = jst("2026-10-22T04:00")
        let best = jst("2026-10-13T04:00")
        // 今日：8:00〜9:00 に 6pt、10:00〜 に1時間で 6pt（今 11:00）
        func mine(_ date: Date) -> Double {
            let h = date.timeIntervalSince(today) / 3600
            return min(max(h - 4, 0), 1) * 6 + min(max(h - 6, 0), 1) * 6
        }
        // ベストの日：8:00〜10:00 に 10pt、10:00〜12:00 に 12pt、14:00〜15:00 に 5pt
        func theirs(_ date: Date) -> Double {
            let h = date.timeIntervalSince(best) / 3600
            return min(max(h - 4, 0), 2) * 5 + min(max(h - 6, 0), 2) * 6 + min(max(h - 10, 0), 1) * 5
        }
        let rows = BestLaps.make(today: mine, todayStart: today, now: jst("2026-10-22T11:00"), best: theirs, bestStart: best)
        // どちらも0の区間（4:00–8:00、12:00–14:00 など）は省く
        #expect(rows.map(\.section.start) == [jst("2026-10-22T08:00"), jst("2026-10-22T10:00"), jst("2026-10-22T14:00")])
        let first = rows[0]
        #expect(first.today?.isApprox(6) == true)
        #expect(first.todayTotal?.isApprox(6) == true)
        #expect(first.best.isApprox(10))
        #expect(first.bestTotal.isApprox(10))
        #expect(!first.isCurrent)
        // 今の区間：ベストの日も 11:00 まで（12pt のうち 6pt）
        let current = rows[1]
        #expect(current.isCurrent)
        #expect(current.today?.isApprox(6) == true)
        #expect(current.todayTotal?.isApprox(12) == true)
        #expect(current.best.isApprox(6))
        #expect(current.bestTotal.isApprox(16))
        #expect(current.totalGap?.isApprox(-4) == true)
        // まだ来ていない区間：今日は空、ベストの日は区間の全部
        let future = rows[2]
        #expect(future.today == nil)
        #expect(future.todayTotal == nil)
        #expect(future.totalGap == nil)
        #expect(future.best.isApprox(5))
        #expect(future.bestTotal.isApprox(27))
    }

    /// 赤にするのは表示（0.1pt）で上回ったときだけ。同じなら付けない
    @Test func beatsComparesTheShownValues() {
        #expect(BestLaps.beats(14.2, 12.0))
        #expect(!BestLaps.beats(12.0, 12.0))
        #expect(!BestLaps.beats(12.04, 12.0))
        #expect(BestLaps.beats(12.06, 12.0))
        #expect(!BestLaps.beats(11.9, 12.0))
    }

    /// 今日の比べる数字：今日の今までと、ベストの日の同じ時刻まで
    @Test func todayAgainstTheBestDayAtTheSameTime() throws {
        let t = try TestStore(now: jst("2026-10-22T12:00"))
        try t.seeded()
        try record(t, "2026-10-13T09:00", "2026-10-13T10:00")
        try record(t, "2026-10-13T15:00", "2026-10-13T17:00")
        try record(t, "2026-10-22T08:00", "2026-10-22T09:30")
        let m = model(t)
        let best = try #require(m.periodBest(.month))
        let comparison = try #require(m.bestComparison(bestDay: best.pointsDay))
        let todaySnapshot = try #require(m.daySnapshot(daysAgo: 0))
        let bestSnapshot = try #require(m.daySnapshot(of: best.pointsDay))
        #expect(comparison.today.isApprox(todaySnapshot.points))
        #expect(comparison.bestAtSameTime.isApprox(bestSnapshot.myPoints(until: jst("2026-10-13T12:00"))))
        #expect(comparison.rows.contains { $0.section.start == jst("2026-10-22T14:00") && $0.today == nil })
    }

    // MARK: ポイントの推移のさかのぼり（ANA-04）

    /// 1期間ずつ前へ。7日なら7日、30日なら30日
    @Test func pagesGoBackOnePeriodAtATime() throws {
        let t = try TestStore(now: jst("2026-10-19T12:00"))
        try t.seeded()
        let m = model(t)
        let previous = m.pointsHistory(days: 7, page: 1)
        #expect(previous.count == 7)
        #expect(previous.first?.dayStart == jst("2026-10-06T04:00"))
        #expect(previous.last?.dayStart == jst("2026-10-12T04:00"))
        #expect(previous.allSatisfy { !$0.isToday })
        let month = m.pointsHistory(days: 30, page: 1)
        #expect(month.last?.dayStart == jst("2026-09-19T04:00"))
        #expect(m.pointsHistory(days: 7, page: 0) == m.pointsHistory(days: 7))
    }

    /// ‹ は一番古い記録の日を含む期間まで
    @Test func canGoBackUntilTheOldestRecord() throws {
        let t = try TestStore(now: jst("2026-10-19T12:00"))
        try t.seeded()
        let m = model(t)
        // 記録がなければさかのぼらない
        #expect(!m.canGoBack(days: 7, page: 0))
        try record(t, "2026-10-08T09:00", "2026-10-08T10:00")
        // 今の期間（10/13〜10/19）より前に記録がある
        #expect(m.canGoBack(days: 7, page: 0))
        // 10/6〜10/12 は記録の日を含むので、それより前へは行かない
        #expect(!m.canGoBack(days: 7, page: 1))
        #expect(!m.canGoBack(days: 30, page: 0))
    }
}
