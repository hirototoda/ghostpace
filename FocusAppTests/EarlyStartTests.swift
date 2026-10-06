import Foundation
import Testing
@testable import FocusApp

/// 前倒しで始める（TMR-10）と、計画外のタイマー中に計画の時刻が来たときの切り替え（TMR-11）。計算の部分。
struct EarlyStartTests {
    private let c = DefaultCategories.all

    private func summary(_ start: String, _ minutes: Int, _ category: CategoryOption = DefaultCategories.all[0],
                         title: String = "ゼミ準備") -> PlanBlockSummary {
        PlanBlockSummary(id: UUID(), category: category, project: nil, title: title, categoryName: category.name,
                         start: jst(start), end: jst(start).addingTimeInterval(Double(minutes * 60)),
                         countsAsFocus: category.countsAsFocus)
    }

    /// 9:00–10:30 英語、11:00–13:00 ゼミ準備
    private func plan(unblockAt: String? = nil) -> PlanDraft {
        var blocks = [
            PlanBlockDraft(start: jst("2026-10-19T09:00"), minutes: 90, category: c[0]),
            PlanBlockDraft(start: jst("2026-10-19T11:00"), minutes: 120, category: c[0]),
        ]
        if let unblockAt { blocks.append(.unblock(start: jst(unblockAt))) }
        return PlanDraft(blocks: blocks)
    }

    private func snapshot(_ now: String, plan: PlanDraft?) -> HomeSnapshot {
        HomeSnapshot.make(now: jst(now), calendar: tokyoCalendar, todaySessions: [], plan: plan, lastWeekSessions: [])
    }

    // MARK: 前倒し（TMR-10）

    @Test func earlyStartIsTheNextBlockBetweenBlocks() {
        let s = snapshot("2026-10-19T10:40", plan: plan())
        #expect(s.earlyStartBlock?.start == jst("2026-10-19T11:00"))
        // 朝いちばん（最初のブロックの前）も
        #expect(snapshot("2026-10-19T05:00", plan: plan()).earlyStartBlock?.start == jst("2026-10-19T09:00"))
    }

    /// 2026-10-06 から今の計画ブロックの最中も次を前倒しできる（タイマーがなくホームが見えているとき、TMR-15）
    @Test func earlyStartAlsoDuringABlock() {
        #expect(snapshot("2026-10-19T09:00", plan: plan()).earlyStartBlock?.start == jst("2026-10-19T11:00"))
        #expect(snapshot("2026-10-19T10:29", plan: plan()).earlyStartBlock?.start == jst("2026-10-19T11:00"))
        #expect(snapshot("2026-10-19T10:30", plan: plan()).earlyStartBlock?.start == jst("2026-10-19T11:00"))
        #expect(snapshot("2026-10-19T10:59", plan: plan()).earlyStartBlock?.start == jst("2026-10-19T11:00"))
        #expect(snapshot("2026-10-19T11:00", plan: plan()).earlyStartBlock == nil)
    }

    @Test func noEarlyStartOnNoPlanDayOrAfterTheLastBlock() {
        #expect(snapshot("2026-10-19T10:40", plan: nil).earlyStartBlock == nil)
        #expect(snapshot("2026-10-19T13:00", plan: plan()).earlyStartBlock == nil)
    }

    /// 次がゲーム・SNS の時間なら出さない（タイマーを始めないため、BLK-10）
    @Test func noEarlyStartForGameTime() {
        let s = snapshot("2026-10-19T10:40", plan: plan(unblockAt: "2026-10-19T10:45"))
        #expect(s.nextBlock?.category.isUnblock == true)
        #expect(s.earlyStartBlock == nil)
    }

    /// くっつくブロック：前のブロックの最中は次を前倒しでき、次の始まりの瞬間は次のブロックが「今」になる
    @Test func earlyStartBetweenAdjacentBlocks() {
        let adjacent = PlanDraft(blocks: [
            PlanBlockDraft(start: jst("2026-10-19T10:00"), minutes: 60, category: c[0]),
            PlanBlockDraft(start: jst("2026-10-19T11:00"), minutes: 60, category: c[1]),
        ])
        #expect(snapshot("2026-10-19T10:59", plan: adjacent).earlyStartBlock?.start == jst("2026-10-19T11:00"))
        #expect(snapshot("2026-10-19T11:00", plan: adjacent).earlyStartBlock == nil)
    }

