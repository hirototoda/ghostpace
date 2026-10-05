import Foundation
import Testing
@testable import FocusApp

/// 習慣（PLN-08）と候補（PLN-09）。docs/product/features/daily-plan.md「習慣」「候補から足す」
struct HabitsTests {
    private let dayStart = jst("2026-10-19T04:00")
    private let study = CategoryOption(id: UUID(), name: "勉強", countsAsFocus: true)
    private let rest = CategoryOption(id: UUID(), name: "休み", countsAsFocus: false)
    private let reading = CategoryOption(id: UUID(), name: "読書", countsAsFocus: true)

    private func block(_ time: String, _ minutes: Int, _ category: CategoryOption, day: String = "2026-10-19") -> PlanBlockDraft {
        PlanBlockDraft(start: jst("\(day)T\(time)"), minutes: minutes, category: category)
    }

    private func habit(_ hour: Int, _ minute: Int, _ minutes: Int, _ category: CategoryOption) -> PlanTemplate.Block {
        PlanTemplate.Block(hour: hour, minute: minute, minutes: minutes, category: category)
    }

    private var habits: PlanHabits {
        PlanHabits(blocks: [habit(7, 0, 15, rest), habit(20, 0, 30, .gameSNS), habit(0, 30, 30, .gameSNS)])
    }

    // MARK: 習慣

    @Test func habitsAreAppliedToTheDay() {
        let draft = habits.draft(dayStart: dayStart, calendar: tokyoCalendar)
        // 0:00〜3:59 は暦の翌日（朝4:00区切り）
        #expect(draft.sortedBlocks.map(\.start) == [jst("2026-10-19T07:00"), jst("2026-10-19T20:00"), jst("2026-10-20T00:30")])
        #expect(draft.unblockCount == 2)
        #expect(draft.sortedBlocks.first?.category == rest)
    }

