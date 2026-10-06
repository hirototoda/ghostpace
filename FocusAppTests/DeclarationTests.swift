import Foundation
import SwiftData
import Testing
@testable import FocusApp

/// 押し忘れの申告（TMR-13、docs/product/features/focus-timer.md「押し忘れの申告」）
struct DeclarationTests {
    private let study = CategoryOption(id: UUID(), name: "勉強", countsAsFocus: true)

    private func block(_ time: String, _ minutes: Int, category: CategoryOption? = nil) -> PlanBlockDraft {
        PlanBlockDraft(start: jst("2026-10-19T\(time)"), minutes: minutes, category: category ?? study)
    }

    private func session(_ from: String, _ to: String, blockId: UUID? = nil) -> FocusSession {
        FocusSession(id: UUID(), dayKey: "2026-10-19", category: study, planBlockId: blockId,
                     startAt: jst("2026-10-19T\(from)"), endAt: jst("2026-10-19T\(to)"))
    }

    private func check(_ b: PlanBlockDraft, end: Date? = nil, snapshot: Set<UUID>? = nil, sessions: [FocusSession] = [],
                       opened: [DateInterval] = [], now: String = "12:00") -> Declaration.Problem? {
        Declaration.problem(block: b, end: end ?? b.end, morningBlockIds: snapshot ?? [b.id], sessions: sessions,
                            opened: opened, now: jst("2026-10-19T\(now)"))
    }

    @Test func endedMorningBlockWithoutRecordCanBeDeclared() {
        #expect(check(block("09:00", 90)) == nil)
        // 終わりを早めるのはよい
        #expect(check(block("09:00", 90), end: jst("2026-10-19T10:00")) == nil)
    }

    @Test func onlyEndedMorningBlocksWithoutRecords() {
        let b = block("09:00", 90)
        #expect(check(b, snapshot: []) == .notInMorningPlan)
        #expect(check(b, now: "10:00") == .notEnded)
        #expect(check(b, sessions: [session("09:10", "09:20", blockId: b.id)]) == .hasRecord)
        #expect(check(PlanBlockDraft.unblock(start: jst("2026-10-19T09:00"))) == .gameTime)
    }

    @Test func lengthCanOnlyBeShortened() {
        let b = block("09:00", 90)
        #expect(check(b, end: jst("2026-10-19T10:35")) == .invalidEnd)
        #expect(check(b, end: jst("2026-10-19T09:00")) == .invalidEnd)
        #expect(check(b, end: jst("2026-10-19T09:05")) == nil)
    }

    @Test func overlapsWithOtherRecordsOrOpenedTimeAreRefused() {
        let b = block("09:00", 90)
        #expect(check(b, sessions: [session("10:00", "10:20")]) == .overlapsRecord)
        #expect(check(b, opened: [DateInterval(start: jst("2026-10-19T09:30"), end: jst("2026-10-19T09:40"))]) == .opened)
        // 早めた終わりより後なら重ならない
        #expect(check(b, end: jst("2026-10-19T09:55"), sessions: [session("10:00", "10:20")]) == nil)
        // くっつくだけならよい
        #expect(check(b, sessions: [session("10:30", "11:00")]) == nil)
    }

    @Test func startingLateCanCountFromTheBlockStart() {
        let b = block("11:00", 120)
        func late(_ now: String, sessions: [FocusSession] = [], opened: [DateInterval] = [], snapshot: Set<UUID>? = nil) -> Date? {
            Declaration.lateStart(block: b, morningBlockIds: snapshot ?? [b.id], sessions: sessions, opened: opened,
                                  now: jst("2026-10-19T\(now)"))
        }
        #expect(late("11:20") == jst("2026-10-19T11:00"))
        // 5分未満は聞かない
        #expect(late("11:04") == nil)
        #expect(late("11:05") == jst("2026-10-19T11:00"))
        // 終わったあと・始まる前は聞かない（終わったブロックは計画のタブから申告）
        #expect(late("13:00") == nil)
        #expect(late("10:50") == nil)
        #expect(late("11:20", sessions: [session("11:02", "11:10")]) == nil)
        #expect(late("11:20", opened: [DateInterval(start: jst("2026-10-19T11:05"), end: jst("2026-10-19T11:06"))]) == nil)
        #expect(late("11:20", snapshot: []) == nil)
    }

    // MARK: 点（0.8倍）