    /// 3:59 は前の日（その日のブロックは終わっている）、4:00 からは新しい日の最初のブロック
    @Test func earlyStartAroundFourAm() {
        let today = PlanDraft(blocks: [PlanBlockDraft(start: jst("2026-10-19T06:00"), minutes: 60, category: c[0])])
        let yesterday = PlanDraft(blocks: [PlanBlockDraft(start: jst("2026-10-18T21:00"), minutes: 60, category: c[0])])
        #expect(snapshot("2026-10-19T03:59", plan: yesterday).earlyStartBlock == nil)
        #expect(snapshot("2026-10-19T04:00", plan: today).earlyStartBlock?.start == jst("2026-10-19T06:00"))
    }

    // MARK: 切り替え（TMR-11）

    /// くっつく2つのブロック：計画外のまま A（11:00）の時刻を過ぎ、B（12:00）の時刻が来たら B
    @Test func switchableIsTheCurrentOneOfAdjacentBlocks() {
        let a = summary("2026-10-19T11:00", 60, title: "英語")
        let b = summary("2026-10-19T12:00", 60)
        let t = timer(session("2026-10-19T10:30", nil), blocks: [a, b])
        #expect(t.switchableBlock(at: jst("2026-10-19T11:59")) == a)
        #expect(t.switchableBlock(at: jst("2026-10-19T12:00")) == b)
    }

    private func timer(_ session: FocusSession, blocks: [PlanBlockSummary]) -> RunningTimer {
        RunningTimer(session: session, focusSecondsBefore: 0, ghost: nil, planBlocks: blocks)
    }

    @Test func switchableFromBlockStartUntilBlockEnd() {
        let block = summary("2026-10-19T11:00", 120)
        let t = timer(session("2026-10-19T10:30", nil, plannedMinutes: 60), blocks: [block])
        #expect(t.switchableBlock(at: jst("2026-10-19T10:59")) == nil)
        #expect(t.switchableBlock(at: jst("2026-10-19T11:00")) == block)
        #expect(t.switchableBlock(at: jst("2026-10-19T12:59")) == block)
        #expect(t.switchableBlock(at: jst("2026-10-19T13:00")) == nil)
    }

    /// ブロックの途中でわざと計画外を始めたときは出さない。ちょうど同じ時刻に始めたときも出さない
    @Test func notSwitchableWhenStartedInsideTheBlock() {
        let block = summary("2026-10-19T11:00", 120)
        #expect(timer(session("2026-10-19T11:10", nil), blocks: [block]).switchableBlock(at: jst("2026-10-19T11:20")) == nil)
        #expect(timer(session("2026-10-19T11:00", nil), blocks: [block]).switchableBlock(at: jst("2026-10-19T11:20")) == nil)
    }

    /// 2026-10-06 から、遅れて始めて終わりをずらした計画ブロックのタイマー中に次のブロックの時刻が来たら切り替えを出す（TMR-15）。
    /// 終わりをずらしていない（定刻に始めて超過している）タイマーとゲーム・SNS には出さない
    @Test func switchableOnlyFromAShiftedBlockButNotForGameTime() {
        let block = summary("2026-10-19T11:00", 120)
        let earlier = summary("2026-10-19T10:00", 60)
        var shifted = session("2026-10-19T10:30", nil, plannedEnd: "2026-10-19T11:30")
        shifted.planBlockId = earlier.id
        #expect(timer(shifted, blocks: [earlier, block]).switchableBlock(at: jst("2026-10-19T11:05")) == block)
        var onTime = session("2026-10-19T10:00", nil, plannedEnd: "2026-10-19T11:00")
        onTime.planBlockId = earlier.id
        #expect(timer(onTime, blocks: [earlier, block]).switchableBlock(at: jst("2026-10-19T11:05")) == nil)
        // そのブロック自身のタイマーには出さない
        var own = session("2026-10-19T11:05", nil, plannedEnd: "2026-10-19T13:00")
        own.planBlockId = block.id
        #expect(timer(own, blocks: [block]).switchableBlock(at: jst("2026-10-19T11:10")) == nil)
        let game = summary("2026-10-19T11:00", 30, .gameSNS, title: "ゲーム・SNS")
        #expect(timer(session("2026-10-19T10:30", nil), blocks: [game]).switchableBlock(at: jst("2026-10-19T11:05")) == nil)
    }

