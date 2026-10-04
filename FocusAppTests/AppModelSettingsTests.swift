import Foundation
import Testing
@testable import FocusApp

/// 設定・通知・振り返り・明日の計画（settings.md、review.md、focus-timer.md TMR-05）。
@MainActor
struct AppModelSettingsTests {
    private func model(_ t: TestStore, settings: MemorySettings = MemorySettings(),
                       notifications: NoNotifications = NoNotifications()) -> AppModel {
        AppModel(store: t.store, clock: t.clock, timeZone: { tokyo }, settings: settings, notifications: notifications)
    }

    private func block(_ start: String, _ minutes: Int, _ category: CategoryOption) -> PlanBlockDraft {
        PlanBlockDraft(start: jst(start), minutes: minutes, category: category)
    }

    // MARK: カテゴリの組み替え（CAT-01、2026-10-03）

    /// 2026-10-03 より前のデフォルトの端末
    private func oldDevice() throws -> TestStore {
        let t = try TestStore()
        for (name, focus) in [("勉強", true), ("仕事", true), ("読書", true), ("掃除", false), ("休み", false), ("料理", false),
                              ("運動", false), ("瞑想", false)] {
            _ = try t.store.createCategory(name: name, countsAsFocus: focus, detoxGroup: nil)
        }
        return t
    }

    @Test func regroupRunsOnceAtLaunch() throws {
        let t = try oldDevice()
        let settings = MemorySettings()
        let m = model(t, settings: settings)
        #expect(m.categories.map(\.name) == ["勉強", "仕事", "読書", "家事", "休み", "運動"])
        #expect(settings.didRegroupDetoxCategories)
        // 覚えているので、あとで「掃除」を作っても組み替え直さない
        _ = try t.store.createCategory(name: "掃除", countsAsFocus: false, detoxGroup: nil)
        let again = model(t, settings: settings)
        #expect(again.categories.contains { $0.name == "掃除" })
    }

    @Test func regroupFailureIsRetriedNextLaunch() throws {
        let t = try oldDevice()
        let settings = MemorySettings()
        t.store.saveHook = { throw CocoaError(.fileWriteUnknown) }
        let failed = model(t, settings: settings)
        #expect(!settings.didRegroupDetoxCategories)
        #expect(failed.categories.contains { $0.name == "掃除" })
        t.store.saveHook = nil
        let m = model(t, settings: settings)
        #expect(settings.didRegroupDetoxCategories)
        #expect(m.categories.contains { $0.name == "家事" })
    }

    // MARK: 通知の説明（TMR-05）

    @Test func introShownOnceAfterFirstConfirm() throws {
        let t = try TestStore(now: jst("2026-10-19T07:00"))
        let settings = MemorySettings()
        let m = model(t, settings: settings)
        m.confirmPlan(PlanDraft(blocks: [block("2026-10-19T09:00", 60, m.categories[0])]))
        #expect(m.showsNotificationIntro)
        m.postponeNotifications()
        #expect(!m.showsNotificationIntro)
        #expect(settings.didShowNotificationIntro)

        t.clock.set(jst("2026-10-20T07:00"))
        let next = model(t, settings: settings)
        next.confirmPlan(PlanDraft(blocks: [block("2026-10-20T09:00", 60, next.categories[0])]))
        #expect(!next.showsNotificationIntro)
    }

    @Test func skippingDoesNotShowIntro() throws {
        let t = try TestStore(now: jst("2026-10-19T07:00"))
        let m = model(t)
        m.skipPlan()
        #expect(!m.showsNotificationIntro)
    }

    @Test func enablingAsksAndSchedules() async throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        let notifications = NoNotifications()
        let m = model(t, notifications: notifications)
        await m.refreshNotificationStatus()
        #expect(notifications.scheduled.isEmpty)  // 許可がないあいだは予約しない

        await m.enableNotifications()
        #expect(notifications.requestCount == 1)
        #expect(m.notificationStatus == .authorized)
        #expect(notifications.scheduled.map(\.id) == [AppNotification.reviewID])

