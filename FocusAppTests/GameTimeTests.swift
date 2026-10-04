import Foundation
import Testing
@testable import FocusApp

/// ゲーム・SNS の時間（BLK-10・BLK-11・BLK-12、app-blocking.md「ゲーム・SNS の時間」「今かかるブロック」）。
struct GameTimePlanTests {
    private let c = DefaultCategories.all
    private let dayStart = jst("2026-10-19T04:00")

    private func block(_ start: String, _ minutes: Int, _ category: CategoryOption) -> PlanBlockDraft {
        PlanBlockDraft(start: jst("2026-10-19T" + start), minutes: minutes, category: category)
    }

    private func game(_ start: String) -> PlanBlockDraft { .unblock(start: jst("2026-10-19T" + start)) }

    // MARK: 計画

    @Test func gameTimeIsThirtyMinutesAndNotInTotals() {
        let plan = PlanDraft(blocks: [block("09:00", 60, c[0]), block("16:00", 60, c[5]), game("20:00")])
        #expect(game("20:00").minutes == 30)
        #expect(plan.focusSeconds == 60 * 60)
        #expect(plan.detoxSeconds == 60 * 60)
        #expect(plan.unblockCount == 1)
        #expect(plan.remainingUnblocks == 2)
    }

    @Test func atMostThreePerDayButAdjacentIsFine() {
        let plan = PlanDraft(blocks: [game("20:00"), game("20:30"), game("21:00")])
        #expect(plan.problem(with: plan.blocks[0], dayStart: dayStart) == nil)
        #expect(plan.problem(with: game("22:00"), dayStart: dayStart) == "ゲーム・SNS の時間は1日3つまでです")
        // ほかのブロックと同じく重ねられない
        let two = PlanDraft(blocks: [game("20:00")])
        #expect(two.problem(with: game("20:15"), dayStart: dayStart)?.contains("重なっています") == true)
        #expect(two.problem(with: game("20:30"), dayStart: dayStart) == nil)
    }

    @Test func carriedTimesMoveToTheNextDay() {
        let yesterday = jst("2026-10-18T04:00")
        let previous = [PlanBlockDraft(start: jst("2026-10-18T20:00"), minutes: 30, category: .gameSNS),
                        PlanBlockDraft(start: jst("2026-10-19T00:30"), minutes: 30, category: .gameSNS),
                        PlanBlockDraft(start: jst("2026-10-18T09:00"), minutes: 60, category: c[0])]
        let carried = PlanDraft.carriedUnblocks(previous, previousDayStart: yesterday, dayStart: dayStart, calendar: tokyoCalendar)
        #expect(carried.map(\.start) == [jst("2026-10-19T20:00"), jst("2026-10-20T00:30")])
        #expect(carried.allSatisfy { $0.isUnblock && $0.minutes == 30 })
    }

    /// 日中のテンプレートは、ゲーム・SNS の時間もテンプレートのものになる（2026-10-02 オーナー決定）
    @Test func replacingFutureUsesTemplateGameTimes() {
        let plan = PlanDraft(blocks: [game("08:00"), game("20:00")])
        let template = PlanDraft(blocks: [block("13:00", 60, c[0]), game("21:00")])
        let result = plan.replacingFuture(with: template, now: jst("2026-10-19T12:00"))
        #expect(result.sortedBlocks.map(\.start) == [jst("2026-10-19T08:00"), jst("2026-10-19T13:00"), jst("2026-10-19T21:00")])
    }

    @Test func endingOngoingGameTimeKeepsTheUsedPart() {
        var plan = PlanDraft(blocks: [game("20:00")])
        plan.endUnblock(id: plan.blocks[0].id, now: jst("2026-10-19T20:12:40"))
        #expect(plan.blocks.first?.minutes == 12)
        var justStarted = PlanDraft(blocks: [game("20:00")])
        justStarted.endUnblock(id: justStarted.blocks[0].id, now: jst("2026-10-19T20:00:30"))
        #expect(justStarted.blocks.isEmpty)
    }

    @Test func phases() {
        let now = jst("2026-10-19T20:10")
        #expect(PlanDraft.unblockPhase(game("19:00"), now: now) == .past)
        #expect(PlanDraft.unblockPhase(game("20:00"), now: now) == .ongoing)
        #expect(PlanDraft.unblockPhase(game("21:00"), now: now) == .upcoming)
    }