    /// 一時停止中・ストップウォッチ・超過中でも出す
    @Test func switchableWhilePausedOrStopwatchOrOvertime() {
        let block = summary("2026-10-19T11:00", 120)
        let paused = session("2026-10-19T10:30", nil, pauses: [("2026-10-19T10:50", nil)], plannedMinutes: 25)
        #expect(timer(paused, blocks: [block]).switchableBlock(at: jst("2026-10-19T11:05")) == block)
        #expect(timer(session("2026-10-19T10:30", nil), blocks: [block]).switchableBlock(at: jst("2026-10-19T11:05")) == block)
        let over = session("2026-10-19T10:00", nil, plannedMinutes: 25)
        #expect(timer(over, blocks: [block]).switchableBlock(at: jst("2026-10-19T11:05")) == block)
    }

    // MARK: 計画の時刻の通知（TMR-11）

    private func notifications(_ running: FocusSession?, now: String, blocks: [PlanBlockSummary], enabled: Bool = true)
        -> AppNotification? {
        NotificationPlan.make(running: running, now: jst(now), plannedEndEnabled: enabled, reviewMinutes: 22 * 60,
                              calendar: tokyoCalendar, planBlocks: blocks)
            .first { $0.id == AppNotification.blockStartID }
    }

    @Test func offPlanTimerNotifiesAtTheNextBlockStart() {
        let blocks = [summary("2026-10-19T09:00", 90, title: "英語"), summary("2026-10-19T11:00", 120)]
        let n = notifications(session("2026-10-19T10:30", nil, plannedMinutes: 60), now: "2026-10-19T10:35", blocks: blocks)
        #expect(n?.trigger == .at(jst("2026-10-19T11:00")))
        #expect(n?.title == "ゼミ準備の時間です")
        #expect(n?.body == "11:00 になりました。開いて切り替えると、ここからゼミ準備の記録になります。")
    }

    /// 先に来る1つだけ
    @Test func onlyTheNearestBlockStartIsNotified() {
        let blocks = [summary("2026-10-19T14:00", 60, title: "卒論"), summary("2026-10-19T11:00", 120)]
        let n = notifications(session("2026-10-19T10:30", nil), now: "2026-10-19T10:59:59", blocks: blocks)
        #expect(n?.trigger == .at(jst("2026-10-19T11:00")))
    }

    @Test func blockStartNotificationEvenWhilePaused() {
        let paused = session("2026-10-19T10:30", nil, pauses: [("2026-10-19T10:40", nil)], plannedMinutes: 60)
        #expect(notifications(paused, now: "2026-10-19T10:45", blocks: [summary("2026-10-19T11:00", 120)]) != nil)
    }

    @Test func noBlockStartNotification() {
        let block = summary("2026-10-19T11:00", 120)
        let offPlan = session("2026-10-19T10:30", nil)
        // 設定でオフ
        #expect(notifications(offPlan, now: "2026-10-19T10:35", blocks: [block], enabled: false) == nil)
        // タイマーなし・計画ブロックから始めたタイマー
        #expect(notifications(nil, now: "2026-10-19T10:35", blocks: [block]) == nil)
        var planned = offPlan
        planned.planBlockId = UUID()
        #expect(notifications(planned, now: "2026-10-19T10:35", blocks: [block]) == nil)
        // もう始まった（ちょうどその時刻も）・ゲーム・SNS の時間・ブロックなし
        #expect(notifications(offPlan, now: "2026-10-19T11:00", blocks: [block]) == nil)
        let game = summary("2026-10-19T11:00", 30, .gameSNS, title: "ゲーム・SNS")
        #expect(notifications(offPlan, now: "2026-10-19T10:35", blocks: [game]) == nil)
        #expect(notifications(offPlan, now: "2026-10-19T10:35", blocks: []) == nil)
    }
}

/// 前倒し・切り替え・計画外でのブロック名（本体 AppModel）。
@MainActor
struct EarlyStartModelTests {
    /// 確定した計画（9:00–10:30 英語、11:00–13:00 ゼミ準備）を持つ AppModel
    private func model(_ t: TestStore, notifications: NoNotifications? = nil) throws -> AppModel {
        let settings = MemorySettings()
        settings.didShowBlockingIntro = true
        let m = AppModel(store: t.store, clock: t.clock, timeZone: { tokyo }, settings: settings,
                         notifications: notifications ?? NoNotifications())
        let seminar = try #require(m.createProject(name: "ゼミ準備", category: m.categories[0]))
        m.confirmPlan(PlanDraft(blocks: [
            PlanBlockDraft(start: jst("2026-10-19T09:00"), minutes: 90, category: m.categories[0]),
            PlanBlockDraft(start: jst("2026-10-19T11:00"), minutes: 120, category: m.categories[0], project: seminar),
        ]))
        return m
    }

