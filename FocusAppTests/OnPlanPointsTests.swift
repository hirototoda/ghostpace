import Foundation
import Testing
@testable import FocusApp

/// 計画どおりの点（GHO-16）と遅れ開始（TMR-15）
struct OnPlanPointsTests {
    private let study = CategoryOption(id: UUID(), name: "勉強", countsAsFocus: true)

    private func block(_ time: String, _ minutes: Int, category: CategoryOption? = nil) -> PlanBlockDraft {
        PlanBlockDraft(start: jst("2026-10-19T\(time)"), minutes: minutes, category: category ?? study)
    }

    private func session(_ b: PlanBlockDraft, _ from: String, _ to: String?, length: Int? = nil, declared: Bool = false,
                         pauses: [PauseInterval] = []) -> FocusSession {
        var s = FocusSession(id: UUID(), dayKey: "2026-10-19", category: b.category, planBlockId: b.id,
                             startAt: jst("2026-10-19T\(from)"), endAt: to.map { jst("2026-10-19T\($0)") },
                             plannedDurationSec: length ?? b.minutes * 60, pauses: pauses)
        s.isDeclared = declared
        return s
    }

    private func awards(_ blocks: [PlanBlockDraft], _ sessions: [FocusSession], morning: Set<UUID>? = nil,
                        added: [UUID: Date] = [:], now: String = "23:00") -> [OnPlanPoints.Award] {
        OnPlanPoints.awards(blocks: blocks, sessions: sessions, morningBlockIds: morning ?? Set(blocks.map(\.id)),
                            addedAt: added, now: jst("2026-10-19T\(now)"))
    }

    @Test func eightyPercentWithinAnHourEarnsOnePointAtThatMoment() {
        let b = block("09:00", 60)
        // 9:10 に始めて48分（80%）に届くのは 9:58
        let result = awards([b], [session(b, "09:10", "10:10")])
        #expect(result.map(\.date) == [jst("2026-10-19T09:58")])
        #expect(result.map(\.blockId) == [b.id])
        // まだ届いていなければ付かない
        #expect(awards([b], [session(b, "09:10", nil)], now: "09:50").isEmpty)
        #expect(awards([b], [session(b, "09:10", nil)], now: "09:58").count == 1)
    }

    @Test func startWindowIsOneHourEitherSide() {
        let b = block("10:00", 60)
        #expect(awards([b], [session(b, "09:00", "10:00")]).count == 1)
        #expect(awards([b], [session(b, "08:59", "10:00")]).isEmpty)
        #expect(awards([b], [session(b, "11:00", "12:00")]).count == 1)
        #expect(awards([b], [session(b, "11:01", "12:00")]).isEmpty)
    }

    @Test func pausesAndDeclaredTimeDoNotCount() {
        let b = block("09:00", 60)
        // 一時停止の15分を除くと45分 → 75% で付かない
        let paused = session(b, "09:00", "10:00", pauses: [PauseInterval(start: jst("2026-10-19T09:20"), end: jst("2026-10-19T09:35"))])
        #expect(awards([b], [paused]).isEmpty)
        // 申告した分は数えない（タイマーの30分だけ）
        #expect(awards([b], [session(b, "09:00", "09:30", declared: true), session(b, "09:30", "10:00")]).isEmpty)
    }

    @Test func lengthIsFixedWhenStarted() {
        // 始めたときは30分のブロック。あとで2時間に伸ばしても基準は30分（24分で付く）
        let b = block("09:00", 120)
        #expect(awards([b], [session(b, "09:00", "09:30", length: 30 * 60)]).map(\.date) == [jst("2026-10-19T09:24")])
    }