    @Test func declaredFocusEarnsEightyPercent() {
        let timer = TimeSegment(start: jst("2026-10-19T09:00"), end: jst("2026-10-19T10:00"), countsAsFocus: true)
        var declared = timer
        declared.isDeclared = true
        let until = jst("2026-10-19T12:00")
        #expect(abs(FocusPoints.points([timer], until: until) - 6) < 0.0001)
        #expect(abs(FocusPoints.points([declared], until: until) - 4.8) < 0.0001)
    }

    @Test func declaredDetoxTimerEarnsZeroPointSixPerTenMinutes() {
        let dayStart = jst("2026-10-19T04:00")
        let interval = DateInterval(start: jst("2026-10-19T09:00"), end: jst("2026-10-19T09:30"))
        func points(declared: Bool) -> Double {
            DetoxDay.make(.init(dayStart: dayStart, dayEnd: dayStart.addingTimeInterval(86400), until: jst("2026-10-19T09:30"),
                                events: [BlockEvent(occurredAt: dayStart.addingTimeInterval(-60), timeZoneId: "Asia/Tokyo", kind: .started)],
                                focus: [], detoxTimers: [DetoxTimer(interval: interval, group: .housework, isDeclared: declared)],
                                sleep: [], gameWindows: []))
                .points(until: jst("2026-10-19T09:30"))
        }
        // 30分の家事：タイマーなら 2.25pt、申告なら 1.8pt（4:00〜9:00 のブロック中の点は同じ）
        #expect(abs(points(declared: false) - points(declared: true) - 0.45) < 0.0001)
    }

    @Test func openedTimeJustTouchingIsFine() {
        let b = block("09:00", 90)
        #expect(check(b, opened: [DateInterval(start: jst("2026-10-19T08:50"), end: jst("2026-10-19T09:00"))]) == nil)
        #expect(check(b, opened: [DateInterval(start: jst("2026-10-19T10:30"), end: jst("2026-10-19T10:40"))]) == nil)
    }

    @Test func gameTimeIsNeverAskedForALateStart() {
        let game = PlanBlockDraft.unblock(start: jst("2026-10-19T11:00"))
        #expect(Declaration.lateStart(block: game, morningBlockIds: [game.id], sessions: [], opened: [],
                                      now: jst("2026-10-19T11:20")) == nil)
    }

    /// 先週の自分のゴーストも、申告した分は0.8倍（今日の自分と同じに数える）
    @Test func lastWeekGhostKeepsTheDeclaredMark() throws {
        var declared = FocusSession(id: UUID(), dayKey: "2026-10-12", category: study, planBlockId: nil,
                                    startAt: jst("2026-10-12T09:00"), endAt: jst("2026-10-12T10:00"))
        declared.isDeclared = true
        let ghost = try #require(GhostSummary(lastWeek: [declared], lastWeekStart: jst("2026-10-12T04:00"),
                                              todayStart: jst("2026-10-19T04:00")))
        #expect(ghost.segments.allSatisfy { $0.isDeclared })
        #expect(abs(FocusPoints.points(ghost.segments, until: jst("2026-10-19T12:00")) - 4.8) < 0.0001)
        // 集中した時間はそのまま
        #expect(ghost.focusSeconds(at: jst("2026-10-19T12:00")) == 3600)
    }

    @Test func timelineSaysDeclared() {
        var declared = session("09:00", "10:00")
        declared.isDeclared = true
        #expect(sessionCaption(declared, now: jst("2026-10-19T12:00")).contains("申告"))
        #expect(!sessionCaption(session("09:00", "10:00"), now: jst("2026-10-19T12:00")).contains("申告"))
    }

    @Test func declaredDetoxTimerUsesTheSameDailyCap() {
        let dayStart = jst("2026-10-19T04:00")
        let interval = DateInterval(start: jst("2026-10-19T09:00"), end: jst("2026-10-19T10:30"))
        func points(declared: Bool) -> Double {
            DetoxDay.make(.init(dayStart: dayStart, dayEnd: dayStart.addingTimeInterval(86400), until: jst("2026-10-19T10:30"),
                                events: [BlockEvent(occurredAt: dayStart.addingTimeInterval(-60), timeZoneId: "Asia/Tokyo", kind: .started)],
                                focus: [], detoxTimers: [DetoxTimer(interval: interval, group: .housework, isDeclared: declared)],
                                sleep: [], gameWindows: []))
                .points(until: jst("2026-10-19T10:30"))
        }
        // 家事の上限1時間：タイマーは 4.5＋1.5、申告は 3.6＋1.5（上限を超えた30分はどちらもブロック中の0.5pt）
        #expect(abs(points(declared: false) - points(declared: true) - 0.9) < 0.0001)
    }
}