    @Test func habitsRoundTripFromAPlan() {
        let draft = habits.draft(dayStart: dayStart, calendar: tokyoCalendar)
        #expect(PlanHabits(plan: draft, calendar: tokyoCalendar).draft(dayStart: dayStart, calendar: tokyoCalendar).sortedBlocks
            .map(\.start) == draft.sortedBlocks.map(\.start))
    }

    @Test func atMostThreeOtherBlocksAndThreeGameTimes() {
        var draft = PlanDraft(blocks: [block("07:00", 30, rest), block("09:00", 60, study), block("13:00", 60, reading)])
        #expect(PlanHabits.problem(with: block("15:00", 30, study), in: draft, dayStart: dayStart) == "習慣のブロックは3つまでです")
        // ゲーム・SNS の時間は別に3つまで
        #expect(PlanHabits.problem(with: .unblock(start: jst("2026-10-19T20:00")), in: draft, dayStart: dayStart) == nil)
        // 今あるブロックを直すのは数えない
        let existing = draft.blocks[1]
        var moved = existing
        moved.start = jst("2026-10-19T10:00")
        #expect(PlanHabits.problem(with: moved, in: draft, dayStart: dayStart) == nil)
        // ゲーム・SNS をほかのブロックに変えるときは数える
        let game = PlanBlockDraft.unblock(start: jst("2026-10-19T20:00"))
        draft.upsert(game)
        var changed = game
        changed.category = study
        changed.minutes = 60
        #expect(PlanHabits.problem(with: changed, in: draft, dayStart: dayStart) == "習慣のブロックは3つまでです")
        // 重なりは計画と同じ理由
        #expect(PlanHabits.problem(with: block("09:30", 30, rest), in: PlanDraft(blocks: [block("09:00", 60, study)]),
                                   dayStart: dayStart) != nil)
    }

    @Test func habitsAroundFourAm() {
        // 3:55 は1日の終わり（暦の翌日）、4:00 はその日の始まり
        let draft = PlanHabits(blocks: [habit(3, 55, 5, rest), habit(4, 0, 15, rest)]).draft(dayStart: dayStart, calendar: tokyoCalendar)
        #expect(draft.sortedBlocks.map(\.start) == [jst("2026-10-19T04:00"), jst("2026-10-20T03:55")])
        // 4:00 をまたぐ習慣は置けない
        #expect(PlanHabits.problem(with: block("03:30", 60, rest, day: "2026-10-20"), in: PlanDraft(), dayStart: dayStart) != nil)
        #expect(PlanHabits.problem(with: block("03:30", 30, rest, day: "2026-10-20"), in: PlanDraft(), dayStart: dayStart) == nil)
    }

    @Test func habitsKeepTheWallClockOnDaylightSavingDays() throws {
        // 夏時間の終わり（2026-11-01 2:00 に1時間戻る）の日も、習慣・テンプレートの時刻は同じ
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 4)))
        let draft = PlanHabits(blocks: [habit(9, 0, 60, study), habit(1, 30, 30, .gameSNS)]).draft(dayStart: start, calendar: calendar)
        let parts = draft.sortedBlocks.map { calendar.dateComponents([.day, .hour, .minute], from: $0.start) }
        #expect(parts.map(\.hour) == [9, 1])
        #expect(parts.map(\.day) == [31, 1])
        let next = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 4)))
        let after = PlanHabits(blocks: [habit(9, 0, 60, study)]).draft(dayStart: next, calendar: calendar)
        #expect(after.blocks.map { calendar.component(.hour, from: $0.start) } == [9])
    }

    @Test func habitGameTimesLeaveNoRoomForTemplateGameTimes() {
        let habitDraft = PlanHabits(blocks: [habit(19, 0, 30, .gameSNS), habit(20, 0, 30, .gameSNS), habit(21, 0, 30, .gameSNS)])
            .draft(dayStart: dayStart, calendar: tokyoCalendar)
        let loaded = habitDraft.loading(PlanDraft(blocks: [.unblock(start: jst("2026-10-19T22:00"))]), keeping: habitDraft)
        #expect(loaded.unblockCount == 3)
        #expect(!loaded.blocks.contains { $0.start == jst("2026-10-19T22:00") })
    }

    // MARK: テンプレートを読み込んでも習慣は残る（2026-10-05 オーナー決定）

    @Test func loadingATemplateKeepsHabitBlocks() {
        let habitDraft = habits.draft(dayStart: dayStart, calendar: tokyoCalendar)
        var plan = habitDraft
        plan.upsert(block("10:00", 60, study))
        let template = PlanDraft(blocks: [
            block("07:00", 15, rest),  // 習慣と同じ → 1つだけ
            block("09:00", 180, study),  // 10:00 の勉強は習慣ではないので消え、これが入る
            block("19:45", 30, reading),  // 習慣のゲーム・SNS と重なる → 入らない
            .unblock(start: jst("2026-10-19T21:00")),
            .unblock(start: jst("2026-10-19T21:30")),  // 3つ目まで
        ])
        let loaded = plan.loading(template, keeping: habitDraft)
        #expect(loaded.sortedBlocks.map(\.start) == [
            jst("2026-10-19T07:00"), jst("2026-10-19T09:00"), jst("2026-10-19T20:00"), jst("2026-10-19T21:00"),
            jst("2026-10-20T00:30"),
        ])
        #expect(loaded.unblockCount == 3)
    }

    @Test func movedHabitBlockIsNoLongerKept() {
        let habitDraft = habits.draft(dayStart: dayStart, calendar: tokyoCalendar)
        var plan = habitDraft
        var meditation = plan.sortedBlocks[0]
        meditation.start = jst("2026-10-19T07:30")
        plan.upsert(meditation)
        let loaded = plan.loading(PlanDraft(blocks: [block("09:00", 60, study)]), keeping: habitDraft)
        // 動かしたブロックは習慣ではなく普通のブロックとして置き換わる
        #expect(!loaded.blocks.contains { $0.category == rest })
    }

    @Test func goingWithATemplateKeepsFutureHabitBlocks() {
        let habitDraft = PlanHabits(blocks: [habit(20, 0, 30, .gameSNS), habit(21, 0, 30, rest)])
            .draft(dayStart: dayStart, calendar: tokyoCalendar)
        var plan = habitDraft
        plan.upsert(block("09:00", 60, study))
        plan.upsert(block("15:00", 60, study))
        let template = PlanDraft(blocks: [block("14:00", 120, reading), block("21:00", 60, study)])
        let result = plan.replacingFuture(with: template, now: jst("2026-10-19T11:00"), keeping: habitDraft)
        #expect(result.sortedBlocks.map(\.start) == [
            jst("2026-10-19T09:00"), jst("2026-10-19T14:00"), jst("2026-10-19T20:00"), jst("2026-10-19T21:00"),
        ])
        #expect(result.sortedBlocks.last?.category == rest)
    }

    // MARK: 候補（PLN-09）

    @Test func candidatesComeFromYesterdayLastWeekAndTemplates() {
        let yesterdayStart = jst("2026-10-18T04:00")
        let lastWeekStart = jst("2026-10-12T04:00")
        let yesterday = PlanDraft(blocks: [block("09:00", 60, study, day: "2026-10-18"), block("20:00", 60, reading, day: "2026-10-18"),
                                           .unblock(start: jst("2026-10-18T21:00"))])
        let lastWeek = PlanDraft(blocks: [block("09:00", 60, study, day: "2026-10-12"), block("13:00", 30, rest, day: "2026-10-12")])
        let template = PlanTemplate(name: "平日", blocks: [habit(13, 0, 30, rest), habit(0, 30, 30, reading), habit(8, 0, 60, study)])
        let today = PlanDraft(blocks: [block("19:30", 60, study)])
        let candidates = PlanCandidates.make(
            plan: today, dayStart: dayStart, calendar: tokyoCalendar,
            sources: [.init(source: .yesterday, plan: yesterday, dayStart: yesterdayStart),
                      .init(source: .lastWeek, plan: lastWeek, dayStart: lastWeekStart)],
            templates: [template], notEndedBy: nil)
        // 20:00 の読書は今日の 19:30 と重なる、ゲーム・SNS は出さない、同じものは最初の出どころだけ
        // 8:00 の勉強は 9:00 の勉強と重なるが、候補どうしは重なってよい
        #expect(candidates.map { $0.block.start } == [
            jst("2026-10-19T08:00"), jst("2026-10-19T09:00"), jst("2026-10-19T13:00"), jst("2026-10-20T00:30"),
        ])
        #expect(candidates.map(\.source) == [.template("平日"), .yesterday, .lastWeek, .template("平日")])
        #expect(Set(candidates.map(\.id)).count == candidates.count)
    }

    @Test func confirmedDayHidesEndedCandidates() {
        let yesterday = PlanDraft(blocks: [block("09:00", 60, study, day: "2026-10-18"), block("10:30", 60, rest, day: "2026-10-18"),
                                           block("15:00", 60, reading, day: "2026-10-18")])
        let candidates = PlanCandidates.make(
            plan: PlanDraft(), dayStart: dayStart, calendar: tokyoCalendar,
            sources: [.init(source: .yesterday, plan: yesterday, dayStart: jst("2026-10-18T04:00"))],
            templates: [], notEndedBy: jst("2026-10-19T11:00"))
        // 終わった 9:00 は出さず、途中の 10:30 と、これからの 15:00 は出す
        #expect(candidates.map { $0.block.start } == [jst("2026-10-19T10:30"), jst("2026-10-19T15:00")])
    }

    @Test func yesterdayWinsOverLastWeekButOtherLengthsStay() {
        let candidates = PlanCandidates.make(
            plan: PlanDraft(), dayStart: dayStart, calendar: tokyoCalendar,
            sources: [.init(source: .yesterday, plan: PlanDraft(blocks: [block("09:00", 60, study, day: "2026-10-18")]),
                            dayStart: jst("2026-10-18T04:00")),
                      .init(source: .lastWeek, plan: PlanDraft(blocks: [block("09:00", 60, study, day: "2026-10-12"),
                                                                       block("09:00", 90, study, day: "2026-10-12")]),
                            dayStart: jst("2026-10-12T04:00"))],
            templates: [], notEndedBy: nil)
        #expect(candidates.map(\.source) == [.yesterday, .lastWeek])
        #expect(candidates.map(\.block.minutes) == [60, 90])
        // 描き直しても ID は変わらない
        #expect(candidates.map(\.id) == PlanCandidates.make(
            plan: PlanDraft(), dayStart: dayStart, calendar: tokyoCalendar,
            sources: [.init(source: .yesterday, plan: PlanDraft(blocks: [block("09:00", 60, study, day: "2026-10-18")]),
                            dayStart: jst("2026-10-18T04:00")),
                      .init(source: .lastWeek, plan: PlanDraft(blocks: [block("09:00", 60, study, day: "2026-10-12"),
                                                                       block("09:00", 90, study, day: "2026-10-12")]),
                            dayStart: jst("2026-10-12T04:00"))],
            templates: [], notEndedBy: nil).map(\.id))
    }

    @Test func candidateEndingExactlyNowIsHidden() {
        let candidates = PlanCandidates.make(
            plan: PlanDraft(), dayStart: dayStart, calendar: tokyoCalendar,
            sources: [.init(source: .yesterday, plan: PlanDraft(blocks: [block("10:00", 60, study, day: "2026-10-18")]),
                            dayStart: jst("2026-10-18T04:00"))],
            templates: [], notEndedBy: jst("2026-10-19T11:00"))
        #expect(candidates.isEmpty)
    }

    @Test func addingACandidateUsesTheSameTimeAndLength() {
        let candidate = PlanCandidates.make(
            plan: PlanDraft(), dayStart: dayStart, calendar: tokyoCalendar,
            sources: [.init(source: .yesterday, plan: PlanDraft(blocks: [block("09:00", 45, study, day: "2026-10-18")]),
                            dayStart: jst("2026-10-18T04:00"))],
            templates: [], notEndedBy: nil)[0]
        var plan = PlanDraft()
        plan.upsert(candidate.blockToAdd)
        #expect(plan.blocks.map(\.start) == [jst("2026-10-19T09:00")])
        #expect(plan.blocks.first?.id != candidate.block.id)
        #expect(plan.blocks.map(\.minutes) == [45])
        #expect(candidate.sourceLabel == "昨日")
    }
}