    @Test func targetBlocks() {
        let short = block("09:00", 25)
        let game = PlanBlockDraft.unblock(start: jst("2026-10-19T20:00"))
        #expect(awards([short], [session(short, "09:00", "09:25")]).isEmpty)
        #expect(awards([game], [session(game, "20:00", "20:30", length: 1800)]).isEmpty)
        // 朝の計画になく、始める1時間前より後に足したブロックは対象外
        let late = block("13:00", 60)
        #expect(awards([late], [session(late, "13:00", "14:00")], morning: [],
                       added: [late.id: jst("2026-10-19T12:30")]).isEmpty)
        #expect(awards([late], [session(late, "13:00", "14:00")], morning: [],
                       added: [late.id: jst("2026-10-19T12:00")]).count == 1)
        // デトックスのカテゴリも対象
        let walk = block("17:00", 30, category: CategoryOption(name: "運動", countsAsFocus: false))
        #expect(awards([walk], [session(walk, "17:00", "17:30")]).count == 1)
    }

    @Test func atMostThreePerDayFromTheEarliest() {
        let blocks = ["08:00", "10:00", "12:00", "14:00"].map { block($0, 60) }
        let sessions = blocks.map { b in
            FocusSession(id: UUID(), dayKey: "2026-10-19", category: study, planBlockId: b.id, startAt: b.start, endAt: b.end,
                         plannedDurationSec: 3600)
        }
        let result = awards(blocks, sessions)
        #expect(result.count == 3)
        #expect(result.map(\.blockId) == Array(blocks.prefix(3).map(\.id)))
    }

    @Test func goalGhostEarnsAtThePlannedEightyPercent() {
        let blocks = [block("09:00", 60), block("11:00", 20), block("13:00", 30), block("15:00", 60), block("17:00", 60)]
        let dates = OnPlanPoints.goalAwards(blocks: blocks)
        // 20分のブロックは除く、早い3つ
        #expect(dates == [jst("2026-10-19T09:48"), jst("2026-10-19T13:24"), jst("2026-10-19T15:48")])
    }

    // MARK: 遅れ開始（TMR-15）

    @Test func lateStartShiftsTheEndByTheLength() {
        let b = block("09:00", 30)
        #expect(OnPlanPoints.plannedEnd(blockStart: b.start, blockEnd: b.end, startingAt: jst("2026-10-19T09:12")) == jst("2026-10-19T09:42"))
        // 開始前・開始ちょうどはブロックの終わり（前倒しも今までどおり）
        #expect(OnPlanPoints.plannedEnd(blockStart: b.start, blockEnd: b.end, startingAt: jst("2026-10-19T08:40")) == jst("2026-10-19T09:30"))
        #expect(OnPlanPoints.plannedEnd(blockStart: b.start, blockEnd: b.end, startingAt: jst("2026-10-19T09:00")) == jst("2026-10-19T09:30"))
    }
}

/// 本体：計画どおりの点・遅れ開始・さっきの行・前倒し・切り替え
@MainActor
struct OnPlanModelTests {
    private func model(_ t: TestStore, settings: MemorySettings = MemorySettings()) -> AppModel {
        settings.didShowBlockingIntro = true
        return AppModel(store: t.store, clock: t.clock, timeZone: { tokyo }, settings: settings)
    }

    private func confirmed(_ t: TestStore, _ c: [CategoryOption]) -> AppModel {
        let m = model(t)
        m.confirmPlan(PlanDraft(blocks: [PlanBlockDraft(start: jst("2026-10-19T09:00"), minutes: 30, category: c[0]),
                                         PlanBlockDraft(start: jst("2026-10-19T10:00"), minutes: 60, category: c[0])]))
        return m
    }

    @Test func lateStartShiftsTheEndAndEarnsThePoint() throws {
        let t = try TestStore(now: jst("2026-10-19T07:00"))
        let c = try t.seeded()
        let m = confirmed(t, c)
        t.clock.set(jst("2026-10-19T09:12"))
        m.reload()
        let block = try #require(m.snapshot.currentBlock)
        m.startPlanned(block: block)
        let running = try #require(try t.store.runningSession())
        #expect(running.plannedEndAt == jst("2026-10-19T09:42"))
        #expect(running.plannedDurationSec == 1800)
        // 24分（80%）に届く 9:36 に1pt と帯
        let before = m.snapshot.points
        t.clock.set(jst("2026-10-19T09:36"))
        m.reload()
        #expect(m.snapshot.planAwards.map(\.date) == [jst("2026-10-19T09:36")])
        #expect(m.notice == "計画どおり +1pt（今日 1/3）")
        #expect(m.snapshot.points > before + 1)
        // 二度は出さない
        m.notice = nil
        t.clock.set(jst("2026-10-19T09:40"))
        m.reload()
        #expect(m.notice == nil)
    }