/// 本体（AppModel）とストアでの申告
@MainActor
struct DeclarationModelTests {
    private func model(_ t: TestStore) -> AppModel {
        let settings = MemorySettings()
        settings.didShowBlockingIntro = true
        return AppModel(store: t.store, clock: t.clock, timeZone: { tokyo }, settings: settings)
    }

    private func confirmedPlan(_ t: TestStore, _ c: [CategoryOption]) throws -> AppModel {
        let m = model(t)
        m.confirmPlan(PlanDraft(blocks: [PlanBlockDraft(start: jst("2026-10-19T09:00"), minutes: 90, category: c[0]),
                                         PlanBlockDraft(start: jst("2026-10-19T11:00"), minutes: 120, category: c[0])]))
        return m
    }

    @Test func declaringAddsAMarkedRecordThatCountsAsFocus() throws {
        let t = try TestStore(now: jst("2026-10-19T07:00"))
        let c = try t.seeded()
        let m = try confirmedPlan(t, c)
        t.clock.set(jst("2026-10-19T10:40"))
        m.reload()
        let morning = try #require(m.plan?.sortedBlocks.first)
        #expect(m.declarationProblem(for: morning, end: morning.end) == nil)
        #expect(m.declare(morning, end: jst("2026-10-19T10:15")))
        let sessions = try t.store.sessions(dayKey: "2026-10-19")
        #expect(sessions.count == 1)
        #expect(sessions[0].isDeclared)
        #expect(sessions[0].startAt == jst("2026-10-19T09:00"))
        #expect(sessions[0].endAt == jst("2026-10-19T10:15"))
        #expect(sessions[0].planBlockId == morning.id)
        // 集中した時間に入る
        #expect(m.snapshot.focusSeconds == 75 * 60)
        // 二度は申告できない
        #expect(m.declarationProblem(for: morning, end: morning.end) == .hasRecord)
    }

    @Test func blocksAddedLaterCannotBeDeclared() throws {
        let t = try TestStore(now: jst("2026-10-19T07:00"))
        let c = try t.seeded()
        let m = try confirmedPlan(t, c)
        var plan = try #require(m.plan)
        let added = PlanBlockDraft(start: jst("2026-10-19T07:30"), minutes: 30, category: c[2])
        plan.upsert(added)
        m.savePlanChanges(plan)
        t.clock.set(jst("2026-10-19T10:40"))
        m.reload()
        #expect(m.declarationProblem(for: added, end: added.end) == .notInMorningPlan)
        #expect(!m.declare(added, end: added.end))
    }

    @Test func startingLateFromTheBlockStartSplitsIntoDeclaredAndTimer() throws {
        let t = try TestStore(now: jst("2026-10-19T07:00"))
        let c = try t.seeded()
        let m = try confirmedPlan(t, c)
        t.clock.set(jst("2026-10-19T11:20"))
        m.reload()
        let block = try #require(m.snapshot.currentBlock)
        #expect(m.lateStart(for: block) == jst("2026-10-19T11:00"))
        m.startPlanned(block: block, fromBlockStart: true)
        let sessions = try t.store.sessions(dayKey: "2026-10-19").sorted { $0.startAt < $1.startAt }
        #expect(sessions.count == 2)
        #expect(sessions[0].isDeclared && sessions[0].startAt == jst("2026-10-19T11:00") && sessions[0].endAt == jst("2026-10-19T11:20"))
        #expect(!sessions[1].isDeclared && sessions[1].isRunning && sessions[1].startAt == jst("2026-10-19T11:20"))
        #expect(sessions[1].plannedEndAt == jst("2026-10-19T13:00"))
        #expect(m.running != nil)
    }