        m.startUnplanned(category: m.categories[0], minutes: 25)
        #expect(notifications.scheduled.first { $0.id == AppNotification.plannedEndID }?.trigger == .at(jst("2026-10-19T09:25")))
        m.pause()
        #expect(!notifications.scheduled.contains { $0.id == AppNotification.plannedEndID })
        t.clock.advance(300)
        m.resume()
        #expect(notifications.scheduled.first { $0.id == AppNotification.plannedEndID }?.trigger == .at(jst("2026-10-19T09:30")))
        t.clock.advance(120)
        m.end(reportedEnd: nil)
        #expect(!notifications.scheduled.contains { $0.id == AppNotification.plannedEndID })
    }

    @Test func turningOffPlannedEndKeepsReview() async throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        let notifications = NoNotifications(status: .authorized)
        let m = model(t, notifications: notifications)
        await m.refreshNotificationStatus()
        m.startUnplanned(category: m.categories[0], minutes: 25)
        m.setPlannedEndNotifications(false)
        #expect(notifications.scheduled.map(\.id) == [AppNotification.reviewID])
        m.setReviewMinutes(21 * 60)
        #expect(notifications.scheduled.first?.trigger == .daily(minutes: 21 * 60))
    }

    // MARK: 振り返りの入口（REV-02）

    @Test func reviewEntryFollowsSettingUntil4AM() throws {
        let t = try TestStore(now: jst("2026-10-19T21:30"))
        let settings = MemorySettings()
        let m = model(t, settings: settings)
        #expect(!m.snapshot.showsReviewEntry)
        m.setReviewMinutes(21 * 60)
        #expect(m.snapshot.showsReviewEntry)
        #expect(settings.reviewMinutes == 21 * 60)

        t.clock.set(jst("2026-10-20T03:59"))
        m.reload()
        #expect(m.snapshot.showsReviewEntry)
        t.clock.set(jst("2026-10-20T04:00"))
        m.reload()
        #expect(!m.snapshot.showsReviewEntry)
    }

    @Test func reviewTimeAfterMidnightBelongsToThatNight() throws {
        let t = try TestStore(now: jst("2026-10-19T23:30"))
        let m = model(t)
        m.setReviewMinutes(60)  // 1:00
        #expect(!m.snapshot.showsReviewEntry)
        t.clock.set(jst("2026-10-20T01:00"))
        m.reload()
        #expect(m.snapshot.showsReviewEntry)
    }

    // MARK: 夜の振り返り（REV-01）

    @Test func reviewComparesWithMorningSnapshot() throws {
        let t = try TestStore(now: jst("2026-10-19T07:00"))
        let m = model(t)
        let study = m.categories[0], reading = m.categories[2]
        m.confirmPlan(PlanDraft(blocks: [block("2026-10-19T09:00", 120, study), block("2026-10-19T23:00", 30, reading)]))
        let planned = try #require(m.plan?.summaries.first)
        t.clock.set(jst("2026-10-19T09:00"))
        m.startPlanned(block: planned)
        t.clock.set(jst("2026-10-19T09:30"))
        m.end(reportedEnd: nil)
        // 日中に勉強のブロックを消しても、朝の計画と比べる
        m.savePlanChanges(PlanDraft(blocks: m.plan!.blocks.filter { $0.category == reading }))
        t.clock.set(jst("2026-10-19T22:30"))
        m.reload()

        let review = try #require(m.reviewContent())
        #expect(review.focusSeconds == 30 * 60)
        #expect(review.categories.map(\.name) == ["勉強"])
        #expect(review.gaps.map(\.diffSeconds) == [-90 * 60])  // 23:00 の読書はまだ来ていない
        #expect(!review.isNoPlanDay)
        #expect(review.opponents.map(\.opponent) == [.goal])  // 先週の記録はない。目標は今の計画（読書30分）
        #expect(review.opponents.first?.theirSeconds == 0)
    }

    @Test func reviewOnNoPlanDay() throws {
        let t = try TestStore(now: jst("2026-10-19T07:00"))
        let m = model(t)
        m.skipPlan()
        t.clock.set(jst("2026-10-19T22:30"))
        m.reload()
        let review = try #require(m.reviewContent())
        #expect(review.isNoPlanDay)
        #expect(review.gaps.isEmpty)
        #expect(review.opponents.isEmpty)
        #expect(review.focusSeconds == 0)
    }

    // MARK: 明日の計画（REV-01）

    @Test func tomorrowDraftBecomesNextMorningPlan() throws {
        let t = try TestStore(now: jst("2026-10-19T22:30"))
        let m = model(t)
        m.skipPlan()
        let tomorrow = m.tomorrowPlan()
        #expect(tomorrow.dayKey == "2026-10-20")
        #expect(tomorrow.dayStart == jst("2026-10-20T04:00"))
        m.saveTomorrowDraft(PlanDraft(blocks: [block("2026-10-20T08:00", 60, m.categories[0])]), for: tomorrow)
        #expect(m.tomorrowPlan().draft.blocks.count == 1)  // 続きから

        t.clock.set(jst("2026-10-20T03:59"))
        m.reload()
        #expect(m.morningPlan == nil)
        t.clock.set(jst("2026-10-20T04:00"))
        m.reload()
        #expect(m.morningPlan?.dayKey == "2026-10-20")
        #expect(m.morningPlan?.draft.blocks.first?.start == jst("2026-10-20T08:00"))
    }

    @Test func tomorrowAfterMidnightIsTheComingMorning() throws {
        let t = try TestStore(now: jst("2026-10-20T01:30"))  // 10/19 の夜中
        let m = model(t)
        #expect(m.tomorrowPlan().dayKey == "2026-10-20")
    }

    // MARK: 対戦相手（GHO-10）

    @Test func opponentIsRemembered() throws {
        let t = try TestStore()
        let settings = MemorySettings()
        let m = model(t, settings: settings)
        #expect(m.opponent == .lastWeek)
        m.selectOpponent(.goal)
        #expect(model(t, settings: settings).opponent == .goal)
    }

    @Test func timerDiffAgainstGoal() throws {
        let t = try TestStore(now: jst("2026-10-19T07:00"))
        let m = model(t)
        m.confirmPlan(PlanDraft(blocks: [block("2026-10-19T09:00", 60, m.categories[0])]))
        t.clock.set(jst("2026-10-19T09:30"))
        m.startUnplanned(category: m.categories[0], minutes: nil)
        t.clock.set(jst("2026-10-19T09:40"))
        let timer = try #require(m.running)
        // 目標は 9:40 までに40分、自分は10分
        #expect(timer.opponentDiffSeconds(.goal, at: jst("2026-10-19T09:40")) == -30 * 60)
        #expect(timer.opponentDiffSeconds(.lastWeek, at: jst("2026-10-19T09:40")) == nil)
        #expect(timer.effectiveOpponent(.lastWeek) == .goal)
    }

    // MARK: カテゴリの失敗の理由

    @Test func categoryErrorsShowReasons() throws {
        let t = try TestStore()
        let m = model(t)
        #expect(!m.updateCategory(m.categories[0], name: "仕事", countsAsFocus: true))
        #expect(m.errorMessage == AppModel.duplicateNameMessage)
        m.errorMessage = nil
        #expect(m.createCategory(name: " ", countsAsFocus: true) == nil)
        #expect(m.errorMessage == AppModel.emptyNameMessage)
        m.errorMessage = nil
        let piano = try #require(m.createCategory(name: "ピアノ", countsAsFocus: true))
        #expect(m.categories.contains(piano))
    }

    // MARK: レビューで足したもの

    @Test func deniedOrUndecidedSchedulesNothing() async throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        let notifications = NoNotifications(status: .denied)
        let m = model(t, notifications: notifications)
        await m.refreshNotificationStatus()
        m.startUnplanned(category: m.categories[0], minutes: 25)
        #expect(m.notificationStatus == .denied)
        #expect(notifications.scheduled.isEmpty)
        // 断ったあとに「オンにする」を押しても、iPhone の許可は変わらない（設定アプリへ案内する）
        await m.enableNotifications()
        #expect(notifications.scheduled.isEmpty)
    }

    @Test func plannedEndPassedIsNotScheduled() async throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        let notifications = NoNotifications(status: .authorized)
        let m = model(t, notifications: notifications)
        await m.refreshNotificationStatus()
        m.startUnplanned(category: m.categories[0], minutes: 25)
        t.clock.set(jst("2026-10-19T09:40"))  // 超過中
        m.reload()
        #expect(notifications.scheduled.map(\.id) == [AppNotification.reviewID])
        #expect(m.running != nil)
    }

    @Test func tomorrowDraftMadeAfterMidnightAppearsThatMorning() throws {
        let t = try TestStore(now: jst("2026-10-20T02:30"))  // 10/19 の夜中
        let m = model(t)
        m.skipPlan()  // 10/19 は計画なし日として終わっている
        let tomorrow = m.tomorrowPlan()
        m.saveTomorrowDraft(PlanDraft(blocks: [block("2026-10-20T08:00", 30, m.categories[2])]), for: tomorrow)
        t.clock.set(jst("2026-10-20T04:00"))
        m.reload()
        #expect(m.morningPlan?.dayKey == "2026-10-20")
        #expect(m.morningPlan?.draft.blocks.map(\.start) == [jst("2026-10-20T08:00")])
    }

    @Test func tomorrowDraftSaveFailureIsReported() throws {
        let t = try TestStore(now: jst("2026-10-19T22:30"))
        let m = model(t)
        let tomorrow = m.tomorrowPlan()
        t.store.saveHook = { throw TestFailure() }
        #expect(!m.saveTomorrowDraft(PlanDraft(blocks: [block("2026-10-20T08:00", 30, m.categories[0])]), for: tomorrow))
        #expect(m.errorMessage == AppModel.saveErrorMessage)
        t.store.saveHook = nil
        #expect(m.tomorrowPlan().draft.blocks.isEmpty)
    }

    @Test func planTabSaveFailureKeepsStoredPlanAndSnapshot() throws {
        let t = try TestStore(now: jst("2026-10-19T07:00"))
        let m = model(t)
        let planned = PlanDraft(blocks: [block("2026-10-19T09:00", 60, m.categories[0])])
        m.confirmPlan(planned)
        t.store.saveHook = { throw TestFailure() }
        #expect(!m.savePlanChanges(PlanDraft(blocks: [])))
        #expect(m.errorMessage == AppModel.saveErrorMessage)
        // 画面は保存されている計画に戻る（計画のタブは storedPlan に合わせる）
        #expect(m.plan?.blocks.count == 1)
        t.store.saveHook = nil
        #expect(m.savePlanChanges(PlanDraft(blocks: [])))
        #expect(try t.store.snapshot(dayKey: "2026-10-19")?.count == 1)  // 朝の計画は変わらない
    }

    @Test func categoryArchiveFailureShowsReason() throws {
        let t = try TestStore()
        let m = model(t)
        for category in m.categories.dropLast() { #expect(m.setCategoryArchived(category, true)) }
        #expect(!m.setCategoryArchived(m.categories[0], true))
        #expect(m.errorMessage == AppModel.lastCategoryMessage)
        #expect(m.categories.count == 1)
    }

    @Test func reviewKeepsDetoxOutOfFocus() throws {
        let t = try TestStore(now: jst("2026-10-19T07:00"))
        let m = model(t)
        m.skipPlan()
        t.clock.set(jst("2026-10-19T08:00"))
        m.startUnplanned(category: m.categories[4], minutes: nil)  // 休み
        t.clock.set(jst("2026-10-19T08:30"))
        m.end(reportedEnd: nil)
        t.clock.set(jst("2026-10-19T22:30"))
        m.reload()
        let review = try #require(m.reviewContent())
        #expect(review.focusSeconds == 0)
        // 開けた時間はブロックの記録から（DTX-05）。ブロックを始めていなければ出さない。カテゴリの棒はタイマーの時間のまま
        #expect(review.opened == nil)
        #expect(review.categories.map(\.name) == ["休み"])
        #expect(review.categories.first?.seconds == 30 * 60)
        #expect(review.categories.first?.countsAsFocus == false)
    }
}