/// 本体（AppModel）での習慣と候補。
@MainActor
struct HabitsModelTests {
    private func model(_ t: TestStore, settings: MemorySettings = MemorySettings(), offersHabitIntro: Bool = false) -> AppModel {
        AppModel(store: t.store, clock: t.clock, timeZone: { tokyo }, settings: settings, offersHabitIntro: offersHabitIntro)
    }

    private func plan(_ categories: [CategoryOption], day: String, games: [String]) -> PlanDraft {
        PlanDraft(blocks: [PlanBlockDraft(start: jst("\(day)T09:00"), minutes: 60, category: categories[0])]
                  + games.map { PlanBlockDraft.unblock(start: jst("\(day)T\($0)")) })
    }

    private func habits(_ categories: [CategoryOption]) -> PlanHabits {
        PlanHabits(blocks: [PlanTemplate.Block(hour: 7, minute: 0, minutes: 15, category: categories[4]),
                            PlanTemplate.Block(hour: 20, minute: 0, minutes: 30, category: .gameSNS)])
    }

    @Test func existingUserStartsWithCarriedGameTimesAsHabits() throws {
        let t = try TestStore(now: jst("2026-10-18T09:00"))
        let c = try t.seeded()
        try t.store.confirm(plan(c, day: "2026-10-18", games: ["20:00", "20:30"]), dayKey: "2026-10-18", timeZone: tokyo)
        t.clock.set(jst("2026-10-19T07:00"))
        let settings = MemorySettings()
        let m = model(t, settings: settings)
        #expect(m.showsHabitIntro == false)
        #expect(m.habits.blocks.map { [$0.hour, $0.minute] } == [[20, 0], [20, 30]])
        #expect(settings.habitsJSON != nil)
        #expect(m.morningPlan?.draft.blocks.map(\.start) == [jst("2026-10-19T20:00"), jst("2026-10-19T20:30")])

        // 次の起動からは習慣を使う（前の日から引き継がない）
        try t.store.skip(dayKey: "2026-10-19", timeZone: tokyo)
        t.clock.set(jst("2026-10-20T07:00"))
        let next = model(t, settings: settings)
        #expect(next.morningPlan?.draft.blocks.map(\.start) == [jst("2026-10-20T20:00"), jst("2026-10-20T20:30")])
    }

