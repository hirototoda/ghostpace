import Foundation
import Testing
@testable import FocusApp

@MainActor
struct AppModelTests {
    private func model(_ t: TestStore, timeZone: @escaping () -> TimeZone = { tokyo }) -> AppModel {
        AppModel(store: t.store, clock: t.clock, timeZone: timeZone)
    }

    private func block(_ start: String, _ minutes: Int, _ category: CategoryOption) -> PlanBlockDraft {
        PlanBlockDraft(start: jst(start), minutes: minutes, category: category)
    }

    @Test func seedsCategoriesOnLaunch() throws {
        let t = try TestStore()
        let m = model(t)
        #expect(m.categories.count == 6)
    }

    @Test func morningPlanShownWhenNoneOrDraft() throws {
        let t = try TestStore(now: jst("2026-10-19T09:10"))
        let m = model(t)
        #expect(m.morningPlan?.dayKey == "2026-10-19")
        #expect(m.morningPlan?.dayStart == jst("2026-10-19T04:00"))

        m.saveDraft(PlanDraft(blocks: [block("2026-10-19T09:10", 60, m.categories[0])]))
        let reopened = model(t)
        #expect(reopened.morningPlan?.draft.blocks.count == 1)

        reopened.confirmPlan(reopened.morningPlan!.draft)
        #expect(reopened.morningPlan == nil)
        #expect(model(t).morningPlan == nil)
        #expect(model(t).plan?.blocks.count == 1)
    }

    @Test func skipMakesNoPlanDay() throws {
        let t = try TestStore(now: jst("2026-10-19T09:10"))
        let m = model(t)
        m.skipPlan()
        #expect(m.morningPlan == nil)
        #expect(m.plan == nil)
        #expect(m.snapshot.isNoPlanDay)
        #expect(model(t).morningPlan == nil)
    }

    @Test func morningPlanDayBoundary() throws {
        let t = try TestStore(now: jst("2026-10-18T09:00"))
        model(t).skipPlan()

        t.clock.set(jst("2026-10-19T03:59"))
        #expect(model(t).morningPlan == nil)
        t.clock.set(jst("2026-10-19T04:00"))
        let m = model(t)
        #expect(m.morningPlan?.dayKey == "2026-10-19")
    }

    @Test func morningPlanWaitsForRunning() throws {
        let t = try TestStore(now: jst("2026-10-19T03:30"))
        let m = model(t)
        m.skipPlan()
        m.startUnplanned(category: m.categories[0], minutes: nil)
        t.clock.set(jst("2026-10-19T04:10"))
        m.reload()
        #expect(m.running != nil)
        #expect(m.morningPlan == nil)

        m.end(reportedEnd: t.clock.now())
        #expect(m.running == nil)
        #expect(m.morningPlan?.dayKey == "2026-10-19")
    }

    @Test func morningPlanKeepsOpeningDayKey() throws {
        let t = try TestStore(now: jst("2026-10-19T03:55"))
        let m = model(t)
        #expect(m.morningPlan?.dayKey == "2026-10-18")

        t.clock.set(jst("2026-10-19T04:05"))
        m.reload()
        #expect(m.morningPlan?.dayKey == "2026-10-18")
        m.confirmPlan(PlanDraft(blocks: [block("2026-10-19T03:00", 30, m.categories[0])]))

        #expect(try t.store.plan(dayKey: "2026-10-18")?.status == .confirmed)
        #expect(try t.store.plan(dayKey: "2026-10-19") == nil)
        #expect(m.morningPlan?.dayKey == "2026-10-19")
    }

    @Test func reloadUsesProvidedTimeZone() throws {
        // 10/19 01:00 UTC は東京では 10:00（10/19）、ニューヨークでは 10/18 21:00
        let t = try TestStore(now: Date(timeIntervalSince1970: 1_792_371_600))
        var zone = tokyo
        let m = model(t, timeZone: { zone })
        #expect(m.morningPlan?.dayKey == "2026-10-19")
        m.skipPlan()

        zone = TimeZone(identifier: "America/New_York")!
        m.reload()
        #expect(m.morningPlan?.dayKey == "2026-10-18")
    }