    @Test func pointsEarnedWhileClosedAreAnnouncedOnce() throws {
        let t = try TestStore(now: jst("2026-10-19T07:00"))
        let c = try t.seeded()
        let m = confirmed(t, c)
        // アプリを開かずに2つのブロックをやり終える
        for (from, to) in [("09:00", "09:30"), ("10:00", "11:00")] {
            let block = try #require(m.plan?.sortedBlocks.first { $0.start == jst("2026-10-19T\(from)") })
            t.clock.set(jst("2026-10-19T\(from)"))
            _ = try t.store.start(StartRequest(category: c[0], planBlockId: block.id, plannedEndAt: block.end,
                                               plannedDurationSec: block.minutes * 60, timeZone: tokyo))
            t.clock.set(jst("2026-10-19T\(to)"))
            _ = try t.store.end(id: try #require(try t.store.runningSession()).id, reportedEnd: nil)
        }
        m.reload()
        #expect(m.snapshot.planAwards.count == 2)
        #expect(m.notice == "計画どおり +1pt（今日 2/3）")
        m.notice = nil
        t.clock.set(jst("2026-10-19T11:01"))
        m.reload()
        #expect(m.notice?.hasPrefix("計画どおり") != true)
    }

    @Test func nextBlockStartingDuringALateTimerOffersTheSwitch() throws {
        let t = try TestStore(now: jst("2026-10-19T07:00"))
        let c = try t.seeded()
        let m = model(t)
        m.confirmPlan(PlanDraft(blocks: [PlanBlockDraft(start: jst("2026-10-19T09:00"), minutes: 60, category: c[0]),
                                         PlanBlockDraft(start: jst("2026-10-19T10:00"), minutes: 60, category: c[2])]))
        t.clock.set(jst("2026-10-19T09:30"))
        m.reload()
        m.startPlanned(block: try #require(m.snapshot.currentBlock))
        // 終わりは 10:30 にずれたので、10:00 の読書の時刻が来たら切り替えを出す
        t.clock.set(jst("2026-10-19T10:05"))
        m.reload()
        let timer = try #require(m.running)
        #expect(timer.switchableBlock(at: t.clock.now())?.title == "読書")
    }

    @Test func missedBlockRowAndStartingItLate() throws {
        let t = try TestStore(now: jst("2026-10-19T07:00"))
        let c = try t.seeded()
        let m = confirmed(t, c)
        t.clock.set(jst("2026-10-19T09:45"))
        m.reload()
        let missed = try #require(m.snapshot.recentMissedBlock)
        #expect(missed.start == jst("2026-10-19T09:00"))
        let draft = try #require(m.plan?.sortedBlocks.first)
        #expect(m.canStartLate(draft))
        m.startLate(draft)
        #expect(try t.store.runningSession()?.plannedEndAt == jst("2026-10-19T10:15"))
        // 記録ができたので、さっきの行はもう出ない
        #expect(m.snapshot.recentMissedBlock == nil)
        #expect(!m.canStartLate(draft))
    }

    @Test func missedRowDisappearsAnHourAfterTheStart() throws {
        let t = try TestStore(now: jst("2026-10-19T07:00"))
        let c = try t.seeded()
        let m = confirmed(t, c)
        t.clock.set(jst("2026-10-19T10:01"))
        m.reload()
        #expect(m.snapshot.recentMissedBlock == nil)
    }

    @Test func nextBlockCanStartEarlyDuringTheCurrentBlock() throws {
        let t = try TestStore(now: jst("2026-10-19T07:00"))
        let c = try t.seeded()
        let m = confirmed(t, c)
        t.clock.set(jst("2026-10-19T09:10"))
        m.reload()
        #expect(m.snapshot.currentBlock != nil)
        #expect(m.snapshot.earlyStartBlock?.start == jst("2026-10-19T10:00"))
        m.startPlanned(block: try #require(m.snapshot.earlyStartBlock))
        // 前倒しは今までどおりブロックの終わりまで
        #expect(try t.store.runningSession()?.plannedEndAt == jst("2026-10-19T11:00"))
    }

    @Test func goalGhostAndLastWeekEarnPlanPoints() throws {
        let t = try TestStore(now: jst("2026-10-12T07:00"))
        let c = try t.seeded()
        // 先週：9:00–10:00 を計画どおりに
        let last = model(t)
        last.confirmPlan(PlanDraft(blocks: [PlanBlockDraft(start: jst("2026-10-12T09:00"), minutes: 60, category: c[0])]))
        t.clock.set(jst("2026-10-12T09:00"))
        last.reload()
        last.startPlanned(block: try #require(last.snapshot.currentBlock))
        t.clock.set(jst("2026-10-12T10:00"))
        last.reload()
        last.requestEnd()
        // 今日
        t.clock.set(jst("2026-10-19T07:00"))
        let m = confirmed(t, c)
        #expect(m.snapshot.ghostPlanAwards == [jst("2026-10-19T09:48")])
        // 目標のゴースト：30分（9:24）と60分（10:48）
        #expect(m.snapshot.goalPlanAwards == [jst("2026-10-19T09:24"), jst("2026-10-19T10:48")])
    }
}