    // MARK: 確定したあとの変更（BD-10）

    @Test func deleteFollowsThePhaseOnConfirmedDay() {
        let now = jst("2026-10-19T20:10")
        var plan = PlanDraft(blocks: [game("19:00"), game("20:00"), game("21:00"), block("22:00", 30, c[0])])
        let ids = plan.sortedBlocks.map(\.id)
        plan.delete(id: ids[0], confirmedDay: true, now: now)   // 終わった：消さない
        plan.delete(id: ids[1], confirmedDay: true, now: now)   // 今：今で終える
        plan.delete(id: ids[2], confirmedDay: true, now: now)   // まだ：消す
        plan.delete(id: ids[3], confirmedDay: true, now: now)   // ほかのブロック：消す
        #expect(plan.sortedBlocks.map(\.start) == [jst("2026-10-19T19:00"), jst("2026-10-19T20:00")])
        #expect(plan.sortedBlocks.map(\.minutes) == [30, 10])
    }

    @Test func draftDayDeletesAnything() {
        var plan = PlanDraft(blocks: [game("08:00")])
        plan.delete(id: plan.blocks[0].id, confirmedDay: false, now: jst("2026-10-19T20:00"))
        #expect(plan.blocks.isEmpty)
    }

    @Test func phaseBoundaries() {
        #expect(PlanDraft.unblockPhase(game("20:00"), now: jst("2026-10-19T20:00")) == .ongoing)
        #expect(PlanDraft.unblockPhase(game("20:00"), now: jst("2026-10-19T20:30")) == .past)
        #expect(PlanDraft.isLocked(game("19:00"), confirmedDay: true, now: jst("2026-10-19T20:00")))
        #expect(!PlanDraft.isLocked(game("19:00"), confirmedDay: false, now: jst("2026-10-19T20:00")))
        #expect(!PlanDraft.isLocked(block("09:00", 60, c[0]), confirmedDay: true, now: jst("2026-10-19T20:00")))
        #expect(PlanDraft.isOngoing(game("20:00"), confirmedDay: true, now: jst("2026-10-19T20:10")))
    }



    @Test func gameTimeCannotCrossFourAm() {
        let plan = PlanDraft()
        let late = PlanBlockDraft.unblock(start: jst("2026-10-20T03:45"))
        #expect(plan.problem(with: late, dayStart: dayStart) == "1日の区切り（朝4:00）をまたいでいます")
        #expect(plan.problem(with: .unblock(start: jst("2026-10-20T03:30")), dayStart: dayStart) == nil)
    }

    @Test func replacingFutureKeepsStartedAndCapsAtThree() {
        let plan = PlanDraft(blocks: [game("12:00"), game("12:30"), game("20:00")])
        let template = PlanDraft(blocks: [game("08:00"), game("13:00"), game("21:00"), game("22:00")])
        let result = plan.replacingFuture(with: template, now: jst("2026-10-19T12:40"))
        // 始まった2つは残り、まだの 20:00 は外れる。今より前の 08:00 は入らない。3つまでなので 13:00 だけ入る
        #expect(result.sortedBlocks.map(\.start) == [jst("2026-10-19T12:00"), jst("2026-10-19T12:30"), jst("2026-10-19T13:00")])
        let empty = plan.replacingFuture(with: PlanDraft(), now: jst("2026-10-19T12:40"))
        #expect(empty.unblockCount == 2)
    }

    // MARK: ほかの計算に入れない

    @Test func goalGhostDoesNotUseGameTimeAsFreeTime() {
        // 9:00–10:00 勉強、12:00–12:30 ゲーム、14:00–15:00 勉強、20:00 ゲーム。目標は計画より1時間多い。7:00 起き・0:00 寝
        let plan = PlanDraft(blocks: [block("09:00", 60, c[0]), game("12:00"), block("14:00", 60, c[0]), game("20:00")])
        let sleep = [DateInterval(start: jst("2026-10-19T00:00"), end: jst("2026-10-19T07:00")),
                     DateInterval(start: jst("2026-10-20T00:00"), end: jst("2026-10-20T07:00"))]
        let ghost = GoalGhost(plan: plan, goalSeconds: 3 * 3600, sleep: sleep, dayStart: dayStart, calendar: tokyoCalendar)
        // ゲームの30分には足さない
        let during = ghost.focusSeconds(at: jst("2026-10-19T12:30")) - ghost.focusSeconds(at: jst("2026-10-19T12:00"))
        #expect(during == 0)
        let evening = ghost.focusSeconds(at: jst("2026-10-19T20:30")) - ghost.focusSeconds(at: jst("2026-10-19T20:00"))
        #expect(evening == 0)
        // 空き時間は起きている時間からゲームと計画を除いた 14時間。寝る 0:00 に目標に届く
        #expect(ghost.focusSeconds(at: jst("2026-10-19T15:00")) < 3 * 3600)
        #expect(ghost.focusSeconds(at: jst("2026-10-20T00:00")) == 3 * 3600)
    }

