import Foundation
import Testing
@testable import FocusApp

/// 時間の格子（PLN-10、docs/product/features/daily-plan.md「時間の格子」）
struct PlanGridTests {
    private let dayStart = jst("2026-10-19T04:00")
    private let study = CategoryOption(id: UUID(), name: "勉強", countsAsFocus: true)
    private var layout: PlanGridLayout { PlanGridLayout(dayStart: dayStart, hourHeight: 60) }

    private func block(_ time: String, _ minutes: Int, day: String = "2026-10-19") -> PlanBlockDraft {
        PlanBlockDraft(start: jst("\(day)T\(time)"), minutes: minutes, category: study)
    }

    @Test func positionsFromFourAm() {
        #expect(layout.y(for: jst("2026-10-19T04:00")) == 0)
        #expect(layout.y(for: jst("2026-10-19T09:30")) == 330)
        #expect(layout.y(for: jst("2026-10-20T03:59")) == 1439)
        #expect(layout.totalHeight == 1440)
        #expect(layout.height(minutes: 90) == 90)
    }

    @Test func movingSnapsTheStartToHalfHours() {
        let b = block("09:10", 45)
        // 9:10 から 20分下へ → 9:30
        #expect(layout.moved(b, by: 20).start == jst("2026-10-19T09:30"))
        // 14分下 → 9:24 → 近い 9:30
        #expect(layout.moved(b, by: 14).start == jst("2026-10-19T09:30"))
        // 14分上 → 8:56 → 9:00
        #expect(layout.moved(b, by: -14).start == jst("2026-10-19T09:00"))
        #expect(layout.moved(b, by: 20).minutes == 45)
    }

    @Test func movingStaysInsideTheDay() {
        #expect(layout.moved(block("05:00", 60), by: -180).start == jst("2026-10-19T04:00"))
        // 終わりが翌4:00 を越えないところまで
        #expect(layout.moved(block("23:00", 90), by: 600).start == jst("2026-10-20T02:30"))
    }

    @Test func resizingSnapsTheEnd() {
        let b = block("09:00", 45)
        // 9:45 の終わりを 10分下 → 9:55 → 10:00
        #expect(layout.resized(b, by: 10).minutes == 60)
        // 上へ縮めても5分より短くしない（最初の :30 は 9:30 → 30分）
        #expect(layout.resized(b, by: -30).minutes == 30)
        #expect(layout.resized(block("09:00", 30), by: -60).minutes == 30)
        let odd = block("09:10", 15)
        // 9:10 開始で上へ縮めると、開始より後の最初の :30（9:30）まで
        #expect(layout.resized(odd, by: -60).minutes == 20)
        // 3時間まで
        #expect(layout.resized(b, by: 600).minutes == 180)
        // 翌4:00 まで
        #expect(layout.resized(block("03:00", 30, day: "2026-10-20"), by: 120).minutes == 60)
    }

    @Test func gameTimeKeepsItsLength() {
        let game = PlanBlockDraft.unblock(start: jst("2026-10-19T20:00"))
        #expect(layout.resized(game, by: 60).minutes == 30)
        #expect(!PlanGridLayout.canResize(game))
        #expect(PlanGridLayout.canResize(block("09:00", 60)))
    }

    @Test func tappingAnEmptyPlaceStartsAtTheHalfHourBelow() {
        #expect(layout.tapStart(y: 330 + 29) == jst("2026-10-19T09:30"))
        #expect(layout.tapStart(y: 330 - 1) == jst("2026-10-19T09:00"))
        // 最後の30分より下でも 3:30 まで
        #expect(layout.tapStart(y: 1500) == jst("2026-10-20T03:30"))
        #expect(layout.tapStart(y: -10) == jst("2026-10-19T04:00"))
    }

    @Test func confirmedDayLocksStartedBlocks() {
        let now = jst("2026-10-19T11:00")
        #expect(!PlanGridLayout.canMove(block("10:30", 60), confirmedDay: true, now: now))
        #expect(!PlanGridLayout.canMove(block("09:00", 60), confirmedDay: true, now: now))
        #expect(PlanGridLayout.canMove(block("11:30", 60), confirmedDay: true, now: now))
        // 下書き（朝・明日）は全部動かせる
        #expect(PlanGridLayout.canMove(block("09:00", 60), confirmedDay: false, now: now))
    }

    @Test func droppingOnAnotherBlockIsRefused() {
        let a = block("09:00", 60), b = block("11:00", 60)
        let plan = PlanDraft(blocks: [a, b])
        let moved = layout.moved(a, by: 120)
        #expect(plan.problem(with: moved, dayStart: dayStart) != nil)
        #expect(plan.problem(with: layout.moved(a, by: 60), dayStart: dayStart) == nil)
    }

    @Test func voiceOverMovesByHalfAnHour() {
        let b = block("09:10", 60)
        #expect(layout.shifted(b, minutes: 30).start == jst("2026-10-19T09:40"))
        #expect(layout.shifted(b, minutes: -30).start == jst("2026-10-19T08:40"))
        #expect(layout.shifted(block("04:10", 60), minutes: -30).start == jst("2026-10-19T04:00"))
    }

    @Test func awakeRangeComesFromSleep() {
        let range = PlanGridLayout.awake(wake: jst("2026-10-19T07:05"), bed: jst("2026-10-20T00:30"), dayStart: dayStart)
        #expect(range.lowerBound == jst("2026-10-19T07:05"))
        #expect(range.upperBound == jst("2026-10-20T00:30"))
        // 寝る時刻が起きた時刻より前なら1日全部
        let broken = PlanGridLayout.awake(wake: jst("2026-10-19T09:00"), bed: jst("2026-10-19T08:00"), dayStart: dayStart)
        #expect(broken == dayStart...jst("2026-10-20T04:00"))
    }