/// 目標とテンプレート（GHO-10、PLN-07）。
@MainActor
struct AppModelGoalTemplateTests {
    private func model(_ t: TestStore, settings: MemorySettings = MemorySettings()) -> AppModel {
        AppModel(store: t.store, clock: t.clock, timeZone: { tokyo }, settings: settings)
    }

    private func block(_ start: String, _ minutes: Int, _ category: CategoryOption) -> PlanBlockDraft {
        PlanBlockDraft(start: jst(start), minutes: minutes, category: category)
    }

    @Test func manualGoalDrivesHomeAndTimer() throws {
        let t = try TestStore(now: jst("2026-10-19T07:00"))
        let m = model(t)
        var draft = PlanDraft(blocks: [block("2026-10-19T09:00", 60, m.categories[0]), block("2026-10-19T11:00", 60, m.categories[0])])
        // 計画より1時間多い → 起きている 7:00〜0:00（設定の睡眠）の空き 7:00–9:00・10:00–11:00・12:00–0:00（15時間）に足す
        draft.goalSeconds = 3 * 3600
        m.confirmPlan(draft)
        t.clock.set(jst("2026-10-19T10:30"))
        m.reload()
        #expect(m.snapshot.goal?.goalSeconds == 3 * 3600)
        #expect(m.snapshot.opponentFocusSeconds(.goal) == 70 * 60)  // 2.5時間×4分＋60分
        #expect(model(t).plan?.goalSeconds == 3 * 3600)  // 開き直しても残る
    }