    @Test func existingUserWithoutPlansStartsWithNoHabits() throws {
        let t = try TestStore(now: jst("2026-10-18T09:00"))
        let c = try t.seeded()
        // 下書きだけの日は引き継がない
        try t.store.saveDraft(plan(c, day: "2026-10-18", games: ["21:00"]), dayKey: "2026-10-18", timeZone: tokyo)
        t.clock.set(jst("2026-10-19T07:00"))
        let settings = MemorySettings()
        let m = model(t, settings: settings)
        #expect(m.habits.blocks.isEmpty)
        #expect(settings.habitsJSON != nil)
    }

    @Test func migrationHappensOnlyOnce() throws {
        let t = try TestStore(now: jst("2026-10-18T09:00"))
        let c = try t.seeded()
        try t.store.confirm(plan(c, day: "2026-10-18", games: ["20:00"]), dayKey: "2026-10-18", timeZone: tokyo)
        t.clock.set(jst("2026-10-19T07:00"))
        let settings = MemorySettings()
        let m = model(t, settings: settings)
        // 習慣を空にしたら、次の起動で引き継ぎの時刻を入れ直さない
        m.saveHabits(PlanHabits())
        try t.store.skip(dayKey: "2026-10-19", timeZone: tokyo)
        t.clock.set(jst("2026-10-20T07:00"))
        let next = model(t, settings: settings)
        #expect(next.habits.blocks.isEmpty)
        #expect(next.morningPlan?.draft.blocks.isEmpty == true)
    }

