import Foundation
import SwiftData
import Testing
@testable import FocusApp

/// 分析のポイントの推移（ANA-04）とその日のグラフ（ANA-05）。過去の日もホームと同じ計算で数える。
@MainActor
struct PointsHistoryTests {
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
        t.context.insert(record)
        try t.context.save()
    }

    // MARK: その日の数字（ANA-05）

    /// 今日は今まで、過ぎた日は翌4:00までの1日分
    @Test func daySnapshotCoversTheWholePastDay() throws {
        let t = try TestStore(now: jst("2026-10-19T12:00"))
        try t.seeded()
        try record(t, "2026-10-18T21:00", "2026-10-18T22:00")
        let m = model(t)
        let yesterday = try #require(m.daySnapshot(daysAgo: 1))
        #expect(yesterday.dayStart == jst("2026-10-18T04:00"))
        #expect(yesterday.now == jst("2026-10-19T04:00"))
        #expect(yesterday.focusSeconds == 3600)
        let today = try #require(m.daySnapshot(daysAgo: 0))
        #expect(today.now == jst("2026-10-19T12:00"))
        #expect(today.focusSeconds == 0)
    }

    /// 今日の数字はホームと同じ
    @Test func todayMatchesHome() throws {
        let t = try TestStore(now: jst("2026-10-19T12:00"))
        try t.seeded()
        try record(t, "2026-10-19T09:00", "2026-10-19T10:00")
        try record(t, "2026-10-12T09:00", "2026-10-12T11:00")
        let m = model(t)
        m.skipPlan()
        let today = try #require(m.daySnapshot(daysAgo: 0))
        #expect(today.points.isApprox(m.snapshot.points))
        #expect(today.focusSeconds == m.snapshot.focusSeconds)
        let history = m.pointsHistory(days: 7)
        #expect(history.last?.points.map { $0.isApprox(m.snapshot.points) } == true)
    }

    /// 未来は見られない
    @Test func noFutureDays() throws {
        let t = try TestStore(now: jst("2026-10-19T12:00"))
        try t.seeded()
        #expect(model(t).daySnapshot(daysAgo: -1) == nil)
    }

    /// 0:00〜3:59 は前の日が「今日」
    @Test func beforeFourIsStillThePreviousDay() throws {
        let t = try TestStore(now: jst("2026-10-20T03:59"))
        try t.seeded()
        let m = model(t)
        #expect(m.daySnapshot(daysAgo: 0)?.dayStart == jst("2026-10-19T04:00"))
        #expect(m.pointsHistory(days: 7).last?.dayStart == jst("2026-10-19T04:00"))
    }

    /// 前の日に始めて4:00をまたいだタイマーは、4:00より後の分をその日に入れる（ホームと同じ）
    @Test func carriedOverTimerCountsAfterFour() throws {
        let t = try TestStore(now: jst("2026-10-19T12:00"))
        try t.seeded()
        try record(t, "2026-10-18T03:00", "2026-10-18T05:00")
        let m = model(t)
        // 10/18 3:00 は 10/17 の日。10/18 の日には 4:00〜5:00 の1時間
        #expect(m.daySnapshot(daysAgo: 1)?.focusSeconds == 3600)
    }

    // MARK: ポイントの推移（ANA-04）

    /// 古い日から今日まで、今日を含めて指定した日数
    @Test func historyIsOldestFirstAndEndsToday() throws {
        let t = try TestStore(now: jst("2026-10-19T12:00"))
        try t.seeded()
        let m = model(t)
        let week = m.pointsHistory(days: 7)
        #expect(week.count == 7)
        #expect(week.first?.dayStart == jst("2026-10-13T04:00"))
        #expect(week.last?.dayStart == jst("2026-10-19T04:00"))
        #expect(week.last?.isToday == true)
        #expect(week.dropLast().allSatisfy { !$0.isToday })
        #expect(m.pointsHistory(days: 30).count == 30)
    }

    /// タイマーの記録・計画・保存した睡眠のどれもない日は「記録なし」（使い始める前の日に設定の睡眠で点が付かないように）
    @Test func daysWithoutAnyRecordHaveNoPoints() throws {
        let t = try TestStore(now: jst("2026-10-19T12:00"))
        try t.seeded()
        try record(t, "2026-10-17T09:00", "2026-10-17T10:00")
        try t.store.skip(dayKey: "2026-10-16", timeZone: tokyo)
        let m = model(t)
        let week = m.pointsHistory(days: 7)
        let byDay = Dictionary(uniqueKeysWithValues: week.map { (DayBoundary.dayKey(containing: $0.dayStart, calendar: tokyoCalendar), $0) })
        #expect(byDay["2026-10-15"]?.points == nil)
        // 計画なしにした日は記録がある日（タイマーがなくても点を出す）
        #expect(byDay["2026-10-16"]?.points != nil)
        #expect(byDay["2026-10-17"]?.points != nil)
        // 今日はいつも出す
        #expect(byDay["2026-10-19"]?.points != nil)
    }

    /// 過ぎた日の合計は、その日のグラフの最後（翌4:00）の値と同じ
    @Test func pastDayPointsMatchTheDayGraph() throws {
        let t = try TestStore(now: jst("2026-10-19T12:00"))
        try t.seeded()
        try record(t, "2026-10-17T09:00", "2026-10-17T11:00")
        let m = model(t)
        let day = try #require(m.pointsHistory(days: 7).first { $0.dayStart == jst("2026-10-17T04:00") })
        let snapshot = try #require(m.daySnapshot(daysAgo: 2))
        #expect(try #require(day.points).isApprox(snapshot.points))
        #expect(snapshot.points >= 12)
    }

    // MARK: 平均

    /// 一覧の行の平均：今日（途中）と記録のない日を除いた、直近7日のうち過ぎた日
    @Test func averageSkipsTodayAndEmptyDays() {
        let days = [
            DayPoints(dayStart: jst("2026-10-16T04:00"), points: 40, lastWeek: nil, isToday: false),
            DayPoints(dayStart: jst("2026-10-17T04:00"), points: nil, lastWeek: nil, isToday: false),
            DayPoints(dayStart: jst("2026-10-18T04:00"), points: 50, lastWeek: 30, isToday: false),
            DayPoints(dayStart: jst("2026-10-19T04:00"), points: 5, lastWeek: 10, isToday: true),
        ]
        #expect(PointsHistory.average(days)?.isApprox(45) == true)
        #expect(PointsHistory.average([days[1], days[3]]) == nil)
    }

    /// 差（自分−先週の同じ曜日）。比べる数字がない日は nil
    @Test func gapAgainstLastWeek() {
        #expect(DayPoints(dayStart: jst("2026-10-18T04:00"), points: 50, lastWeek: 30, isToday: false).gap == 20)
        #expect(DayPoints(dayStart: jst("2026-10-18T04:00"), points: 50, lastWeek: nil, isToday: false).gap == nil)
        #expect(DayPoints(dayStart: jst("2026-10-18T04:00"), points: nil, lastWeek: 30, isToday: false).gap == nil)
    }
}