    @Test func noPlanDayGoalPacesFrom8To20() throws {
        let t = try TestStore(now: jst("2026-10-19T07:00"))
        let m = model(t)
        m.skipPlan()
        #expect(m.snapshot.goal == nil)
        #expect(m.setNoPlanGoal(6 * 3600))
        #expect(m.noPlanGoalSeconds == 6 * 3600)
        t.clock.set(jst("2026-10-19T14:00"))
        m.reload()
        #expect(m.snapshot.opponentFocusSeconds(.goal) == 3 * 3600)
        m.setNoPlanGoal(nil)
        #expect(m.snapshot.goal == nil)
    }

    @Test func idealHolidaySeededOnceEvenAfterDeleting() throws {
        let t = try TestStore()
        let settings = MemorySettings()
        let m = model(t, settings: settings)
        let holiday = try #require(m.templates.first)
        #expect(holiday.name == "理想の休日")
        m.deleteTemplate(holiday)
        #expect(m.templates.isEmpty)
        #expect(model(t, settings: settings).templates.isEmpty)
    }

    @Test func saveAsTemplateAndLimit() throws {
        let t = try TestStore(now: jst("2026-10-19T07:00"))
        let m = model(t)
        let plan = PlanDraft(blocks: [block("2026-10-19T09:00", 60, m.categories[0])])
        for i in 2...7 { #expect(m.saveAsTemplate(name: "t\(i)", plan: plan)) }
        #expect(m.templates.count == 7)
        #expect(!m.saveAsTemplate(name: "t8", plan: plan))
        #expect(m.errorMessage == AppModel.tooManyTemplatesMessage)
        #expect(m.templates.last?.blocks.first.map { ($0.hour, $0.minute) } ?? (0, 0) == (9, 0))
    }

    @Test func skipWithGoalBecomesNoPlanGoal() throws {
        let t = try TestStore(now: jst("2026-10-19T07:00"))
        let m = model(t)
        m.skipPlan(goalSeconds: 5 * 3600)
        #expect(m.plan == nil)
        #expect(m.noPlanGoalSeconds == 5 * 3600)
        m.skipPlan(goalSeconds: nil)  // もう計画なし日なので何も変わらない
        #expect(m.noPlanGoalSeconds == 5 * 3600)
    }
}

/// レビューで足したもの（PR②）
@MainActor
struct NoPlanGoalFlowTests {
    private func model(_ t: TestStore) -> AppModel {
        AppModel(store: t.store, clock: t.clock, timeZone: { tokyo }, settings: MemorySettings())
    }