    @Test func declaredRecordsCanBeShortenedLikeOthers() throws {
        let t = try TestStore(now: jst("2026-10-19T07:00"))
        let c = try t.seeded()
        let m = try confirmedPlan(t, c)
        t.clock.set(jst("2026-10-19T10:40"))
        m.reload()
        let morning = try #require(m.plan?.sortedBlocks.first)
        #expect(m.declare(morning, end: morning.end))
        let declared = try #require(try t.store.sessions(dayKey: "2026-10-19").first)
        try t.store.shortenEnd(id: declared.id, to: jst("2026-10-19T10:00"))
        let shortened = try #require(try t.store.sessions(dayKey: "2026-10-19").first)
        #expect(shortened.isDeclared)
        #expect(shortened.endAt == jst("2026-10-19T10:00"))
    }

    /// 第4版の記録が第5版で読め、申告の印は空（タイマーの記録）
    @Test func version4StoreOpensWithVersion5() throws {
        let url = temporaryStoreURL()
        defer { removeStoreFiles(url) }
        let now = jst("2026-10-19T09:00")
        let sessionId = UUID(), categoryId = UUID()
        do {
            let schema = Schema(versionedSchema: SchemaV4.self)
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url,
                                                                                               cloudKitDatabase: .none))
            let context = ModelContext(container)
            context.insert(SchemaV4.CategoryRecord(id: categoryId, name: "勉強", countsAsFocus: true, sortOrder: 0, at: now))
            let session = SchemaV4.FocusSessionRecord(id: sessionId, dayKey: "2026-10-19", timeZoneId: "Asia/Tokyo",
                                                      planBlockId: nil, categoryId: categoryId, countsAsFocus: true,
                                                      projectId: nil, startAt: jst("2026-10-19T08:00"),
                                                      plannedEndAt: nil, plannedDurationSec: nil, at: now)
            session.endAt = jst("2026-10-19T08:40")
            context.insert(session)
            try context.save()
        }
        let container = try AppStore.makeContainer(url: url)
        let store = SwiftDataStore(container: container, clock: FixedClock(date: now))
        let sessions = try store.sessions(dayKey: "2026-10-19")
        #expect(sessions.map(\.id) == [sessionId])
        #expect(sessions.first?.isDeclared == false)
    }

    @Test func noLateStartQuestionWhileATimerRuns() throws {
        let t = try TestStore(now: jst("2026-10-19T07:00"))
        let c = try t.seeded()
        let m = try confirmedPlan(t, c)
        t.clock.set(jst("2026-10-19T10:50"))
        m.reload()
        m.startUnplanned(category: c[2], minutes: nil)
        t.clock.set(jst("2026-10-19T11:20"))
        m.reload()
        let block = try #require(m.snapshot.currentBlock)
        #expect(m.lateStart(for: block) == nil)
    }

    @Test func declaringOverARunningTimerIsRefused() throws {
        let t = try TestStore(now: jst("2026-10-19T07:00"))
        let c = try t.seeded()
        let m = try confirmedPlan(t, c)
        t.clock.set(jst("2026-10-19T09:30"))
        m.reload()
        m.startUnplanned(category: c[2], minutes: nil)
        t.clock.set(jst("2026-10-19T10:40"))
        m.reload()
        let morning = try #require(m.plan?.sortedBlocks.first)
        #expect(m.declarationProblem(for: morning, end: morning.end) == .overlapsRecord)
        // 計画外のタイマーより前で終わるなら申告できる
        #expect(m.declarationProblem(for: morning, end: jst("2026-10-19T09:30")) == nil)
    }

    /// 日をまたぐブロック（23:30〜翌1:00）は 3:59 までその日のうちとして申告でき、記録は始めた日の分
    @Test func blockAcrossMidnightCanBeDeclaredUntilFourAm() throws {
        let t = try TestStore(now: jst("2026-10-19T07:00"))
        let c = try t.seeded()
        let m = model(t)
        m.confirmPlan(PlanDraft(blocks: [PlanBlockDraft(start: jst("2026-10-19T23:30"), minutes: 90, category: c[0])]))
        t.clock.set(jst("2026-10-20T03:59"))
        m.reload()
        let late = try #require(m.plan?.sortedBlocks.first)
        #expect(m.declare(late, end: late.end))
        #expect(try t.store.sessions(dayKey: "2026-10-19").first?.isDeclared == true)
        // 4:00 を過ぎると新しい日の計画なので、前の日のブロックは申告できない
        t.clock.set(jst("2026-10-20T04:00"))
        m.reload()
        #expect(m.declarationProblem(for: late, end: late.end) != nil)
    }
}