    private func seminar(_ m: AppModel) throws -> PlanBlockSummary {
        try #require(m.plan?.summaries.first { $0.start == jst("2026-10-19T11:00") })
    }

    @Test func earlyStartRecordsTheBlockUntilItsEnd() throws {
        let t = try TestStore(now: jst("2026-10-19T10:40"))
        let m = try model(t)
        let block = try #require(m.snapshot.earlyStartBlock)
        m.startPlanned(block: block)
        let running = try #require(m.running?.session)
        #expect(running.planBlockId == block.id)
        #expect(running.startAt == jst("2026-10-19T10:40"))
        #expect(running.plannedEndAt == jst("2026-10-19T13:00"))
        #expect(running.title == "ゼミ準備")
        // 早く始めた分も達成率に入る（10:40–13:00 で 140分 ÷ 120分）
        t.clock.set(jst("2026-10-19T13:00"))
        m.end(reportedEnd: nil)
        let day = try #require(m.timelineDay(daysAgo: 0))
        let card = try #require(day.planBlocks.first { $0.id == block.id })
        #expect(day.achievementPercent(of: card) == 116)
        #expect(day.unplannedSessions.isEmpty)
    }

    @Test func switchEndsOffPlanAndStartsTheBlock() throws {
        let t = try TestStore(now: jst("2026-10-19T10:30"))
        let m = try model(t)
        m.startUnplanned(category: m.categories[0], minutes: 60)
        let offPlanId = try #require(m.running?.id)
        t.clock.set(jst("2026-10-19T11:05"))
        m.reload()
        let block = try seminar(m)
        #expect(m.running?.switchableBlock(at: t.clock.now()) == block)
        m.switchToBlock(block)

        let sessions = try t.store.sessions(dayKey: "2026-10-19")
        let ended = try #require(sessions.first { $0.id == offPlanId })
        #expect(ended.endAt == jst("2026-10-19T11:05"))
        #expect(ended.planBlockId == nil)
        let running = try #require(m.running?.session)
        #expect(running.planBlockId == block.id)
        #expect(running.startAt == jst("2026-10-19T11:05"))
        #expect(running.plannedEndAt == jst("2026-10-19T13:00"))
        #expect(m.running?.switchableBlock(at: t.clock.now()) == nil)
    }

    /// 1分未満で切り替えたら、計画外の記録は残さず知らせる（ブロックは始まる）
    @Test func switchRightAfterStartingDropsTheShortOne() throws {
        let t = try TestStore(now: jst("2026-10-19T10:59:30"))
        let m = try model(t)
        m.startUnplanned(category: m.categories[0], minutes: nil)
        t.clock.set(jst("2026-10-19T11:00:10"))
        m.reload()
        m.switchToBlock(try seminar(m))
        #expect(m.notice == AppModel.discardedNotice)
        #expect(try t.store.sessions(dayKey: "2026-10-19").count == 1)
        #expect(m.running?.session.planBlockId != nil)
    }

    /// 時刻の前・切り替えられないときは何もしない
    @Test func switchBeforeTheBlockDoesNothing() throws {
        let t = try TestStore(now: jst("2026-10-19T10:30"))
        let m = try model(t)
        m.startUnplanned(category: m.categories[0], minutes: 60)
        let id = m.running?.id
        t.clock.set(jst("2026-10-19T10:50"))
        m.switchToBlock(try seminar(m))
        #expect(m.running?.id == id)
        #expect(m.running?.session.planBlockId == nil)
    }

    /// 通知は予約し直され、切り替えたら計画の時刻の通知はなくなる
    @Test func blockStartNotificationIsScheduledForOffPlan() async throws {
        let t = try TestStore(now: jst("2026-10-19T10:30"))
        let notifications = NoNotifications(status: .authorized)
        let m = try model(t, notifications: notifications)
        await m.refreshNotificationStatus()
        m.startUnplanned(category: m.categories[0], minutes: nil)
        #expect(notifications.scheduled.first { $0.id == AppNotification.blockStartID }?.trigger == .at(jst("2026-10-19T11:00")))
        t.clock.set(jst("2026-10-19T11:05"))
        m.reload()
        m.switchToBlock(try seminar(m))
        #expect(!notifications.scheduled.contains { $0.id == AppNotification.blockStartID })
    }