    @Test func blocksLockFromTheMomentTheyStart() {
        let now = jst("2026-10-19T11:00")
        #expect(!PlanGridLayout.canMove(block("11:00", 60), confirmedDay: true, now: now))
        #expect(PlanGridLayout.canMove(block("11:05", 60), confirmedDay: true, now: now))
    }

    @Test func gameTimeMovesInHalfHoursAndIsRefusedOnAnotherGameTime() {
        let first = PlanBlockDraft.unblock(start: jst("2026-10-19T20:00"))
        let second = PlanBlockDraft.unblock(start: jst("2026-10-19T21:00"))
        let moved = layout.moved(first, by: 40)
        #expect(moved.start == jst("2026-10-19T20:30"))
        #expect(moved.minutes == 30)
        let plan = PlanDraft(blocks: [first, second])
        #expect(plan.problem(with: layout.moved(first, by: 60), dayStart: dayStart) != nil)
        // 最後の30分（翌3:30）より下へは行かない
        #expect(layout.moved(first, by: 1000).start == jst("2026-10-20T03:30"))
    }

    @Test func lateNightBlocksStayInsideTheDay() {
        // 0:00〜3:59 は前の日（4:00 区切り）の格子の下の端
        let late = block("01:00", 90, day: "2026-10-20")
        #expect(layout.y(for: late.start) == 1260)
        #expect(layout.moved(late, by: 120).start == jst("2026-10-20T02:30"))
        #expect(layout.resized(late, by: 120).minutes == 180)
        #expect(layout.resized(block("03:00", 30, day: "2026-10-20"), by: 600).end == jst("2026-10-20T04:00"))
        // VoiceOver の「30分遅く」も翌4:00 で止まる
        #expect(layout.shifted(block("03:30", 30, day: "2026-10-20"), minutes: 30).start == jst("2026-10-20T03:30"))
    }

    @Test func threeHourBlockDoesNotGrow() {
        #expect(layout.resized(block("09:00", 180), by: 60).minutes == 180)
        #expect(layout.resized(block("09:00", 180), by: -60).minutes == 120)
    }

    @Test func openingPosition() {
        let wake = jst("2026-10-19T07:05")
        // 朝・明日（下書き）は起きた時刻、計画のタブは今の1時間前
        #expect(PlanGridLayout.initialHour(confirmedDay: false, now: jst("2026-10-19T15:00"), wake: wake, dayStart: dayStart) == 3)
        #expect(PlanGridLayout.initialHour(confirmedDay: true, now: jst("2026-10-19T15:00"), wake: wake, dayStart: dayStart) == 10)
        // 4:00 すぐ・3:59 は端に収める
        #expect(PlanGridLayout.initialHour(confirmedDay: true, now: jst("2026-10-19T04:10"), wake: wake, dayStart: dayStart) == 0)
        #expect(PlanGridLayout.initialHour(confirmedDay: true, now: jst("2026-10-20T03:59"), wake: wake, dayStart: dayStart) == 22)
    }
}

/// 起きている時間（格子の灰色、PLN-10）を本体から求める
@MainActor
struct PlanGridAwakeTests {
    private func model(_ t: TestStore, source: NoSleepSource = NoSleepSource()) -> AppModel {
        AppModel(store: t.store, clock: t.clock, timeZone: { tokyo }, settings: MemorySettings(), sleepSource: source)
    }

    @Test func wakeComesFromTheDaysSleepAndBedFromTonightsSetting() async throws {
        let t = try TestStore(now: jst("2026-10-19T07:30"))
        try t.seeded()
        let m = model(t, source: NoSleepSource(isAvailable: true,
                                                intervals: [DateInterval(start: jst("2026-10-19T00:10"), end: jst("2026-10-19T07:05"))]))
        await m.refreshSleep()
        m.setSleepSetting(startMinutes: 23 * 60 + 30, endMinutes: 7 * 60)
        let range = m.awakeRange(dayStart: jst("2026-10-19T04:00"))
        #expect(range.lowerBound == jst("2026-10-19T07:05"))
        #expect(range.upperBound == jst("2026-10-19T23:30"))
    }

    @Test func settingTimesWhenThereIsNoSleepForTheDay() throws {
        let t = try TestStore(now: jst("2026-10-19T07:30"))
        try t.seeded()
        let m = model(t)
        // 明日の計画（まだ睡眠を保存していない日）は設定の時刻（初期 0:00〜7:00）
        let range = m.awakeRange(dayStart: jst("2026-10-20T04:00"))
        #expect(range.lowerBound == jst("2026-10-20T07:00"))
        #expect(range.upperBound == jst("2026-10-21T00:00"))
    }

    @Test func bedAfterTheDayEndStopsAtFourAm() throws {
        let t = try TestStore(now: jst("2026-10-19T07:30"))
        try t.seeded()
        let m = model(t)
        // 寝る 6:00・起きる 7:00（朝に寝る人）→ 寝る時刻は翌4:00 より後なので、格子の終わり（翌4:00）まで起きている
        m.setSleepSetting(startMinutes: 6 * 60, endMinutes: 7 * 60)
        let range = m.awakeRange(dayStart: jst("2026-10-20T04:00"))
        #expect(range == jst("2026-10-20T07:00")...jst("2026-10-21T04:00"))
    }
}