    @Test func reviewGapsSkipGameTime() {
        let gameBlock = PlanSnapshotBlock(blockId: UUID(), startAt: jst("2026-10-19T20:00"), endAt: jst("2026-10-19T20:30"),
                                          categoryId: CategoryOption.gameSNS.id, categoryName: "ゲーム・SNS",
                                          projectId: nil, projectName: nil)
        #expect(ReviewGaps.largest(snapshot: [gameBlock], sessions: [], now: jst("2026-10-19T22:00")).isEmpty)
    }

    @Test func timelineHasNoAchievementForGameTime() {
        let summary = PlanDraft(blocks: [game("09:00")]).summaries[0]
        let day = TimelineDay(dayKey: "2026-10-19", dayStart: dayStart, now: jst("2026-10-19T12:00"), isToday: true,
                              planBlocks: [summary], isNoPlanDay: false, sessions: [],
                              editableDayKeys: ["2026-10-19"])
        #expect(day.achievementPercent(of: summary) == nil)
    }
}

/// 決定表とスケジュール（本体と拡張で共有）。
struct GameTimePolicyTests {
    private let windows = [UnblockWindow(start: jst("2026-10-19T20:00"), end: jst("2026-10-19T21:00"))]

    private func state(focus: Bool = false, unlocked: Bool = false) -> BlockState {
        BlockState(isEnabled: true, unlockedUntil: unlocked ? jst("2026-10-19T20:40") : nil, isFocusBlocking: focus,
                   unblockWindows: windows)
    }

    @Test(arguments: [
        // 時刻, 集中中, 開けている → いつもの, 全部
        ("2026-10-19T19:59", false, false, true, false),
        ("2026-10-19T20:00", false, false, false, false),
        ("2026-10-19T20:30", true, false, true, true),
        ("2026-10-19T20:30", false, true, false, false),
        ("2026-10-19T21:00", false, false, true, false),
    ])
    func decisionTableWithGameTime(time: String, focus: Bool, unlocked: Bool, usual: Bool, focusOn: Bool) {
        let plan = BlockPolicy.shields(state(focus: focus, unlocked: unlocked), hasSelection: true, authorized: true, now: jst(time))
        #expect(plan == ShieldPlan(usual: usual, focus: focusOn))
    }