    /// 通知を押して開き直した（新しく起動した）ときも、切り替えが出て通知も予約し直される
    @Test func switchableAfterReopeningTheApp() async throws {
        let t = try TestStore(now: jst("2026-10-19T10:30"))
        let m = try model(t)
        m.startUnplanned(category: m.categories[0], minutes: 60)
        let notifications = NoNotifications(status: .authorized)
        let settings = MemorySettings()
        settings.didShowBlockingIntro = true
        let reopened = AppModel(store: t.store, clock: t.clock, timeZone: { tokyo }, settings: settings,
                                notifications: notifications)
        await reopened.refreshNotificationStatus()
        #expect(notifications.scheduled.contains { $0.id == AppNotification.blockStartID })
        t.clock.set(jst("2026-10-19T11:05"))
        let later = AppModel(store: t.store, clock: t.clock, timeZone: { tokyo }, settings: settings)
        let block = try seminar(later)
        #expect(later.running?.switchableBlock(at: t.clock.now()) == block)
        later.switchToBlock(block)
        #expect(later.running?.session.planBlockId == block.id)
    }

    /// 一時停止中に切り替えても、計画外の記録は止めたところまで。ブロックは動いた状態で始まる
    @Test func switchWhilePaused() throws {
        let t = try TestStore(now: jst("2026-10-19T10:30"))
        let m = try model(t)
        m.startUnplanned(category: m.categories[0], minutes: 60)
        let id = try #require(m.running?.id)
        t.clock.set(jst("2026-10-19T10:50"))
        m.pause()
        t.clock.set(jst("2026-10-19T11:05"))
        m.reload()
        m.switchToBlock(try seminar(m))
        let ended = try #require(try t.store.sessions(dayKey: "2026-10-19").first { $0.id == id })
        #expect(ended.activeSeconds(at: jst("2026-10-19T11:05")) == 20 * 60)
        #expect(m.running?.session.isPaused == false)
    }

    /// 3:30 に計画外を始めて 4:00 を過ぎても、前の日の記録なので新しい日の計画には切り替えない
    /// （タイマー中は新しい日の朝の計画を出さないため、まだ新しい日の計画は確定していない）
    @Test func noSwitchAcrossFourAm() throws {
        let t = try TestStore(now: jst("2026-10-19T03:30"))
        let settings = MemorySettings()
        settings.didShowBlockingIntro = true
        let m = AppModel(store: t.store, clock: t.clock, timeZone: { tokyo }, settings: settings)
        m.skipPlan()
        m.startUnplanned(category: m.categories[0], minutes: nil)
        try t.store.confirm(PlanDraft(blocks: [PlanBlockDraft(start: jst("2026-10-19T05:00"), minutes: 60,
                                                              category: m.categories[0])]),
                            dayKey: "2026-10-19", timeZone: tokyo)
        t.clock.set(jst("2026-10-19T05:10"))
        m.reload()
        #expect(m.running?.session.dayKey == "2026-10-18")
        #expect(m.running?.switchableBlock(at: t.clock.now()) == nil)
    }

    /// 下書きのままの計画（未確定）のブロックでは、切り替えも通知も出さない
    @Test func noSwitchForDraftPlan() throws {
        let t = try TestStore(now: jst("2026-10-19T10:30"))
        let settings = MemorySettings()
        settings.didShowBlockingIntro = true
        let m = AppModel(store: t.store, clock: t.clock, timeZone: { tokyo }, settings: settings)
        m.saveDraft(PlanDraft(blocks: [PlanBlockDraft(start: jst("2026-10-19T11:00"), minutes: 60, category: m.categories[0])]))
        #expect(try t.store.plan(dayKey: "2026-10-19")?.status == .draft)
        m.startUnplanned(category: m.categories[0], minutes: nil)
        t.clock.set(jst("2026-10-19T11:05"))
        m.reload()
        #expect(m.running?.planBlocks.isEmpty == true)
    }

    /// 計画外でもブロック名を選べる（CAT-03、TMR-01）
    @Test func offPlanWithAProject() throws {
        let t = try TestStore(now: jst("2026-10-19T10:30"))
        let m = try model(t)
        let project = try #require(m.projects.first { $0.name == "ゼミ準備" })
        m.startUnplanned(category: m.categories[0], project: project, minutes: 25)
        let running = try #require(m.running?.session)
        #expect(running.project == project)
        #expect(running.title == "ゼミ準備")
        #expect(running.planBlockId == nil)
        // 開き直しても残る
        #expect(try t.store.runningSession()?.project == project)
    }
}