    @Test func skippingDraftDropsItsGoalUnlessGiven() throws {
        let t = try TestStore(now: jst("2026-10-19T07:00"))
        let m = model(t)
        var draft = PlanDraft(blocks: [PlanBlockDraft(start: jst("2026-10-19T09:00"), minutes: 60, category: m.categories[0])])
        draft.goalSeconds = 4 * 3600
        m.saveDraft(draft)
        m.skipPlan(goalSeconds: nil)
        #expect(m.noPlanGoalSeconds == nil)  // 下書きの目標は残らない
    }

    @Test func noPlanGoalCarriesIntoLatePlan() throws {
        let t = try TestStore(now: jst("2026-10-19T07:00"))
        let m = model(t)
        m.skipPlan(goalSeconds: 5 * 3600)
        m.openPlanOnNoPlanDay()
        #expect(m.morningPlan?.draft.goalSeconds == 5 * 3600)
        m.confirmPlan(PlanDraft(blocks: [PlanBlockDraft(start: jst("2026-10-19T09:00"), minutes: 60, category: m.categories[0])],
                                goalSeconds: m.morningPlan?.draft.goalSeconds))
        #expect(m.plan?.goalSeconds == 5 * 3600)
        #expect(m.snapshot.goal?.goalSeconds == 5 * 3600)
    }
}