    @Test func adjacentWindowsAreJoined() {
        let merged = BlockPolicy.mergedWindows([
            UnblockWindow(start: jst("2026-10-19T20:30"), end: jst("2026-10-19T21:00")),
            UnblockWindow(start: jst("2026-10-19T20:00"), end: jst("2026-10-19T20:30")),
            UnblockWindow(start: jst("2026-10-19T12:00"), end: jst("2026-10-19T12:30")),
        ])
        #expect(merged == [UnblockWindow(start: jst("2026-10-19T12:00"), end: jst("2026-10-19T12:30")),
                           UnblockWindow(start: jst("2026-10-19T20:00"), end: jst("2026-10-19T21:00"))])
    }

    @Test func schedulesSwitchAtStartAndEnd() {
        let now = jst("2026-10-19T20:10:30")
        let all = [UnblockWindow(start: jst("2026-10-19T12:00"), end: jst("2026-10-19T12:30"))] + windows
        let schedules = BlockPolicy.unblockSchedules(all, now: now)
        // 終わったものは入れない。始まっているものは今の分から。終わりは「終わる前の合図」＝ゲーム・SNS の時間の終わり
        #expect(schedules.count == 1)
        #expect(schedules[0].start == jst("2026-10-19T20:10"))
        #expect(schedules[0].fireAt == jst("2026-10-19T21:00"))
        #expect(schedules[0].end.timeIntervalSince(schedules[0].start) >= 15 * 60)
    }

    @Test func logsStartAndEndOnce() throws {
        let store = MemoryBlockStore()
        store.state = state()
        store.selection = Data("sel".utf8)
        let log = MemoryBlockEventLog()
        #expect(!UnblockLog.note(store: store, log: log, authorized: true, now: jst("2026-10-19T19:59"), timeZone: tokyo))
        #expect(UnblockLog.note(store: store, log: log, authorized: true, now: jst("2026-10-19T20:00"), timeZone: tokyo))
        #expect(!UnblockLog.note(store: store, log: log, authorized: true, now: jst("2026-10-19T20:01"), timeZone: tokyo))
        #expect(UnblockLog.note(store: store, log: log, authorized: true, now: jst("2026-10-19T21:00"), timeZone: tokyo))
        #expect(try log.all().map(\.kind) == [.unblockStarted, .unblockEnded])
        #expect(try log.all().map(\.occurredAt) == [jst("2026-10-19T20:00"), jst("2026-10-19T21:00")])
    }

    /// ゲーム・SNS の時間の中で開けた時間が終わった → いつものブロックはかけず、外したと記録する
    @Test func unlockEndingInsideGameTimeKeepsItOpen() throws {
        let store = MemoryBlockStore()
        store.state = state(unlocked: true)
        store.selection = Data("sel".utf8)
        let log = MemoryBlockEventLog()
        var shielded = 0
        #expect(BlockReblock.run(store: store, log: log, now: jst("2026-10-19T20:40"), timeZone: tokyo, reason: .expired) { _ in
            shielded += 1
            return true
        })
        #expect(shielded == 0)
        #expect(try log.all().map(\.kind) == [.reblocked, .unblockStarted])
    }


    @Test(arguments: [
        // 始めた, 選択あり, 許可あり, 時刻 → いつもの
        (false, true, true, "2026-10-19T20:10", false),
        (false, true, true, "2026-10-19T19:00", false),
        (true, false, true, "2026-10-19T19:00", false),
        (true, true, false, "2026-10-19T19:00", false),
        (true, true, true, "2026-10-19T20:59:59", false),
    ])
    func decisionTableOtherRows(enabled: Bool, hasSelection: Bool, authorized: Bool, time: String, usual: Bool) {
        var s = state()
        s.isEnabled = enabled
        let plan = BlockPolicy.shields(s, hasSelection: hasSelection, authorized: authorized, now: jst(time))
        #expect(plan == ShieldPlan(usual: usual, focus: false))
    }

    @Test func unlockedWhileFocusingInsideWindowIsAllOpen() {
        let plan = BlockPolicy.shields(state(focus: true, unlocked: true), hasSelection: true, authorized: true,
                                       now: jst("2026-10-19T20:30"))
        #expect(plan == .none)
        #expect(!BlockPolicy.isUnblocking(state(focus: true), hasSelection: true, authorized: true, now: jst("2026-10-19T20:30")))
        #expect(!BlockPolicy.isUnblocking(state(), hasSelection: true, authorized: false, now: jst("2026-10-19T20:30")))
        #expect(BlockPolicy.unblockWindowEnd(state(), now: jst("2026-10-19T20:00")) == jst("2026-10-19T21:00"))
        #expect(BlockPolicy.unblockWindowEnd(state(), now: jst("2026-10-19T21:00")) == nil)
    }

    @Test func mergeKeepsSeparateAndJoinsOverlaps() {
        let a = UnblockWindow(start: jst("2026-10-19T20:00"), end: jst("2026-10-19T20:30"))
        let gap = UnblockWindow(start: jst("2026-10-19T20:30:01"), end: jst("2026-10-19T21:00"))
        #expect(BlockPolicy.mergedWindows([a, gap]).count == 2)
        #expect(BlockPolicy.mergedWindows([]).isEmpty)
        let three = [a, UnblockWindow(start: jst("2026-10-19T20:30"), end: jst("2026-10-19T21:00")),
                     UnblockWindow(start: jst("2026-10-19T21:00"), end: jst("2026-10-19T21:30"))]
        #expect(BlockPolicy.mergedWindows(three) == [UnblockWindow(start: jst("2026-10-19T20:00"), end: jst("2026-10-19T21:30"))])
    }

    @Test func schedulesBeforeStartUseTheStart() {
        let schedules = BlockPolicy.unblockSchedules(windows, now: jst("2026-10-19T19:00"))
        #expect(schedules.first?.start == jst("2026-10-19T20:00"))
        #expect(BlockPolicy.unblockSchedules(windows, now: jst("2026-10-19T21:00")).isEmpty)
        #expect(ShieldControl.unblockActivities.count == PlanLimits.unblockPerDay)
    }

    /// 拡張に合図が少し早く届いても、決定表は少しあとの時刻で引くので切り替わる（ShieldControl.applyForUnblockSignal と同じ計算）
    @Test func earlySignalStillSwitches() throws {
        let store = MemoryBlockStore()
        store.state = state()
        store.selection = Data("sel".utf8)
        let log = MemoryBlockEventLog()
        let tolerance: TimeInterval = 30
        let start = jst("2026-10-19T19:59:45").addingTimeInterval(tolerance)
        UnblockLog.note(store: store, log: log, authorized: true, now: start, timeZone: tokyo)
        #expect(BlockPolicy.shields(store.state, hasSelection: true, authorized: true, now: start) == .none)
        // 本体がすでに書いていれば二重に記録しない
        UnblockLog.note(store: store, log: log, authorized: true, now: jst("2026-10-19T20:01"), timeZone: tokyo)
        let end = jst("2026-10-19T20:59:45").addingTimeInterval(tolerance)
        UnblockLog.note(store: store, log: log, authorized: true, now: end, timeZone: tokyo)
        #expect(BlockPolicy.shields(store.state, hasSelection: true, authorized: true, now: end).usual)
        #expect(try log.all().map(\.kind) == [.unblockStarted, .unblockEnded])
    }

    @Test func stateRoundTripsWindows() throws {
        let s = BlockState(isEnabled: true, unblockWindows: windows, isUnblocking: true)
        #expect(try JSONDecoder().decode(BlockState.self, from: JSONEncoder().encode(s)) == s)
    }

    @Test func oldStateWithoutWindowsDecodes() throws {
        let state = try JSONDecoder().decode(BlockState.self, from: Data(#"{"isEnabled":true,"isFocusBlocking":true}"#.utf8))
        #expect(state.unblockWindows.isEmpty)
        #expect(!state.isUnblocking)
    }
}

/// 本体（AppModel）でのゲーム・SNS の時間。
@MainActor
struct GameTimeModelTests {
    private func model(_ t: TestStore, blocking: FakeBlocking = FakeBlocking(), blockStore: MemoryBlockStore? = nil,
                       log: MemoryBlockEventLog = MemoryBlockEventLog()) -> AppModel {
        let store = blockStore ?? {
            let s = MemoryBlockStore()
            s.state = BlockState(isEnabled: true)
            s.selection = Data("sel".utf8)
            return s
        }()
        let settings = MemorySettings()
        settings.didShowBlockingIntro = true
        settings.didLogBlockStart = true
        settings.lastBlockingAuthorized = true
        return AppModel(store: t.store, clock: t.clock, timeZone: { tokyo }, settings: settings, blocking: blocking,
                        blockStore: store, blockLog: log)
    }

    private func plan(_ categories: [CategoryOption], day: String, games: [String]) -> PlanDraft {
        PlanDraft(blocks: [PlanBlockDraft(start: jst("\(day)T09:00"), minutes: 60, category: categories[0])]
                  + games.map { PlanBlockDraft.unblock(start: jst("\(day)T\($0)")) })
    }

    // MARK: 引き継ぎ

    @Test func morningPlanStartsWithYesterdaysGameTimes() throws {
        let t = try TestStore(now: jst("2026-10-18T09:00"))
        let c = try t.seeded()
        try t.store.confirm(plan(c, day: "2026-10-18", games: ["20:00", "20:30"]), dayKey: "2026-10-18", timeZone: tokyo)
        t.clock.set(jst("2026-10-19T07:00"))
        let m = model(t)
        let draft = try #require(m.morningPlan?.draft)
        #expect(draft.blocks.map(\.start) == [jst("2026-10-19T20:00"), jst("2026-10-19T20:30")])
        #expect(draft.unblockCount == draft.blocks.count)
    }

    @Test func noPlanDaysAreSkippedButAnEmptyDayCarriesNothing() throws {
        let t = try TestStore(now: jst("2026-10-17T09:00"))
        let c = try t.seeded()
        try t.store.confirm(plan(c, day: "2026-10-17", games: ["21:00"]), dayKey: "2026-10-17", timeZone: tokyo)
        try t.store.skip(dayKey: "2026-10-18", timeZone: tokyo)
        t.clock.set(jst("2026-10-19T07:00"))
        let first = model(t)
        #expect(first.morningPlan?.draft.blocks.map(\.start) == [jst("2026-10-19T21:00")])

        // 前の日に確定した計画にゲーム・SNS の時間がなければ、なし
        let u = try TestStore(now: jst("2026-10-17T09:00"))
        let d = try u.seeded()
        try u.store.confirm(plan(d, day: "2026-10-17", games: ["21:00"]), dayKey: "2026-10-17", timeZone: tokyo)
        try u.store.confirm(plan(d, day: "2026-10-18", games: []), dayKey: "2026-10-18", timeZone: tokyo)
        u.clock.set(jst("2026-10-19T07:00"))
        let second = model(u)
        #expect(second.morningPlan?.draft.blocks.isEmpty == true)
    }

    @Test func tomorrowPlanCarriesTodaysGameTimes() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        let c = try t.seeded()
        let m = model(t)
        m.confirmPlan(plan(c, day: "2026-10-19", games: ["19:30"]))
        t.clock.set(jst("2026-10-19T22:30"))
        #expect(m.tomorrowPlan().draft.blocks.map(\.start) == [jst("2026-10-20T19:30")])
    }

    @Test func gameTimeIsSavedAndReadBack() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        let c = try t.seeded()
        try t.store.confirm(plan(c, day: "2026-10-19", games: ["20:00"]), dayKey: "2026-10-19", timeZone: tokyo)
        let stored = try #require(try t.store.plan(dayKey: "2026-10-19"))
        #expect(stored.draft.unblockCount == 1)
        let snapshot = try t.store.snapshot(dayKey: "2026-10-19")
        #expect(snapshot?.contains { $0.categoryId == CategoryOption.gameSNS.id } == true)
        // テンプレートにも入る
        try t.store.saveTemplate(PlanTemplate(name: "平日", plan: stored.draft, calendar: tokyoCalendar))
        let templates = try t.store.templates()
        #expect(templates.last?.blocks.contains { $0.category.isUnblock } == true)
    }

    // MARK: ブロックの切り替え

    @Test func confirmedGameTimeSwitchesUsualBlock() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        let c = try t.seeded()
        let blocking = FakeBlocking()
        let blockStore = MemoryBlockStore()
        blockStore.state = BlockState(isEnabled: true)
        blockStore.selection = Data("sel".utf8)
        let log = MemoryBlockEventLog()
        let m = model(t, blocking: blocking, blockStore: blockStore, log: log)
        m.confirmPlan(plan(c, day: "2026-10-19", games: ["20:00", "20:30"]))

        #expect(blockStore.state.unblockWindows == [UnblockWindow(start: jst("2026-10-19T20:00"), end: jst("2026-10-19T21:00"))])
        #expect(blocking.unblockSchedules?.count == 1)

        blocking.clearCalls()
        t.clock.set(jst("2026-10-19T20:05"))
        m.reload(quietly: true)
        #expect(blocking.calls.contains("unshield"))
        #expect(m.unblockedUntil == jst("2026-10-19T21:00"))

        blocking.clearCalls()
        t.clock.set(jst("2026-10-19T21:01"))
        m.reload(quietly: true)
        #expect(blocking.calls.contains("shield"))
        #expect(m.unblockedUntil == nil)
        #expect(try log.all().map(\.kind).filter { $0 == .unblockStarted || $0 == .unblockEnded } == [.unblockStarted, .unblockEnded])
    }

    @Test func draftPlanDoesNotOpenAnything() throws {
        let t = try TestStore(now: jst("2026-10-19T07:00"))
        let c = try t.seeded()
        let blockStore = MemoryBlockStore()
        blockStore.state = BlockState(isEnabled: true)
        blockStore.selection = Data("sel".utf8)
        let m = model(t, blockStore: blockStore)
        m.saveDraft(plan(c, day: "2026-10-19", games: ["07:00"]))
        m.reload()
        #expect(blockStore.state.unblockWindows.isEmpty)
    }

    @Test func focusDuringGameTimeBlocksEverything() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        let c = try t.seeded()
        let blocking = FakeBlocking()
        let m = model(t, blocking: blocking)
        m.confirmPlan(plan(c, day: "2026-10-19", games: ["20:00"]))
        t.clock.set(jst("2026-10-19T20:05"))
        m.reload()
        blocking.clearCalls()
        m.startUnplanned(category: c[0], minutes: 10)
        #expect(blocking.calls == ["shield", "focus"])
        #expect(m.unblockedUntil == nil)
        blocking.clearCalls()
        m.pause()
        #expect(blocking.calls == ["unshield", "unfocus"])
    }

    @Test func cannotStartTimerFromGameTime() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        let c = try t.seeded()
        let m = model(t)
        m.confirmPlan(plan(c, day: "2026-10-19", games: ["20:00"]))
        t.clock.set(jst("2026-10-19T20:05"))
        m.reload()
        let current = try #require(m.snapshot.currentBlock)
        #expect(current.category.isUnblock)
        m.startPlanned(block: current)
        #expect(m.running == nil)
    }

    // MARK: 窓の途中で直す・日の区切り

    private func blockFixture(_ t: TestStore) -> (FakeBlocking, MemoryBlockStore, MemoryBlockEventLog) {
        let store = MemoryBlockStore()
        store.state = BlockState(isEnabled: true)
        store.selection = Data("sel".utf8)
        return (FakeBlocking(), store, MemoryBlockEventLog())
    }

    @Test func endingOngoingGameTimeBlocksAgain() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        let c = try t.seeded()
        let (blocking, blockStore, log) = blockFixture(t)
        let m = model(t, blocking: blocking, blockStore: blockStore, log: log)
        m.confirmPlan(plan(c, day: "2026-10-19", games: ["20:00"]))
        t.clock.set(jst("2026-10-19T20:10"))
        m.reload()
        #expect(m.unblockedUntil != nil)

        var edited = try #require(m.plan)
        let id = try #require(edited.blocks.first { $0.isUnblock }?.id)
        edited.delete(id: id, confirmedDay: true, now: t.clock.now())
        blocking.clearCalls()
        _ = m.savePlanChanges(edited)
        #expect(blockStore.state.unblockWindows == [UnblockWindow(start: jst("2026-10-19T20:00"), end: jst("2026-10-19T20:10"))])
        #expect(blocking.calls.contains("shield"))
        #expect(m.unblockedUntil == nil)
        #expect(try log.all().map(\.kind).last == .unblockEnded)
    }

    @Test func addingAdjacentWindowMidwayKeepsItOpen() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        let c = try t.seeded()
        let (blocking, blockStore, log) = blockFixture(t)
        let m = model(t, blocking: blocking, blockStore: blockStore, log: log)
        m.confirmPlan(plan(c, day: "2026-10-19", games: ["20:00"]))
        t.clock.set(jst("2026-10-19T20:10"))
        m.reload()
        var edited = try #require(m.plan)
        edited.upsert(.unblock(start: jst("2026-10-19T20:30")))
        blocking.clearCalls()
        _ = m.savePlanChanges(edited)
        #expect(m.unblockedUntil == jst("2026-10-19T21:00"))
        #expect(!blocking.calls.contains("shield"))
        #expect(try log.all().map(\.kind).filter { $0 == .unblockEnded }.isEmpty)
    }

    /// 0:30 のゲーム・SNS の時間は前の日（4:00 区切り）の計画のもの。4:00 を過ぎて新しい日の計画が確定するまで、新しい窓はない
    @Test func fourAmSwitchesToTheNewDay() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        let c = try t.seeded()
        let (blocking, blockStore, log) = blockFixture(t)
        let m = model(t, blocking: blocking, blockStore: blockStore, log: log)
        var withLate = plan(c, day: "2026-10-19", games: [])
        withLate.upsert(.unblock(start: jst("2026-10-20T00:30")))
        m.confirmPlan(withLate)
        t.clock.set(jst("2026-10-20T00:40"))
        m.reload()
        #expect(m.unblockedUntil == jst("2026-10-20T01:00"))
        t.clock.set(jst("2026-10-20T03:59"))
        m.reload()
        #expect(!blockStore.state.unblockWindows.isEmpty)
        t.clock.set(jst("2026-10-20T04:00"))
        m.reload()
        #expect(blockStore.state.unblockWindows.isEmpty)
        // 朝の計画には引き継いでいる（翌日の暦の 0:30）
        #expect(m.morningPlan?.draft.blocks.map(\.start) == [jst("2026-10-21T00:30")])
    }

    @Test func noAuthorizationInsideWindowLogsNothing() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        let c = try t.seeded()
        let (blocking, blockStore, log) = blockFixture(t)
        let m = model(t, blocking: blocking, blockStore: blockStore, log: log)
        m.confirmPlan(plan(c, day: "2026-10-19", games: ["20:00"]))
        blocking.status = .denied
        t.clock.set(jst("2026-10-19T20:10"))
        m.reload()
        #expect(m.unblockedUntil == nil)
        #expect(try !log.all().map(\.kind).contains(.unblockStarted))
    }

    @Test func notStartedDoesNothing() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        let c = try t.seeded()
        let blocking = FakeBlocking()
        let log = MemoryBlockEventLog()
        let m = model(t, blocking: blocking, blockStore: MemoryBlockStore(), log: log)
        m.confirmPlan(plan(c, day: "2026-10-19", games: ["20:00"]))
        t.clock.set(jst("2026-10-19T20:10"))
        m.reload()
        #expect(m.unblockedUntil == nil)
        #expect(try log.all().isEmpty)
    }

    @Test func carryIgnoresDraftsAndLooksBackSevenDays() throws {
        let t = try TestStore(now: jst("2026-10-11T09:00"))
        let c = try t.seeded()
        try t.store.confirm(plan(c, day: "2026-10-11", games: ["21:00"]), dayKey: "2026-10-11", timeZone: tokyo)
        try t.store.saveDraft(plan(c, day: "2026-10-18", games: ["22:00"]), dayKey: "2026-10-18", timeZone: tokyo)
        t.clock.set(jst("2026-10-19T07:00"))
        // 前の日は下書き（飛ばす）、8日前の確定は拾わない
        let m = model(t)
        #expect(m.morningPlan?.draft.blocks.isEmpty == true)
    }

    @Test func carryUsesTheFinalShapeAfterEdits() throws {
        let t = try TestStore(now: jst("2026-10-18T09:00"))
        let c = try t.seeded()
        let m = model(t)
        m.confirmPlan(plan(c, day: "2026-10-18", games: ["20:00", "21:00"]))
        var edited = try #require(m.plan)
        let first = try #require(edited.sortedBlocks.first { $0.isUnblock })
        edited.delete(id: first.id, confirmedDay: true, now: t.clock.now())
        _ = m.savePlanChanges(edited)
        t.clock.set(jst("2026-10-19T07:00"))
        let next = model(t)
        #expect(next.morningPlan?.draft.blocks.map(\.start) == [jst("2026-10-19T21:00")])
    }

    @Test func tomorrowKeepsItsSavedDraft() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        let c = try t.seeded()
        let m = model(t)
        m.confirmPlan(plan(c, day: "2026-10-19", games: ["19:30"]))
        try t.store.saveDraft(plan(c, day: "2026-10-20", games: []), dayKey: "2026-10-20", timeZone: tokyo)
        #expect(m.tomorrowPlan().draft.unblockCount == 0)
    }

    /// 前の起動で登録に失敗した・iPhone 側から消えたときに備え、窓が同じでも起動のたびに登録し直す
    @Test func schedulesAreRegisteredAgainOnLaunch() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        let c = try t.seeded()
        let (_, blockStore, _) = blockFixture(t)
        let first = model(t, blockStore: blockStore)
        first.confirmPlan(plan(c, day: "2026-10-19", games: ["20:00"]))
        let blocking = FakeBlocking()
        _ = model(t, blocking: blocking, blockStore: blockStore)
        #expect(blocking.unblockSchedules?.count == 1)
    }

    /// 許可がない朝に確定し、あとでブロックを始めた → そのときに登録し直す
    @Test func startingBlockingRegistersSchedules() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        let c = try t.seeded()
        let blocking = FakeBlocking()
        let m = model(t, blocking: blocking, blockStore: MemoryBlockStore())
        m.confirmPlan(plan(c, day: "2026-10-19", games: ["20:00"]))
        blocking.clearCalls()
        #expect(m.saveBlockSelection(Data("sel".utf8)))
        #expect(blocking.unblockSchedules?.count == 1)
    }
}
