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
        #expect(m.periodBests()[.week]?.pointsDay == jst("2026-10-21T04:00"))
        #expect(m.periodBests()[.week]?.focus?.focusDay == jst("2026-10-21T04:00"))
        #expect(m.periodBests()[.week]?.focus?.focusSeconds == 2 * 3600)
        #expect(m.periodBests()[.month]?.pointsDay == jst("2026-10-13T04:00"))
        #expect(m.periodBests()[.all]?.pointsDay == jst("2026-09-28T04:00"))
        #expect(m.periodBests()[.all]?.focus?.focusSeconds == 4 * 3600)
    }

    /// 今週に記録のある日がなければ nil（月曜は必ずこうなる）
    @Test func noBestOnMonday() throws {
        let t = try TestStore(now: jst("2026-10-19T12:00"))
        try t.seeded()
        try record(t, "2026-10-18T09:00", "2026-10-18T10:00")  // 前の週の日曜
        try record(t, "2026-10-19T09:00", "2026-10-19T11:00")  // 今日
        let m = model(t)
        #expect(m.periodBests()[.week] == nil)
        #expect(m.periodBests()[.month]?.pointsDay == jst("2026-10-18T04:00"))
    }

    /// 月曜の 3:59 はまだ日曜（今日）なので、日曜の記録は入らない。4:00 に月曜になると、日曜は前の週
    @Test func mondayBeforeFourIsStillSunday() throws {
        let t = try TestStore(now: jst("2026-10-19T03:59"))  // まだ日曜（10/18）
        try t.seeded()
        try record(t, "2026-10-18T09:00", "2026-10-18T10:00")
        let m = model(t)
        // 今日は日曜なので入れない。今週（10/12〜）にほかの記録はない
        #expect(m.periodBests()[.week] == nil)
        t.clock.set(jst("2026-10-19T04:00"))
        // 月曜になると日曜は前の週。今週はまだない
        #expect(m.periodBests()[.week] == nil)
        #expect(m.periodBests()[.month]?.pointsDay == jst("2026-10-18T04:00"))
    }

    /// 3:59 に始めた記録は前の日、4:00 に始めた記録はその日
    @Test func recordsSplitAtFourAM() throws {
        let t = try TestStore(now: jst("2026-10-22T12:00"))
        try t.seeded()
        try record(t, "2026-10-21T03:00", "2026-10-21T03:59")  // 火曜の夜（水曜の 3:59 まで）
        try record(t, "2026-10-21T04:00", "2026-10-21T04:30")  // 水曜
        try record(t, "2026-10-20T09:00", "2026-10-20T09:20")  // 火曜の昼
        let best = try #require(model(t).periodBests()[.week]?.focus)
        #expect(best.focusDay == jst("2026-10-20T04:00"))
        #expect(best.focusSeconds == 79 * 60)
    }

    /// 同じポイントなら新しい日をベストにする
    @Test func tieGoesToTheNewerDay() throws {
        let t = try TestStore(now: jst("2026-10-22T12:00"))
        try t.seeded()
        try record(t, "2026-10-20T09:00", "2026-10-20T10:00")
        try record(t, "2026-10-21T09:00", "2026-10-21T10:00")
        let m = model(t)
        #expect(m.periodBests()[.week]?.pointsDay == jst("2026-10-21T04:00"))
    }

    /// 記録がない・今日しかない・1日（今月は今日だけ）は、その期間のベストがない
    @Test func noBestWithoutPastDays() throws {
        let t = try TestStore(now: jst("2026-11-01T12:00"))
        try t.seeded()
        let m = model(t)
        #expect(m.periodBests().isEmpty)
        try record(t, "2026-11-01T09:00", "2026-11-01T10:00")
        #expect(m.periodBests().isEmpty)
        try record(t, "2026-10-31T09:00", "2026-10-31T10:00")
        #expect(m.periodBests()[.month] == nil)
        // 11/1 は日曜なので、今週（10/26〜）には土曜が入る
        #expect(m.periodBests()[.week]?.pointsDay == jst("2026-10-31T04:00"))
        #expect(m.periodBests()[.all]?.pointsDay == jst("2026-10-31T04:00"))
    }

    /// 全期間は使い始めから全部（180日より前も入る）
    @Test func allTimeHasNoDayLimit() throws {
        let t = try TestStore(now: jst("2026-10-22T12:00"))
        try t.seeded()
        try record(t, "2026-01-05T09:00", "2026-01-05T13:00")
        try record(t, "2026-10-21T09:00", "2026-10-21T10:00")
        #expect(model(t).periodBests()[.all]?.pointsDay == jst("2026-01-05T04:00"))
    }

    /// 過ぎた日のポイントは覚えておくが、記録を足したら数え直す
    @Test func newRecordsAreCountedAfterCaching() throws {
        let t = try TestStore(now: jst("2026-10-22T12:00"))
        try t.seeded()
        try record(t, "2026-10-20T09:00", "2026-10-20T10:00")
        try record(t, "2026-10-21T09:00", "2026-10-21T10:30")
        let m = model(t)
        #expect(m.periodBests()[.week]?.pointsDay == jst("2026-10-21T04:00"))
        try record(t, "2026-10-20T13:00", "2026-10-20T15:00")
        #expect(m.periodBests()[.week]?.pointsDay == jst("2026-10-20T04:00"))
        #expect(m.periodBests()[.week]?.focus?.focusSeconds == 3 * 3600)
    }

    /// 日が変わると、昨日（さっきまでの今日）がベストの候補に入る
    @Test func dayChangeAddsYesterday() throws {
        let t = try TestStore(now: jst("2026-10-21T23:00"))
        try t.seeded()
        try record(t, "2026-10-20T09:00", "2026-10-20T10:00")
        try record(t, "2026-10-21T09:00", "2026-10-21T12:00")
        let m = model(t)
        #expect(m.periodBests()[.week]?.pointsDay == jst("2026-10-20T04:00"))
        t.clock.set(jst("2026-10-22T04:00"))
        #expect(m.periodBests()[.week]?.pointsDay == jst("2026-10-21T04:00"))
    }

    /// 睡眠の時刻の設定を変えると、睡眠を保存していない日（開いたときに保存する直近7日より前）のポイントを数え直す
    @Test func sleepSettingChangeRecounts() throws {
        let t = try TestStore(now: jst("2026-10-22T12:00"))
        try t.seeded()
        try record(t, "2026-10-12T09:00", "2026-10-12T10:00")
        // 睡眠の点はブロックが効いている間に付くので、その日の朝からブロックを効かせておく
        let log = MemoryBlockEventLog()
        try log.append(BlockEvent(occurredAt: jst("2026-10-12T04:00"), timeZoneId: "Asia/Tokyo", kind: .started))
        let settings = MemorySettings()
        settings.didShowBlockingIntro = true
        settings.didLogBlockStart = true
        settings.lastBlockingAuthorized = true
        let blockStore = MemoryBlockStore()
        blockStore.state = BlockState(isEnabled: true)
        blockStore.selection = Data("sel".utf8)
        func make() -> AppModel {
            AppModel(store: t.store, clock: t.clock, timeZone: { tokyo }, settings: settings,
                     blocking: FakeBlocking(), blockStore: blockStore, blockLog: log)
        }
        let m = make()
        let before = try #require(m.periodBests()[.month]?.points)
        m.setSleepSetting(startMinutes: 2 * 60, endMinutes: 4 * 60)
        let after = try #require(m.periodBests()[.month]?.points)
        #expect(!after.isApprox(before))
        #expect(try #require(make().periodBests()[.month]?.points).isApprox(after))
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
        let rows = BestLaps.make(today: mine, todayStart: today, now: jst("2026-10-22T11:00"), theirs: { theirs(best.addingTimeInterval($0)) })
        // どちらも0の区間（4:00–8:00、12:00–14:00 など）は省く
        #expect(rows.map(\.section.start) == [jst("2026-10-22T08:00"), jst("2026-10-22T10:00"), jst("2026-10-22T14:00")])
        let first = rows[0]
        #expect(first.today?.isApprox(6) == true)
        #expect(first.todayTotal?.isApprox(6) == true)
        #expect(first.theirs.isApprox(10))
        #expect(first.theirsTotal.isApprox(10))
        #expect(!first.isCurrent)
        // 今の区間：ベストの日も 11:00 まで（12pt のうち 6pt）
        let current = rows[1]
        #expect(current.isCurrent)
        #expect(current.today?.isApprox(6) == true)
        #expect(current.todayTotal?.isApprox(12) == true)
        #expect(current.theirs.isApprox(6))
        #expect(current.theirsTotal.isApprox(16))
        #expect(current.totalGap?.isApprox(-4) == true)
        // まだ来ていない区間：今日は空、ベストの日は区間の全部
        let future = rows[2]
        #expect(future.today == nil)
        #expect(future.todayTotal == nil)
        #expect(future.totalGap == nil)
        #expect(future.theirs.isApprox(5))
        #expect(future.theirsTotal.isApprox(27))
    }

    /// 今がちょうど区間の始まりなら、その区間はまだ来ていない。今日だけ・ベストの日だけに点がある区間は残す
    @Test func lapRowsAtSectionStartAndOneSided() {
        let today = jst("2026-10-22T04:00")
        let best = jst("2026-10-13T04:00")
        // 今日は 6:00〜8:00 に 4pt、ベストの日は 8:00〜10:00 に 4pt
        func mine(_ date: Date) -> Double { min(max(date.timeIntervalSince(today) / 3600 - 2, 0), 2) * 2 }
        func theirs(_ date: Date) -> Double { min(max(date.timeIntervalSince(best) / 3600 - 4, 0), 2) * 2 }
        let rows = BestLaps.make(today: mine, todayStart: today, now: jst("2026-10-22T10:00"), theirs: { theirs(best.addingTimeInterval($0)) })
        #expect(rows.map(\.section.start) == [jst("2026-10-22T06:00"), jst("2026-10-22T08:00")])
        #expect(rows[0].todayWins && rows[0].totalWins)
        #expect(rows[1].today?.isApprox(0) == true)
        #expect(!rows[1].todayWins && !rows[1].isCurrent)
        #expect(rows[1].totalGap?.isApprox(0) == true)
        let atStart = BestLaps.make(today: mine, todayStart: today, now: jst("2026-10-22T08:00"), theirs: { theirs(best.addingTimeInterval($0)) })
        #expect(atStart[1].today == nil)
        #expect(!atStart[1].todayWins && !atStart[1].totalWins)
        // 4:00 ちょうどは、どの区間もまだ来ていない
        let dawn = BestLaps.make(today: mine, todayStart: today, now: today, theirs: { theirs(best.addingTimeInterval($0)) })
        #expect(dawn.allSatisfy { $0.today == nil })
    }

    /// 赤と差は、表に出る数字（0.1pt）で決める。12.04 と 11.96 はどちらも 12.0 なので、赤にせず差も 0
    @Test func winsAndGapUseTheShownValues() {
        let section = DateInterval(start: jst("2026-10-22T08:00"), duration: Laps.length)
        let row = BestLapRow(section: section, today: 2.04, todayTotal: 12.04, theirs: 1.96, theirsTotal: 11.96, isCurrent: false)
        #expect(!row.todayWins && !row.totalWins)
        #expect(row.totalGap == 0)
        let ahead = BestLapRow(section: section, today: 2.06, todayTotal: 12.06, theirs: 2.0, theirsTotal: 11.96, isCurrent: false)
        #expect(ahead.todayWins && ahead.totalWins)
        #expect(ahead.totalGap?.isApprox(0.1) == true)
        let comparison = BestComparison(today: 10.04, theirsAtSameTime: 9.96, rows: [])
        #expect(!comparison.wins)
        #expect(comparison.gap == 0)
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
        let best = try #require(m.periodBests()[.month])
        let comparison = try #require(m.lapComparison(target: .bestDay, period: .month))
        let todaySnapshot = try #require(m.daySnapshot(daysAgo: 0))
        let bestSnapshot = try #require(m.daySnapshot(of: best.pointsDay))
        #expect(comparison.today.isApprox(todaySnapshot.points))
        #expect(comparison.theirsAtSameTime.isApprox(bestSnapshot.myPoints(until: jst("2026-10-13T12:00"))))
        #expect(comparison.rows.contains { $0.section.start == jst("2026-10-22T14:00") && $0.today == nil })
    }

    // MARK: ラップ表の相手・理論ベスト・ベスト10（ANA-06・09・11）

    /// 平均：期間の記録のある日の、その時刻までの平均。最後の累計は期間の1日の平均。ほかの期間の日は入らない
    @Test func lapComparisonAgainstTheAverage() throws {
        let t = try TestStore(now: jst("2026-10-22T12:00"))
        try t.seeded()
        try record(t, "2026-10-13T09:00", "2026-10-13T13:00")  // 先週（今週には入らない）
        try record(t, "2026-10-20T09:00", "2026-10-20T10:00")
        try record(t, "2026-10-21T09:00", "2026-10-21T10:00")
        try record(t, "2026-10-21T13:00", "2026-10-21T14:00")
        try record(t, "2026-10-22T08:00", "2026-10-22T09:00")  // 今日（入らない）
        let m = model(t)
        let tue = try #require(m.daySnapshot(of: jst("2026-10-20T04:00")))
        let wed = try #require(m.daySnapshot(of: jst("2026-10-21T04:00")))
        let comparison = try #require(m.lapComparison(target: .average, period: .week))
        #expect(comparison.days == 2)
        let todaySnapshot = try #require(m.daySnapshot(daysAgo: 0))
        #expect(comparison.today.isApprox(todaySnapshot.points))
        let noon = (tue.myPoints(until: jst("2026-10-20T12:00")) + wed.myPoints(until: jst("2026-10-21T12:00"))) / 2
        #expect(comparison.theirsAtSameTime.isApprox(noon))
        // 12:00–14:00 はまだ来ていない区間：相手は区間の全部。最後の累計は1日の平均
        let last = try #require(comparison.rows.last)
        #expect(last.section.start == jst("2026-10-22T12:00"))
        #expect(last.today == nil)
        #expect(last.theirsTotal.isApprox((tue.points + wed.points) / 2))
        #expect(last.theirs.isApprox((wed.points - wed.myPoints(until: jst("2026-10-21T12:00"))) / 2))
    }

    /// 1日なら平均はその日。期間に記録のある日がなければ、どの相手も理論ベストもベスト10も出さない
    @Test func averageOfOneDayAndNoDays() throws {
        let t = try TestStore(now: jst("2026-10-19T12:00"))  // 月曜
        try t.seeded()
        try record(t, "2026-10-18T09:00", "2026-10-18T10:00")
        let m = model(t)
        for target in LapTarget.allCases {
            #expect(m.lapComparison(target: target, period: .week) == nil)
        }
        #expect(m.theoreticalBest(period: .week) == nil)
        #expect(m.topDays(period: .week).isEmpty)
        let one = try #require(m.lapComparison(target: .average, period: .month))
        #expect(one.days == 1)
        let sunday = try #require(m.daySnapshot(of: jst("2026-10-18T04:00")))
        #expect(one.theirsAtSameTime.isApprox(sunday.myPoints(until: jst("2026-10-18T12:00"))))
        let lastRow = try #require(one.rows.last)
        #expect(lastRow.theirsTotal.isApprox(sunday.points))
    }

    /// 区間ベストをつないだ1日：起きている区間は区間ベスト、睡眠の区間（今の設定 0:00–7:00 で 4:00–8:00 と 翌0:00–4:00）は平均。
    /// 最後の累計＝理論ベスト。3:59 までの集中は前の日、4:00 からはその日の区間
    @Test func sectionBestAndTheoreticalBest() throws {
        let t = try TestStore(now: jst("2026-10-22T12:00"))
        try t.seeded()
        try record(t, "2026-10-20T09:00", "2026-10-20T10:00")  // 火曜 8:00–10:00 に 6
        try record(t, "2026-10-21T01:00", "2026-10-21T02:00")  // 火曜の 翌0:00–2:00 に 6（睡眠の区間）
        try record(t, "2026-10-21T03:00", "2026-10-21T03:59")  // 火曜の 翌2:00–4:00 に 5.9（睡眠の区間）
        try record(t, "2026-10-21T04:00", "2026-10-21T04:30")  // 水曜の 4:00–6:00 に 3（睡眠の区間）
        try record(t, "2026-10-21T10:00", "2026-10-21T11:00")  // 水曜 10:00–12:00 に 6
        let m = model(t)
        // 6 ＋ 6 ＋ 睡眠の区間は平均（3 ＋ 2.95 ＋ 1.5）
        let theoretical = try #require(m.theoreticalBest(period: .week))
        #expect(theoretical.isApprox(19.45))
        let comparison = try #require(m.lapComparison(target: .sectionBest, period: .week))
        let lastRow = try #require(comparison.rows.last)
        #expect(lastRow.theirsTotal.isApprox(theoretical))
        // ★の記録は睡眠の区間でも区間ベスト（数え直す前）
        let night = try #require(comparison.rows.first { $0.section.start == jst("2026-10-23T02:00") })
        #expect(night.record?.isApprox(5.9) == true)
        #expect(night.theirs.isApprox(2.95))
        let dawn = try #require(comparison.rows.first { $0.section.start == jst("2026-10-22T04:00") })
        #expect(dawn.record?.isApprox(3) == true)
        #expect(dawn.theirs.isApprox(1.5))
        // 今日の行も区間ベストの1日の同じ時刻まで（12:00 なら 1.5 ＋ 6 ＋ 6）
        #expect(comparison.theirsAtSameTime.isApprox(13.5))
    }

    /// ★：今日の区間が区間ベストを超えたら（相手がベストの日でも）。今の区間は今まで
    @Test func goldMarksInTheTable() throws {
        let t = try TestStore(now: jst("2026-10-22T11:00"))
        try t.seeded()
        try record(t, "2026-10-20T08:00", "2026-10-20T09:00")  // 8:00–10:00 の区間ベスト 6
        try record(t, "2026-10-22T08:00", "2026-10-22T09:10")  // 7
        try record(t, "2026-10-22T10:00", "2026-10-22T11:00")  // 今の区間で 6（区間ベストは 0）
        let m = model(t)
        let rows = try #require(m.lapComparison(target: .bestDay, period: .week)).rows
        let eight = try #require(rows.first { $0.section.start == jst("2026-10-22T08:00") })
        #expect(eight.gold && eight.todayWins)
        let current = try #require(rows.first { $0.isCurrent })
        #expect(current.section.start == jst("2026-10-22T10:00"))
        #expect(current.gold)
    }

    /// ★は相手が平均・区間ベストでも同じ区間に付く。夜（睡眠の区間）でも付く
    @Test func goldMarksForEveryTargetAndAtNight() throws {
        let t = try TestStore(now: jst("2026-10-23T02:30"))  // まだ 10/22
        try t.seeded()
        try record(t, "2026-10-20T08:00", "2026-10-20T09:00")
        try record(t, "2026-10-21T00:30", "2026-10-21T01:00")  // 10/20 の 翌0:00–2:00 に 3
        try record(t, "2026-10-22T08:00", "2026-10-22T09:10")  // 7
        try record(t, "2026-10-23T00:00", "2026-10-23T01:00")  // 夜の区間で 6
        let m = model(t)
        for target in LapTarget.allCases {
            let rows = try #require(m.lapComparison(target: target, period: .week)).rows
            #expect(rows.filter(\.gold).map(\.section.start) == [jst("2026-10-22T08:00"), jst("2026-10-23T00:00")])
        }
    }

    /// 今の区間で開けた時間が入って値が下がると、★は消える
    @Test func goldDisappearsWhenOpenedTimeLowersTheSection() throws {
        let t = try TestStore(now: jst("2026-10-22T11:50"))
        try t.seeded()
        try record(t, "2026-10-20T13:00", "2026-10-20T14:00")  // 10:00–12:00 は集中なし（ブロック中の点だけ）
        try record(t, "2026-10-22T10:00", "2026-10-22T11:50")
        let log = MemoryBlockEventLog()
        try log.append(BlockEvent(occurredAt: jst("2026-10-01T04:00"), timeZoneId: "Asia/Tokyo", kind: .started))
        let settings = MemorySettings()
        settings.didShowBlockingIntro = true
        settings.didLogBlockStart = true
        settings.lastBlockingAuthorized = true
        let blockStore = MemoryBlockStore()
        blockStore.state = BlockState(isEnabled: true)
        blockStore.selection = Data("sel".utf8)
        let m = AppModel(store: t.store, clock: t.clock, timeZone: { tokyo }, settings: settings,
                         blocking: FakeBlocking(), blockStore: blockStore, blockLog: log)
        func current() throws -> BestLapRow {
            try #require(m.lapComparison(target: .bestDay, period: .week)?.rows.first { $0.isCurrent })
        }
        // 110分の集中で 10.5、区間ベストはブロック中の 6
        #expect(try current().gold)
        // 10:10–11:10 に開けていた（その間は0点）
        try log.append(BlockEvent(occurredAt: jst("2026-10-22T10:10"), timeZoneId: "Asia/Tokyo", kind: .unlocked, unlockMinutes: 60))
        try log.append(BlockEvent(occurredAt: jst("2026-10-22T11:10"), timeZoneId: "Asia/Tokyo", kind: .reblocked))
        let lowered = try current()
        #expect(!lowered.gold)
        #expect(try #require(lowered.today) < 6)
    }

    /// ベスト10の件数：ちょうど10日なら10件、9日なら9件、期間に1日なら1件
    @Test func topDaysCount() throws {
        let t = try TestStore(now: jst("2026-10-20T12:00"))  // 火曜。今週は月曜の1日だけ
        try t.seeded()
        for day in 11...19 {  // 9日
            try record(t, "2026-10-\(day)T09:00", "2026-10-\(day)T10:00")
        }
        let m = model(t)
        #expect(m.topDays(period: .all).count == 9)
        #expect(m.topDays(period: .week).map(\.dayStart) == [jst("2026-10-19T04:00")])
        try record(t, "2026-10-10T09:00", "2026-10-10T10:00")
        #expect(m.topDays(period: .all).count == 10)
        try record(t, "2026-10-09T09:00", "2026-10-09T10:00")
        #expect(m.topDays(period: .all).count == 10)
    }

    /// ベスト10：期間の記録のある日の上位10日。同じなら新しい日が上。今日は入れない
    @Test func topTenDays() throws {
        let t = try TestStore(now: jst("2026-10-22T12:00"))
        try t.seeded()
        // 10/10 から 10/21 まで、10分ずつ長く。10/21 は 10/20 と同じ
        for i in 0..<12 {
            let minutes = i == 11 ? 110 : 10 * (i + 1)
            let day = String(format: "2026-10-%02d", 10 + i)
            try record(t, "\(day)T09:00", String(format: "\(day)T%02d:%02d", 9 + minutes / 60, minutes % 60))
        }
        try record(t, "2026-10-22T05:00", "2026-10-22T11:00")  // 今日
        let m = model(t)
        let top = m.topDays(period: .all)
        #expect(top.map(\.dayStart) == [21, 20, 19, 18, 17, 16, 15, 14, 13, 12].map {
            jst(String(format: "2026-10-%02dT04:00", $0))
        })
        #expect(top[0].points == top[1].points)
        #expect(m.topDays(period: .week).map(\.dayStart) == [21, 20, 19].map { jst("2026-10-\($0)T04:00") })
    }

    /// 過ぎた日を覚えていても、記録を足したら平均を数え直す
    @Test func averageRecountsAfterNewRecords() throws {
        let t = try TestStore(now: jst("2026-10-22T12:00"))
        try t.seeded()
        try record(t, "2026-10-20T09:00", "2026-10-20T10:00")
        try record(t, "2026-10-21T09:00", "2026-10-21T10:00")
        let m = model(t)
        let before = try #require(m.lapComparison(target: .average, period: .week)?.rows.last).theirsTotal
        try record(t, "2026-10-20T13:00", "2026-10-20T14:00")
        let after = try #require(m.lapComparison(target: .average, period: .week)?.rows.last).theirsTotal
        #expect(after.isApprox(before + 3))
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

    /// 一番古い記録の日が期間の最初の日ならそこで止まり、1日前ならもう1期間さかのぼれる
    @Test func canGoBackBoundary() throws {
        let t = try TestStore(now: jst("2026-10-19T12:00"))
        try t.seeded()
        let m = model(t)
        try record(t, "2026-10-06T09:00", "2026-10-06T10:00")  // 7日の page 1（10/6〜10/12）の最初の日
        #expect(m.canGoBack(days: 7, page: 0))
        #expect(!m.canGoBack(days: 7, page: 1))
        try record(t, "2026-10-05T09:00", "2026-10-05T10:00")
        #expect(m.canGoBack(days: 7, page: 1))
        #expect(!m.canGoBack(days: 7, page: 2))
        // 30日：page 0 は 9/20〜10/19。9/19 なら page 1 へ行ける
        #expect(!m.canGoBack(days: 30, page: 0))
        try record(t, "2026-09-19T09:00", "2026-09-19T10:00")
        #expect(m.canGoBack(days: 30, page: 0))
        #expect(!m.canGoBack(days: 30, page: 1))
    }
}