    @Test func runningTimerGoalUsesTheSameSleepAsHome() throws {
        // 今日は 8:00 に起きた（手で直した）、今夜は設定の 0:00。9:00–12:00 勉強・17:00–18:00 休み、目標6時間
        // → 空き 8:00–9:00・12:00–17:00・18:00–0:00（12時間）に3時間 → 18:00 に 3時間＋6時間×1/4 ＝ 4時間30分（GHO-10）
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        try t.store.saveSleep(SleepLine(start: jst("2026-10-19T00:00"), end: jst("2026-10-19T08:00"), source: .manual),
                              dayKey: "2026-10-19", timeZone: tokyo)
        let m = model(t)
        m.confirmPlan(PlanDraft(blocks: [block("2026-10-19T09:00", 180, m.categories[0]),
                                         block("2026-10-19T17:00", 60, m.categories[4])], goalSeconds: 6 * 3600))
        m.startUnplanned(category: m.categories[0], minutes: nil)
        let running = try #require(m.running?.goal)
        let home = try #require(m.snapshot.goal)
        #expect(running.focusSeconds(at: jst("2026-10-19T18:00")) == 270 * 60)
        #expect(home.focusSeconds(at: jst("2026-10-19T18:00")) == 270 * 60)
    }

    /// 遅れて始めると終わりは計画の長さぶん後ろ（TMR-15、2026-10-06。それまではブロックの終わり）
    @Test func startPlannedLateShiftsTheEnd() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        let m = model(t)
        m.confirmPlan(PlanDraft(blocks: [block("2026-10-19T09:00", 70, m.categories[0])]))
        t.clock.set(jst("2026-10-19T09:20"))
        m.reload()
        let current = try #require(m.snapshot.currentBlock)
        m.startPlanned(block: current)