    @Test func newDraftsStartWithHabits() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        let c = try t.seeded()
        let settings = MemorySettings()
        let m = model(t, settings: settings)
        m.saveHabits(habits(c))
        // 今日の計画（下書き）は変わらない
        #expect(m.morningPlan?.draft.blocks.isEmpty == true)
        // 明日の計画
        #expect(m.tomorrowPlan().draft.sortedBlocks.map(\.start) == [jst("2026-10-20T07:00"), jst("2026-10-20T20:00")])
        // 計画なし日にあとから作る計画
        m.skipPlan()
        m.openPlanOnNoPlanDay()
        #expect(m.morningPlan?.draft.sortedBlocks.map(\.start) == [jst("2026-10-19T07:00"), jst("2026-10-19T20:00")])
        // 次の朝
        t.clock.set(jst("2026-10-20T07:00"))
        let next = model(t, settings: settings)
        #expect(next.morningPlan?.draft.sortedBlocks.map(\.start) == [jst("2026-10-20T07:00"), jst("2026-10-20T20:00")])
    }

    @Test func archivedCategoryIsLeftOut() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        let c = try t.seeded()
        let settings = MemorySettings()
        let m = model(t, settings: settings)
        m.saveHabits(habits(c))
        try t.store.setCategoryArchived(id: c[4].id, true)
        t.clock.set(jst("2026-10-20T07:00"))
        let next = model(t, settings: settings)
        #expect(next.morningPlan?.draft.blocks.map(\.start) == [jst("2026-10-20T20:00")])
    }

    @Test func archivedProjectIsLeftOut() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        let c = try t.seeded()
        let english = try #require(try t.store.createProject(name: "英語", category: c[0]))
        let settings = MemorySettings()
        let m = model(t, settings: settings)
        m.saveHabits(PlanHabits(blocks: [PlanTemplate.Block(hour: 9, minute: 0, minutes: 60, category: c[0], project: english),
                                         PlanTemplate.Block(hour: 20, minute: 0, minutes: 30, category: .gameSNS)]))
        try t.store.setProjectArchived(id: english.id, true)
        t.clock.set(jst("2026-10-20T07:00"))
        let next = model(t, settings: settings)
        #expect(next.habits.blocks.count == 1)
        #expect(next.morningPlan?.draft.blocks.map(\.start) == [jst("2026-10-20T20:00")])
    }

    @Test func freshInstallAsksForHabitsBeforeTheMorningPlan() throws {
        let t = try TestStore(now: jst("2026-10-19T07:00"))
        let settings = MemorySettings()
        let m = model(t, settings: settings, offersHabitIntro: true)
        #expect(m.showsHabitIntro)
        #expect(m.morningPlan == nil)
        m.finishHabitIntro(habits(m.categories))
        #expect(!m.showsHabitIntro)
        #expect(m.morningPlan?.draft.sortedBlocks.map(\.start) == [jst("2026-10-19T07:00"), jst("2026-10-19T20:00")])
        // 2回目の起動では出さない
        let again = model(t, settings: settings, offersHabitIntro: true)
        #expect(!again.showsHabitIntro)
    }

    @Test func laterStartsWithoutHabits() throws {
        let t = try TestStore(now: jst("2026-10-19T07:00"))
        let settings = MemorySettings()
        let m = model(t, settings: settings, offersHabitIntro: true)
        m.finishHabitIntro(nil)
        #expect(!m.showsHabitIntro)
        #expect(m.habits.blocks.isEmpty)
        #expect(m.morningPlan?.draft.blocks.isEmpty == true)
    }

    @Test func introIsAskedAgainIfTheAppWasClosedBeforeDeciding() throws {
        let t = try TestStore(now: jst("2026-10-19T07:00"))
        let settings = MemorySettings()
        _ = model(t, settings: settings, offersHabitIntro: true)
        // 決める前に閉じた（カテゴリはもう入っている）
        let again = model(t, settings: settings, offersHabitIntro: true)
        #expect(again.showsHabitIntro)
    }

    @Test func noIntroWithoutTheOffer() throws {
        // 見本データ・UI テストなど（offersHabitIntro なし）では、空の端末でも出さない
        let t = try TestStore(now: jst("2026-10-19T07:00"))
        let m = model(t)
        #expect(!m.showsHabitIntro)
        #expect(m.morningPlan != nil)
    }

    @Test func candidatesUseConfirmedPlansAndTemplates() throws {
        let t = try TestStore(now: jst("2026-10-12T09:00"))
        let c = try t.seeded()
        try t.store.confirm(PlanDraft(blocks: [PlanBlockDraft(start: jst("2026-10-12T13:00"), minutes: 30, category: c[2])]),
                            dayKey: "2026-10-12", timeZone: tokyo)
        // 昨日は下書きのまま → 使わない
        try t.store.saveDraft(PlanDraft(blocks: [PlanBlockDraft(start: jst("2026-10-18T10:00"), minutes: 60, category: c[1])]),
                              dayKey: "2026-10-18", timeZone: tokyo)
        try t.store.saveTemplate(PlanTemplate(name: "平日", blocks: [PlanTemplate.Block(hour: 8, minute: 0, minutes: 60, category: c[0])]))
        t.clock.set(jst("2026-10-19T07:00"))
        let m = model(t)
        let morning = try #require(m.morningPlan)
        let candidates = m.candidates(for: morning.draft, dayStart: morning.dayStart, excludingEnded: false)
        #expect(candidates.map(\.sourceLabel) == ["平日", "先週の月曜"])
        #expect(candidates.map { $0.block.start } == [jst("2026-10-19T08:00"), jst("2026-10-19T13:00")])
        #expect(candidates.map(\.source) == [.template("平日"), .lastWeek])
    }

    @Test func tomorrowCandidatesUseTodayAndSixDaysAgo() throws {
        let t = try TestStore(now: jst("2026-10-14T09:00"))
        let c = try t.seeded()
        // 明日（10-20）の「先週」は 10-13、「昨日」は今日（10-19）
        try t.store.confirm(PlanDraft(blocks: [PlanBlockDraft(start: jst("2026-10-13T13:00"), minutes: 30, category: c[2])]),
                            dayKey: "2026-10-13", timeZone: tokyo)
        try t.store.confirm(PlanDraft(blocks: [PlanBlockDraft(start: jst("2026-10-14T15:00"), minutes: 30, category: c[2])]),
                            dayKey: "2026-10-14", timeZone: tokyo)
        t.clock.set(jst("2026-10-19T09:00"))
        let m = model(t)
        m.confirmPlan(PlanDraft(blocks: [PlanBlockDraft(start: jst("2026-10-19T10:00"), minutes: 60, category: c[0])]))
        t.clock.set(jst("2026-10-19T22:00"))
        let tomorrow = m.tomorrowPlan()
        let candidates = m.candidates(for: tomorrow.draft, dayStart: tomorrow.dayStart, excludingEnded: false)
            .filter { $0.source != .template("理想の休日") }
        #expect(candidates.map(\.source) == [.yesterday, .lastWeek])
        #expect(candidates.map(\.block.start) == [jst("2026-10-20T10:00"), jst("2026-10-20T13:00")])
        #expect(candidates.map(\.sourceLabel) == ["昨日", "先週の火曜"])
    }

    @Test func candidatesSkipArchivedCategoriesAndEndedOnesInTheTab() throws {
        let t = try TestStore(now: jst("2026-10-18T09:00"))
        let c = try t.seeded()
        try t.store.confirm(PlanDraft(blocks: [PlanBlockDraft(start: jst("2026-10-18T08:00"), minutes: 60, category: c[0]),
                                               PlanBlockDraft(start: jst("2026-10-18T13:00"), minutes: 60, category: c[1]),
                                               PlanBlockDraft(start: jst("2026-10-18T15:00"), minutes: 60, category: c[2])]),
                            dayKey: "2026-10-18", timeZone: tokyo)
        try t.store.setCategoryArchived(id: c[1].id, true)
        t.clock.set(jst("2026-10-19T11:00"))
        let m = model(t)
        m.confirmPlan(PlanDraft(blocks: [PlanBlockDraft(start: jst("2026-10-19T10:00"), minutes: 30, category: c[0])]))
        let plan = try #require(m.plan)
        let candidates = m.candidates(for: plan, dayStart: m.snapshot.dayStart, excludingEnded: true).filter { $0.source == .yesterday }
        #expect(candidates.map(\.block.start) == [jst("2026-10-19T15:00")])
    }
}