        let running = try #require(m.running)
        #expect(running.session.plannedEndAt == jst("2026-10-19T10:30"))
        #expect(running.session.planBlockId == current.id)
        #expect(running.remainingSeconds(at: t.clock.now()) == 70 * 60)
    }

    @Test func startUnplannedUsesLength() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        let m = model(t)
        m.skipPlan()
        m.startUnplanned(category: m.categories[4], minutes: 25)
        #expect(m.running?.session.plannedDurationSec == 1500)
        #expect(m.running?.countsAsFocus == false)
    }

    @Test func pauseAndResumeUpdateRunning() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        let m = model(t)
        m.skipPlan()
        m.startUnplanned(category: m.categories[0], minutes: 25)
        t.clock.set(jst("2026-10-19T09:10"))
        m.pause()
        #expect(m.running?.session.isPaused == true)
        t.clock.set(jst("2026-10-19T09:15"))
        m.resume()
        #expect(m.running?.session.isPaused == false)
        // 25分のうち10分集中、5分停止 → 残り15分
        #expect(m.running?.remainingSeconds(at: t.clock.now()) == 15 * 60)
    }

    @Test func requestEndAsksOnlyWhenForgot() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        let m = model(t)
        m.skipPlan()
        m.startUnplanned(category: m.categories[0], minutes: 25)
        t.clock.set(jst("2026-10-19T09:30"))
        m.requestEnd()
        #expect(m.endTimeCheck == nil)
        #expect(m.running == nil)

        m.startUnplanned(category: m.categories[0], minutes: 25)
        t.clock.set(jst("2026-10-19T14:00"))
        m.requestEnd()
        let check = try #require(m.endTimeCheck)
        #expect(check.initialEnd == jst("2026-10-19T09:55"))
        #expect(check.startAt == jst("2026-10-19T09:30"))
        #expect(m.running != nil)

        m.end(reportedEnd: check.initialEnd)
        #expect(m.endTimeCheck == nil)
        #expect(m.running == nil)
        #expect(m.snapshot.focusSeconds == 55 * 60)
    }

    /// 本物の時計は読むたびに進む。普通に終えただけで「終了時刻を早めた」印が付かないこと
    @Test func normalEndHasNoOriginalEnd() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        let clock = TickingClock(jst("2026-10-19T09:00"))
        let store = SwiftDataStore(container: t.container, clock: clock)
        let m = AppModel(store: store, clock: clock, timeZone: { tokyo })
        m.skipPlan()
        m.startUnplanned(category: m.categories[0], minutes: 25)
        clock.advance(25 * 60)
        m.requestEnd()
        #expect(m.running == nil)
        let ended = try #require(try store.sessions(dayKey: "2026-10-19").first)
        #expect(ended.originalEndAt == nil)
    }

    @Test func requestEndInitialEndIsClampedToNow() throws {
        // 3:50 開始・25分：4:05 に4:00をまたいだので聞く。予定の終わり（4:15）はまだ先なので、初期値は今
        let t = try TestStore(now: jst("2026-10-19T03:50"))
        let m = model(t)
        m.skipPlan()
        m.startUnplanned(category: m.categories[0], minutes: 25)
        t.clock.set(jst("2026-10-19T04:05"))
        m.requestEnd()
        let check = try #require(m.endTimeCheck)
        #expect(check.initialEnd == jst("2026-10-19T04:05"))
        #expect(check.range == jst("2026-10-19T03:51")...jst("2026-10-19T04:05"))
        #expect(check.range.contains(check.initialEnd))
    }

    @Test func noPlanDayCanCreatePlanLater() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        let m = model(t)
        m.skipPlan()
        #expect(m.snapshot.isNoPlanDay)

        // 開いて閉じれば計画なしのまま
        m.openPlanOnNoPlanDay()
        #expect(m.morningPlan?.dayKey == "2026-10-19")
        m.skipPlan()
        #expect(m.morningPlan == nil)
        #expect(m.snapshot.isNoPlanDay)

        m.openPlanOnNoPlanDay()
        m.confirmPlan(PlanDraft(blocks: [block("2026-10-19T09:10", 60, m.categories[0])]))
        #expect(m.morningPlan == nil)
        #expect(!m.snapshot.isNoPlanDay)
        #expect(try t.store.plan(dayKey: "2026-10-19")?.status == .confirmed)
        #expect(try t.store.snapshot(dayKey: "2026-10-19")?.count == 1)
    }

    @Test func removedBlockLeavesHome() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        let m = model(t)
        let a = block("2026-10-19T10:00", 60, m.categories[0])
        let b = block("2026-10-19T12:00", 60, m.categories[1])
        m.confirmPlan(PlanDraft(blocks: [a, b]))
        #expect(m.snapshot.nextBlock?.id == a.id)

        #expect(m.savePlanChanges(PlanDraft(blocks: [b])))
        #expect(m.snapshot.nextBlock?.id == b.id)
        #expect(m.snapshot.plannedFocusSeconds == 60 * 60)
    }

    @Test func quietReloadDoesNotShowError() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        let m = model(t)
        m.reload(quietly: true)
        #expect(m.errorMessage == nil)
    }

    // MARK: タイムライン

    @Test func timelineDaysGoBackButNotForward() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        let m = model(t)
        m.confirmPlan(PlanDraft(blocks: [block("2026-10-19T10:00", 60, m.categories[0])]))
        #expect(m.timelineDay(daysAgo: 0)?.dayKey == "2026-10-19")
        #expect(m.timelineDay(daysAgo: 0)?.planBlocks.count == 1)
        #expect(m.timelineDay(daysAgo: 1)?.dayKey == "2026-10-18")
        #expect(m.timelineDay(daysAgo: 1)?.isNoPlanDay == true)
        #expect(m.timelineDay(daysAgo: -1) == nil)
        #expect(m.timelineDay(daysAgo: 0)?.isToday == true)
        #expect(m.timelineDay(daysAgo: 1)?.isToday == false)
    }

    @Test func timelineAt0359ShowsPreviousDayAsToday() throws {
        let t = try TestStore(now: jst("2026-10-20T03:59"))
        let m = model(t)
        let day = try #require(m.timelineDay(daysAgo: 0))
        #expect(day.dayKey == "2026-10-19")
        #expect(day.editableDayKeys == ["2026-10-19", "2026-10-18"])
    }

    @Test func shortenEndOnlyForTodayAndYesterday() throws {
        let t = try TestStore(now: jst("2026-10-17T09:00"))
        let m = model(t)
        m.skipPlan()
        m.startUnplanned(category: m.categories[0], minutes: nil)
        t.clock.set(jst("2026-10-17T10:00"))
        m.requestEnd()
        let old = try #require(try t.store.sessions(dayKey: "2026-10-17").first)

        // 2日後（10/19）には直せない
        t.clock.set(jst("2026-10-19T09:00"))
        #expect(!m.shortenEnd(old, to: jst("2026-10-17T09:30")))
        #expect(try t.store.sessions(dayKey: "2026-10-17").first?.endAt == jst("2026-10-17T10:00"))

        // 翌日（10/18）なら直せる
        t.clock.set(jst("2026-10-18T09:00"))
        #expect(m.shortenEnd(old, to: jst("2026-10-17T09:30")))
        #expect(try t.store.sessions(dayKey: "2026-10-17").first?.endAt == jst("2026-10-17T09:30"))
    }

    @Test func sessionCrossing4amBelongsToStartDay() throws {
        let t = try TestStore(now: jst("2026-10-19T03:30"))
        let m = model(t)
        m.skipPlan()
        m.startUnplanned(category: m.categories[0], minutes: nil)
        t.clock.set(jst("2026-10-19T04:30"))
        m.end(reportedEnd: nil)
        // 4:30 に見ると、今日（10/19）ではなく昨日（10/18）の記録。合計も開始した日で1時間
        let today = try #require(m.timelineDay(daysAgo: 0))
        let yesterday = try #require(m.timelineDay(daysAgo: 1))
        #expect(today.sessions.isEmpty)
        #expect(yesterday.sessions.count == 1)
        #expect(yesterday.focusSeconds == 60 * 60)
        #expect(yesterday.unplannedSessions.count == 1)
        // 円の集中時間は 4:00 で区切る：今日（10/19 の日）は 4:00〜4:30 の30分（2026-10-03）
        #expect(m.snapshot.focusSeconds == 30 * 60)
    }

    @Test func shortenEndRechecksAtSaveAfter4am() throws {
        // 10/18 の記録を 10/19 3:59 に開く（昨日なので直せる）→ 4:00 を過ぎてから保存すると一昨日になるので直せない
        let t = try TestStore(now: jst("2026-10-18T09:00"))
        let m = model(t)
        m.skipPlan()
        m.startUnplanned(category: m.categories[0], minutes: nil)
        t.clock.set(jst("2026-10-18T10:00"))
        m.requestEnd()
        t.clock.set(jst("2026-10-20T03:59"))
        let opened = try #require(m.timelineDay(daysAgo: 1)?.sessions.first)
        #expect(m.timelineDay(daysAgo: 1)?.canEdit(opened) == true)

        t.clock.set(jst("2026-10-20T04:00"))
        #expect(!m.shortenEnd(opened, to: jst("2026-10-18T09:30")))
        #expect(m.errorMessage == AppModel.cannotEditMessage)
        #expect(try t.store.sessions(dayKey: "2026-10-18").first?.endAt == jst("2026-10-18T10:00"))
    }

    @Test func shortenEndRejectsRunningSession() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        let m = model(t)
        m.skipPlan()
        m.startUnplanned(category: m.categories[0], minutes: nil)
        t.clock.set(jst("2026-10-19T10:00"))
        let running = try #require(m.running?.session)
        #expect(!m.shortenEnd(running, to: jst("2026-10-19T09:30")))
        #expect(m.running != nil)
    }

    @Test func timelineOfSkippedDayKeepsSessionsAsUnplanned() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        let m = model(t)
        m.skipPlan()
        m.startUnplanned(category: m.categories[0], minutes: nil)
        t.clock.set(jst("2026-10-19T10:00"))
        m.requestEnd()
        let day = try #require(m.timelineDay(daysAgo: 0))
        #expect(day.isNoPlanDay)
        #expect(day.planBlocks.isEmpty)
        #expect(day.unplannedSessions.count == 1)
    }

    @Test func shortenEndFailureShowsError() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        let m = model(t)
        m.skipPlan()
        m.startUnplanned(category: m.categories[0], minutes: nil)
        t.clock.set(jst("2026-10-19T10:00"))
        m.requestEnd()
        let s = try #require(try t.store.sessions(dayKey: "2026-10-19").first)
        t.store.saveHook = { throw TestFailure() }
        #expect(!m.shortenEnd(s, to: jst("2026-10-19T09:30")))
        #expect(m.errorMessage == AppModel.saveErrorMessage)
    }

    @Test func discardedShowsNotice() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        let m = model(t)
        m.skipPlan()
        m.startUnplanned(category: m.categories[0], minutes: nil)
        t.clock.advance(10)
        m.requestEnd()
        #expect(m.notice == "1分未満なので記録しませんでした")
        #expect(m.running == nil)
    }

    @Test func saveFailureShowsErrorAndAllowsRetry() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        let m = model(t)
        m.skipPlan()
        m.startUnplanned(category: m.categories[0], minutes: nil)
        t.clock.set(jst("2026-10-19T09:30"))

        t.store.saveHook = { throw TestFailure() }
        m.requestEnd()
        #expect(m.errorMessage == "保存できませんでした")
        #expect(m.running != nil)

        t.store.saveHook = nil
        m.errorMessage = nil
        m.requestEnd()
        #expect(m.errorMessage == nil)
        #expect(m.running == nil)
    }

    @Test func createProjectUpdatesList() throws {
        let t = try TestStore()
        let m = model(t)
        let project = m.createProject(name: "ゼミ準備", category: m.categories[0])
        #expect(project?.name == "ゼミ準備")
        // デフォルトのブロック名（家事・休み）のほかに増える
        #expect(m.projects.filter { $0.category == m.categories[0] }.map(\.name) == ["ゼミ準備"])
    }

    @Test func endAddsFocusToSnapshot() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        let m = model(t)
        m.skipPlan()
        m.startUnplanned(category: m.categories[0], minutes: nil)
        t.clock.set(jst("2026-10-19T09:23"))
        m.requestEnd()
        #expect(m.snapshot.focusSeconds == 23 * 60)
    }

    @Test func runningRestoredOnLaunch() throws {
        let t = try TestStore(now: jst("2026-10-19T10:00"))
        let first = model(t)
        first.skipPlan()
        first.startUnplanned(category: first.categories[0], minutes: nil)

        t.clock.set(jst("2026-10-19T10:30"))
        let relaunched = model(t)
        #expect(relaunched.running?.elapsedSeconds(at: t.clock.now()) == 30 * 60)
    }

    @Test func ghostFromLastWeek() throws {
        let t = try TestStore(now: jst("2026-10-12T09:00"))
        let m = model(t)
        m.skipPlan()
        m.startUnplanned(category: m.categories[0], minutes: nil)
        t.clock.set(jst("2026-10-12T10:00"))
        m.requestEnd()

        t.clock.set(jst("2026-10-19T09:30"))
        m.reload()
        #expect(m.snapshot.ghostFocusSeconds == 30 * 60)
        #expect(m.snapshot.ghost?.wholeDayFocusSeconds == 60 * 60)
    }
}
