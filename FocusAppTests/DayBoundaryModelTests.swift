import Foundation
import SwiftData
import Testing
@testable import FocusApp

/// 一日の区切りを夜（初期 22:00）に（GHO-17・PLN-11、ADR-0023、受け入れ 1b-70〜1b-85）。
@MainActor
struct DayBoundaryModelTests {
    private func model(_ t: TestStore, settings: MemorySettings = MemorySettings(),
                       notifications: NoNotifications = NoNotifications()) -> AppModel {
        settings.didShowBlockingIntro = true
        return AppModel(store: t.store, clock: t.clock, timeZone: { tokyo }, settings: settings, notifications: notifications)
    }

    private func block(_ start: String, _ minutes: Int, _ category: CategoryOption) -> PlanBlockDraft {
        PlanBlockDraft(start: jst(start), minutes: minutes, category: category)
    }

    /// `start`〜`end` に計画外のタイマーを動かす（止め忘れの確認を挟まずに終える）
    private func record(_ m: AppModel, _ t: TestStore, _ start: String, _ end: String, category: CategoryOption? = nil) {
        t.clock.set(jst(start))
        m.startUnplanned(category: category ?? m.categories[0], minutes: nil)
        t.clock.set(jst(end))
        m.end(reportedEnd: nil)
    }

    /// 習慣：ゲーム・SNS の時間（`hour`:`minute`）
    private func habitSettings(gameAt hour: Int, minute: Int = 0) -> MemorySettings {
        let settings = MemorySettings()
        settings.habitsJSON = TemplateBlockValue.encode([TemplateBlockValue(PlanTemplate.Block(hour: hour, minute: minute, minutes: 30,
                                                                                                category: .gameSNS))])
        return settings
    }

    // MARK: 区切りより後は次の日（1b-71）

    @Test func focusAfterTheBoundaryCountsForTheNextDay() throws {
        let t = try TestStore(now: jst("2026-10-20T09:00"))
        let m = model(t)
        m.skipPlan()
        record(m, t, "2026-10-20T21:30", "2026-10-20T22:30")
        // 22:00 から新しい日（日の名前は次の暦の日）。区切りより後の30分だけ新しい日の集中
        #expect(m.snapshot.dayKey == "2026-10-21")
        #expect(m.snapshot.dayStart == jst("2026-10-20T22:00"))
        #expect(m.snapshot.focusSeconds == 30 * 60)
        record(m, t, "2026-10-20T22:40", "2026-10-20T23:40")
        #expect(m.snapshot.focusSeconds == 90 * 60)
        // 前の日（10/20）は 21:30〜22:00 の30分のまま
        #expect(m.daySnapshot(daysAgo: 1)?.focusSeconds == 30 * 60)
        // タイムラインは始めた日
        #expect(m.timelineDay(daysAgo: 1)?.sessions.count == 1)
        #expect(m.timelineDay(daysAgo: 0)?.sessions.count == 1)
        #expect(try t.store.sessions(dayKey: "2026-10-21").count == 1)
    }

    /// タイマー中に 22:00 を過ぎると、差も新しい日の0から比べ直す（focus-timer.md）
    @Test func runningTimerRestartsTheDiffAtTheBoundary() throws {
        let t = try TestStore(now: jst("2026-10-20T09:00"))
        let m = model(t)
        m.skipPlan()
        record(m, t, "2026-10-20T10:00", "2026-10-20T11:00")
        t.clock.set(jst("2026-10-20T21:30"))
        m.startUnplanned(category: m.categories[0], minutes: nil)
        #expect(m.running?.focusSecondsBefore == 3600)
        #expect(m.running?.countsFrom == nil)
        t.clock.set(jst("2026-10-20T22:30"))
        m.reload()
        let timer = try #require(m.running)
        #expect(timer.countsFrom == jst("2026-10-20T22:00"))
        #expect(timer.focusSecondsBefore == 0)
        #expect(m.snapshot.focusSeconds == 30 * 60)
    }

    // MARK: 区切りで確定（1b-70）

    @Test func reviewIsFinalAfterTheBoundary() throws {
        let t = try TestStore(now: jst("2026-10-20T07:00"))
        let m = model(t)
        m.confirmPlan(PlanDraft())
        record(m, t, "2026-10-20T21:00", "2026-10-20T21:30")
        t.clock.set(jst("2026-10-20T21:59"))
        m.reload()
        let before = try #require(m.reviewContent())
        #expect(!before.isFinal)
        #expect(before.provisionalNote == "今のところ・確定は22:00")
        #expect(before.focusSeconds == 30 * 60)

        t.clock.set(jst("2026-10-20T22:00"))
        m.reload()
        let after = try #require(m.reviewContent())
        #expect(after.isFinal)
        #expect(after.provisionalNote == nil)
        #expect(after.dayDate == jst("2026-10-20T00:00"))
        let points = try #require(m.daySnapshot(daysAgo: 1)?.points)

        // 22:00 より後に集中しても、確定した日の値は変わらない
        record(m, t, "2026-10-20T22:10", "2026-10-20T22:40")
        let later = try #require(m.reviewContent())
        #expect(later.isFinal)
        #expect(later.focusSeconds == 30 * 60)
        #expect(m.daySnapshot(daysAgo: 1)?.points == points)
    }

    // MARK: 睡眠は起きた日（1b-72・1b-83）

    @Test func sleepCountsOnTheWakeDay() throws {
        let t = try TestStore(now: jst("2026-10-20T09:00"))
        let m = try raceModelWithBlocking(t)
        m.skipPlan()
        m.reload()
        // 前の夜 22:00〜0:00 ブロック中（6pt）、0:00〜7:00 寝ている（31.5pt）、7:00〜9:00 ブロック中（6pt）
        #expect(m.snapshot.points.isApprox(43.5))
        let asleep = (m.snapshot.detox?.pieces ?? []).filter { $0.kind == .asleep }
        #expect(asleep.first?.start == jst("2026-10-20T00:00"))
        #expect(asleep.last?.end == jst("2026-10-20T07:00"))
    }

    /// 区切りより前に寝始めた睡眠（21:00〜6:00）は、21:00〜22:00 を寝た日に（ブロック中として）残し、起きた日には 22:00〜6:00 だけ。
    /// 段は 21:00 から数える（22:00〜4:00 が0.75pt・4:00〜5:00 が0.5pt・5:00〜6:00 が0）
    @Test func sleepBeforeTheBoundaryIsSplitWithoutDoubleCounting() throws {
        let t = try TestStore(now: jst("2026-10-20T09:00"))
        let m = try raceModelWithBlocking(t)
        m.skipPlan()
        try t.store.saveSleep(SleepLine(start: jst("2026-10-20T21:00"), end: jst("2026-10-21T06:00"), source: .manual),
                              dayKey: "2026-10-21", timeZone: tokyo)
        t.clock.set(jst("2026-10-21T09:00"))
        m.reload()
        m.skipPlan()
        // 起きた日：22:00〜4:00 27pt＋4:00〜5:00 3pt＋5:00〜6:00 0pt、6:00〜9:00 ブロック中 9pt
        #expect(m.snapshot.points.isApprox(39))
        // 寝た日の 21:00〜22:00 は寝ているとして数えない
        let yesterday = try #require(m.daySnapshot(daysAgo: 1))
        let lastHour = (yesterday.detox?.pieces ?? []).filter { $0.end > jst("2026-10-20T21:00") }
        #expect(!lastHour.isEmpty)
        #expect(lastHour.allSatisfy { $0.kind != .asleep })
    }

    @Test func sleepIsSavedFromFourAm() throws {
        let t = try TestStore(now: jst("2026-10-20T09:00"))
        let m = model(t)
        m.skipPlan()
        // 寝る前（23:00）に開いても、まだ寝ていない睡眠を保存しない
        t.clock.set(jst("2026-10-20T23:00"))
        m.reload()
        #expect(try t.store.sleep(dayKey: "2026-10-21") == nil)
        t.clock.set(jst("2026-10-21T03:59"))
        m.reload()
        #expect(try t.store.sleep(dayKey: "2026-10-21") == nil)
        t.clock.set(jst("2026-10-21T04:00"))
        m.reload()
        #expect(try t.store.sleep(dayKey: "2026-10-21")?.source == .setting)
    }

    /// ヘルスケアの置き換えはその日の区切りまで
    @Test func healthReplacesOnlyUntilTheBoundary() async throws {
        let t = try TestStore(now: jst("2026-10-20T21:59"))
        try t.seeded()
        let source = NoSleepSource(isAvailable: true, intervals: [DateInterval(start: jst("2026-10-20T00:10"), end: jst("2026-10-20T07:05"))])
        let settings = MemorySettings()
        settings.didShowBlockingIntro = true
        let m = AppModel(store: t.store, clock: t.clock, timeZone: { tokyo }, settings: settings, sleepSource: source)
        m.skipPlan()
        t.clock.set(jst("2026-10-20T22:00"))
        m.reload()
        await m.refreshSleep()
        #expect(try t.store.sleep(dayKey: "2026-10-20")?.source == .setting)
    }

    // MARK: 朝の計画は朝4:00から（1b-73）

    @Test func morningPlanFromFourAmWithTheGridFromWaking() throws {
        let t = try TestStore(now: jst("2026-10-20T09:00"))
        let m = model(t)
        #expect(m.morningPlan?.dayKey == "2026-10-20")
        m.skipPlan()
        t.clock.set(jst("2026-10-20T22:00"))
        m.reload()
        #expect(m.morningPlan == nil)
        t.clock.set(jst("2026-10-21T03:59"))
        m.reload()
        #expect(m.morningPlan == nil)
        try t.store.saveSleep(SleepLine(start: jst("2026-10-21T00:20"), end: jst("2026-10-21T06:47"), source: .health),
                              dayKey: "2026-10-21", timeZone: tokyo)
        t.clock.set(jst("2026-10-21T04:00"))
        m.reload()
        let morning = try #require(m.morningPlan)
        #expect(morning.dayKey == "2026-10-21")
        #expect(morning.dayStart == jst("2026-10-20T22:00"))
        // 格子は起きた時刻（:00・:30 に切り下げ）から区切りまで
        #expect(morning.gridStart == jst("2026-10-21T06:30"))
        #expect(morning.dayEnd == jst("2026-10-21T22:00"))
    }

    // MARK: 前の夜の予定（1b-74、PLN-11）

    @Test func previousNightPlanWorksLikeAPlan() async throws {
        let t = try TestStore(now: jst("2026-10-20T09:00"))
        let notifications = NoNotifications(status: .authorized)
        let m = model(t, settings: habitSettings(gameAt: 23, minute: 30), notifications: notifications)
        await m.refreshNotificationStatus()
        m.skipPlan()
        let study = m.categories[0], reading = m.categories[2]

        t.clock.set(jst("2026-10-20T21:00"))
        m.reload()
        let tomorrow = m.tomorrowPlan()
        #expect(tomorrow.dayKey == "2026-10-21")
        // 習慣のゲーム・SNS の時間は前の夜 23:30 に入っている
        #expect(tomorrow.draft.blocks.map(\.start) == [jst("2026-10-20T23:30")])
        var draft = tomorrow.draft
        draft.blocks += [block("2026-10-20T22:00", 30, study), block("2026-10-20T22:30", 60, reading),
                         block("2026-10-21T09:00", 60, study)]
        #expect(m.saveTomorrowDraft(draft, for: tomorrow, reloads: true))

        // 明日の計画を保存しただけで、前の夜の予定の通知（区切りちょうどの 21:55 も）とブロックを外す予定が入る
        let notices = notifications.scheduled.filter { $0.id.hasPrefix(AppNotification.blockNoticePrefix) }.map(\.trigger)
        #expect(notices.contains(.at(jst("2026-10-20T21:55"))))
        #expect(notices.contains(.at(jst("2026-10-20T22:25"))))
        // 朝からの分（9:00）は朝に確定してから
        #expect(!notices.contains(.at(jst("2026-10-21T08:55"))))
        #expect(m.blockState.unblockWindows.contains { $0.start == jst("2026-10-20T23:30") })

        // 22:00 からは下書きを今日の計画として使う（今・次、1タップ開始）
        t.clock.set(jst("2026-10-20T22:00"))
        m.reload()
        #expect(m.snapshot.dayKey == "2026-10-21")
        let now = try #require(m.snapshot.currentBlock)
        #expect(now.start == jst("2026-10-20T22:00"))
        m.startPlanned(block: now)
        t.clock.set(jst("2026-10-20T22:24"))
        m.end(reportedEnd: nil)
        // 計画どおりの点（21:00 に保存＝1時間以上前から計画にあった）
        #expect(m.snapshot.planAwards.count == 1)

        // 朝の計画にはその下書きが出て、確定したときの写しにも前の夜の分が入る。前の夜の点は増えない
        t.clock.set(jst("2026-10-21T07:00"))
        m.reload()
        let morning = try #require(m.morningPlan)
        #expect(morning.draft.blocks.count == 4)
        m.confirmPlan(morning.draft)
        #expect(try t.store.snapshot(dayKey: "2026-10-21")?.count == 4)
        #expect(m.snapshot.planAwards.count == 1)
    }

    /// 朝に「今日は計画しない」を押しても、前の夜の分は残し、外すのは朝から先の分だけ
    @Test func skippingKeepsThePreviousNight() throws {
        let t = try TestStore(now: jst("2026-10-20T09:00"))
        let m = model(t)
        m.skipPlan()
        t.clock.set(jst("2026-10-20T21:00"))
        m.reload()
        let tomorrow = m.tomorrowPlan()
        let study = m.categories[0]
        m.saveTomorrowDraft(PlanDraft(blocks: [block("2026-10-20T22:30", 60, study), block("2026-10-21T09:00", 60, study)]),
                            for: tomorrow, reloads: true)
        record(m, t, "2026-10-20T22:30", "2026-10-20T23:30")
        t.clock.set(jst("2026-10-21T07:00"))
        m.reload()
        m.skipPlan()
        let stored = try #require(try t.store.plan(dayKey: "2026-10-21"))
        #expect(stored.status == .skipped)
        #expect(stored.draft.blocks.map(\.start) == [jst("2026-10-20T22:30")])
        #expect(try t.store.sessions(dayKey: "2026-10-21").count == 1)
        #expect(m.timelineDay(daysAgo: 0)?.planBlocks.count == 1)
    }

    /// 区切りの後（朝の計画の前）に計画のタブでブロックを足すと、今日の下書きとして保存する（PLN-11）
    @Test func planTabAtNightSavesADraft() throws {
        let t = try TestStore(now: jst("2026-10-20T09:00"))
        let m = model(t)
        m.skipPlan()
        t.clock.set(jst("2026-10-20T22:10"))
        m.reload()
        #expect(m.plan == PlanDraft())
        #expect(m.savePlanChanges(PlanDraft(blocks: [block("2026-10-20T22:30", 30, m.categories[0])])))
        #expect(m.errorMessage == nil)
        #expect(try t.store.plan(dayKey: "2026-10-21")?.status == .draft)
        #expect(m.snapshot.nextBlock?.start == jst("2026-10-20T22:30"))
    }

    /// 下書きがない日は、区切りより後に最初に読み直したときに習慣で作る。区切りより前から次の日の前の夜の分を登録しておく
    @Test func habitDraftIsMadeAfterTheBoundary() throws {
        let t = try TestStore(now: jst("2026-10-20T09:00"))
        let m = model(t, settings: habitSettings(gameAt: 23))
        m.skipPlan()
        t.clock.set(jst("2026-10-20T21:00"))
        m.reload()
        #expect(try t.store.plan(dayKey: "2026-10-21") == nil)
        #expect(m.confirmedUnblocks.map(\.start) == [jst("2026-10-20T23:00")])
        t.clock.set(jst("2026-10-20T22:00"))
        m.reload()
        let stored = try #require(try t.store.plan(dayKey: "2026-10-21"))
        #expect(stored.status == .draft)
        #expect(stored.draft.blocks.map(\.start) == [jst("2026-10-20T23:00")])
        // 今日（前の夜）の分と、次の日の前の夜の分
        #expect(m.confirmedUnblocks.map(\.start) == [jst("2026-10-20T23:00"), jst("2026-10-21T23:00")])
    }

    /// 区切りを過ぎてから前の日の朝の計画を保存しても、前の日の点は変わらない
    @Test func confirmingAfterTheBoundaryKeepsThatDaysPoints() throws {
        let t = try TestStore(now: jst("2026-10-20T09:00"))
        let m = model(t)
        let study = m.categories[0]
        let opened = try #require(m.morningPlan)
        m.saveDraft(PlanDraft(blocks: [block("2026-10-20T10:00", 60, study)]))
        record(m, t, "2026-10-20T10:00", "2026-10-20T11:00", category: study)
        t.clock.set(jst("2026-10-20T22:05"))
        m.reload()
        let before = try #require(m.daySnapshot(of: opened.dayStart)?.points)
        m.confirmPlan(PlanDraft(blocks: [block("2026-10-20T10:00", 60, study)]))
        #expect(m.daySnapshot(of: opened.dayStart)?.points == before)
    }

    // MARK: 区切りの設定（1b-75・1b-82）

    @Test func changingTheBoundaryTakesEffectTheNextDay() throws {
        let t = try TestStore(now: jst("2026-10-20T15:00"))
        let m = model(t)
        #expect(m.boundaryEndMinutes == 22 * 60)
        #expect(m.pendingBoundaryChange == nil)
        m.setBoundary(endMinutes: 23 * 60)
        let pending = try #require(m.pendingBoundaryChange)
        #expect(BoundaryText.pending(pending) == "明日から 23:00 で区切ります（今日は 22:00 で確定します）")
        #expect(BoundaryText.tomorrowLength(pending) == "明日は25時間です")
        #expect(m.boundaryEndMinutes == 23 * 60)
        // 今日は 22:00 で確定、次の日は 22:00〜翌日23:00 の25時間
        #expect(m.snapshot.dayEnd == jst("2026-10-20T22:00"))
        let next = m.boundary.day(key: "2026-10-21")
        #expect(next?.start == jst("2026-10-20T22:00"))
        #expect(next?.end == jst("2026-10-21T23:00"))
        // 早くしたら次の日は22時間。同じ日に何度変えても最後のもの
        m.setBoundary(endMinutes: 20 * 60)
        #expect(m.pendingBoundaryChange.flatMap(BoundaryText.tomorrowLength) == "明日は22時間です")
        // 今日と同じ時刻に戻したら何も変わらない
        m.setBoundary(endMinutes: 22 * 60)
        #expect(m.pendingBoundaryChange == nil)
        #expect(m.boundary.day(key: "2026-10-21")?.duration == TimeInterval(24 * 3600))
    }

    /// 22:00 に変えた（もう次の日に入った）ときは、その次の日から効く
    @Test func changingAfterTheBoundaryWaitsOneMoreDay() throws {
        let t = try TestStore(now: jst("2026-10-20T21:59"))
        let m = model(t)
        m.setBoundary(endMinutes: 23 * 60)
        #expect(m.boundary.day(key: "2026-10-20")?.end == jst("2026-10-20T22:00"))
        #expect(m.boundary.day(key: "2026-10-21")?.end == jst("2026-10-21T23:00"))

        let u = try TestStore(now: jst("2026-10-20T22:00"))
        let n = model(u)
        n.setBoundary(endMinutes: 23 * 60)
        #expect(n.boundary.day(key: "2026-10-21")?.end == jst("2026-10-21T22:00"))
        #expect(n.boundary.day(key: "2026-10-22")?.end == jst("2026-10-22T23:00"))
    }

    /// 使い始めた行は書き換えない（過去の日の点を変えないため）
    @Test func startedRowsAreNeverRewritten() throws {
        let t = try TestStore(now: jst("2026-10-20T15:00"))
        let m = model(t)
        m.setBoundary(endMinutes: 23 * 60)
        t.clock.set(jst("2026-10-21T10:00"))
        m.reload()
        m.setBoundary(endMinutes: 21 * 60)
        let rows = try t.store.boundaryChanges()
        #expect(rows.first { $0.fromDayKey == "2026-10-21" }?.endMinutes == 23 * 60)
        #expect(rows.first { $0.fromDayKey == "2026-10-22" }?.endMinutes == 21 * 60)
        #expect(m.boundary.day(key: "2026-10-21")?.end == jst("2026-10-21T23:00"))
    }

    // MARK: 移すとき（1b-77・1b-79・1b-84）

    private func insertSession(_ t: TestStore, _ start: String, _ end: String, category: CategoryOption) {
        let record = FocusSessionRecord(dayKey: DayBoundary.dayKey(containing: jst(start), calendar: tokyoCalendar), timeZoneId: "Asia/Tokyo",
                                        planBlockId: nil, categoryId: category.id, countsAsFocus: category.countsAsFocus, projectId: nil,
                                        startAt: jst(start), plannedEndAt: nil, plannedDurationSec: nil, at: jst(start))
        record.endAt = jst(end)
        t.context.insert(record)
        try? t.context.save()
    }

    @Test func migrationAddsOneRowFromTheNextDay() throws {
        let t = try TestStore(now: jst("2026-10-22T15:00"))
        let categories = try t.seeded()
        insertSession(t, "2026-10-21T10:00", "2026-10-21T11:00", category: categories[0])
        let m = model(t)
        #expect(try t.store.boundaryChanges().map(\.fromDayKey) == ["2026-10-23"])
        #expect(try t.store.boundaryChanges().map(\.endMinutes) == [22 * 60])
        // 移した日は 4:00 区切りのまま、次の日が 4:00〜22:00 の18時間、その次から 22:00 区切り
        #expect(m.snapshot.dayStart == jst("2026-10-22T04:00"))
        #expect(m.snapshot.dayEnd == jst("2026-10-23T04:00"))
        #expect(m.snapshot.isLegacyDay)
        #expect(m.boundary.day(key: "2026-10-23")?.duration == TimeInterval(18 * 3600))
        // 2回目の起動では足さない
        _ = model(t)
        #expect(try t.store.boundaryChanges().count == 1)
    }

    @Test func freshInstallStartsAtTwentyTwo() throws {
        let t = try TestStore(now: jst("2026-10-22T15:00"))
        let m = model(t)
        #expect(m.snapshot.dayKey == "2026-10-22")
        #expect(m.snapshot.dayStart == jst("2026-10-21T22:00"))
        #expect(!m.snapshot.isLegacyDay)
        let late = try TestStore(now: jst("2026-10-22T23:00"))
        #expect(model(late).snapshot.dayKey == "2026-10-23")
    }

    /// 移した日の振り返りの通知は前の予約を取り消して 22:00 に今までの文面で1回、次の日から区切りの時刻に新しい文面
    @Test func migrationDayReviewNoticeIsRescheduled() async throws {
        let t = try TestStore(now: jst("2026-10-22T15:00"))
        let categories = try t.seeded()
        insertSession(t, "2026-10-21T10:00", "2026-10-21T11:00", category: categories[0])
        let notifications = NoNotifications(status: .authorized)
        notifications.replaceAll(with: [AppNotification(id: AppNotification.reviewID, title: "今日を振り返りましょう", body: "",
                                                        trigger: .daily(minutes: 21 * 60))])
        let m = model(t, notifications: notifications)
        await m.refreshNotificationStatus()
        let reviews = notifications.scheduled.filter { $0.id.hasPrefix(AppNotification.reviewID) }
        #expect(!reviews.contains { $0.trigger == .daily(minutes: 21 * 60) })
        #expect(reviews.first?.trigger == .at(jst("2026-10-22T22:00")))
        #expect(reviews.first?.title == "今日を振り返りましょう")
        #expect(reviews.dropFirst().first?.trigger == .at(jst("2026-10-23T22:00")))
        #expect(reviews.dropFirst().first?.title == "今日の結果が確定しました")
        // 移した日の振り返りは「今のところ・確定は朝4:00」、ホームの入口は 22:00 から
        #expect(m.reviewContent()?.provisionalNote == "今のところ・確定は朝4:00")
        #expect(!m.snapshot.showsReviewEntry)
        t.clock.set(jst("2026-10-22T22:00"))
        m.reload()
        #expect(m.snapshot.showsReviewEntry)
    }

    /// 移した日をまたぐ一晩の睡眠は二重に数えない（移した日に 0:00〜4:00、18時間の日に 4:00 より後）
    @Test func sleepAcrossMigrationNightCountsOnce() throws {
        let t = try TestStore(now: jst("2026-10-22T15:00"))
        let categories = try t.seeded()
        insertSession(t, "2026-10-21T10:00", "2026-10-21T11:00", category: categories[0])
        let m = try raceModelWithBlocking(t)
        m.skipPlan()
        t.clock.set(jst("2026-10-23T09:00"))
        m.reload()
        m.skipPlan()
        let migrated = try #require(m.daySnapshot(daysAgo: 1))
        #expect(migrated.isLegacyDay)
        let night = (migrated.detox?.pieces ?? []).filter { $0.kind == .asleep && $0.start >= jst("2026-10-23T00:00") }
        #expect(night.map(\.start).min() == jst("2026-10-23T00:00"))
        #expect(night.map(\.end).max() == jst("2026-10-23T04:00"))
        let short = (m.snapshot.detox?.pieces ?? []).filter { $0.kind == .asleep }
        #expect(short.map(\.start).min() == jst("2026-10-23T04:00"))
        #expect(short.map(\.end).max() == jst("2026-10-23T07:00"))
    }

    /// 移した日の 3:30〜4:30 のタイマーは、4:00 より後の30分が次の18時間の日の集中。18時間の日の 21:30〜22:30 は 22:00 より後の30分が次の日
    @Test func timersAcrossTheHistoryEdge() throws {
        let t = try TestStore(now: jst("2026-10-22T15:00"))
        let categories = try t.seeded()
        insertSession(t, "2026-10-21T10:00", "2026-10-21T11:00", category: categories[0])
        let m = model(t)
        m.skipPlan()
        record(m, t, "2026-10-23T03:30", "2026-10-23T04:30")
        #expect(m.snapshot.dayKey == "2026-10-23")
        #expect(m.snapshot.focusSeconds == 30 * 60)
        m.skipPlan()
        record(m, t, "2026-10-23T21:30", "2026-10-23T22:30")
        #expect(m.snapshot.dayKey == "2026-10-24")
        #expect(m.snapshot.focusSeconds == 30 * 60)
        #expect(m.daySnapshot(daysAgo: 1)?.focusSeconds == 60 * 60)
    }

    /// 変える前の日（4:00 区切り）の点数・自己ベストは、移す前後で同じ
    @Test func pastDaysAreUnchangedByTheMigration() throws {
        func make() throws -> (TestStore, [CategoryOption]) {
            let t = try TestStore(now: jst("2026-10-22T15:00"))
            let categories = try t.seeded()
            for (start, end) in [("2026-10-15T03:30", "2026-10-15T04:30"), ("2026-10-16T21:00", "2026-10-16T23:30"),
                                 ("2026-10-18T09:00", "2026-10-18T12:00"), ("2026-10-20T23:00", "2026-10-21T01:00"),
                                 ("2026-10-21T10:00", "2026-10-21T11:00")] {
                insertSession(t, start, end, category: categories[0])
            }
            return (t, categories)
        }
        let (before, _) = try make()
        // 移す前：すべての日が朝4:00区切り（区切りの履歴は遠い先から）
        try before.store.setBoundary(endMinutes: 22 * 60, fromDayKey: "2099-01-01", timeZone: tokyo)
        let old = try raceModelWithBlocking(before)
        let (after, _) = try make()
        let new = try raceModelWithBlocking(after)
        #expect(try after.store.boundaryChanges().map(\.fromDayKey) == ["2026-10-23"])
        let oldDays = old.pointsHistory(days: 8).filter { !$0.isToday }
        let newDays = new.pointsHistory(days: 8).filter { !$0.isToday }
        #expect(oldDays.map(\.dayStart) == newDays.map(\.dayStart))
        #expect(oldDays.map(\.points) == newDays.map(\.points))
        #expect(old.periodBests()[.all] == new.periodBests()[.all])
        #expect(old.timelineDay(daysAgo: 6)?.sessions.map(\.id).count == new.timelineDay(daysAgo: 6)?.sessions.map(\.id).count)
    }

    // MARK: 区切りを変えた週の比べ方（1b-78）

    @Test func switchWeekComparesAtTheSameTime() throws {
        let t = try TestStore(now: jst("2026-10-22T14:30"))
        let categories = try t.seeded()
        // 先週の同じ曜日（10/15、朝4:00区切り）：14:00〜14:30 と 23:00〜23:30
        insertSession(t, "2026-10-15T14:00", "2026-10-15T14:30", category: categories[0])
        insertSession(t, "2026-10-15T23:00", "2026-10-15T23:30", category: categories[0])
        try t.store.setBoundary(endMinutes: 22 * 60, fromDayKey: "2026-10-21", timeZone: tokyo)
        let m = model(t)
        #expect(m.snapshot.dayStart == jst("2026-10-21T22:00"))
        let ghost = try #require(m.snapshot.ghost)
        // 今日の前の夜 22:00〜4:00 は先週を0（先週の日は 4:00 に始まった）
        #expect(ghost.focusSeconds(at: jst("2026-10-21T23:45")) == 0)
        // 14:30 は先週の 14:30 まで
        #expect(ghost.focusSeconds(at: jst("2026-10-22T14:30")) == 30 * 60)
        // 22:00 の確定は先週の 4:00〜22:00 の分（先週の 23:00 の分は比べない）
        #expect(ghost.focusSeconds(at: jst("2026-10-22T22:00")) == 30 * 60)
    }

    // MARK: 24時間でない日（1b-81）

    @Test func lapsEndAtTheBoundaryOnLongAndShortDays() {
        func sections(_ from: [(String, Int)], _ key: String) -> [DateInterval] {
            let day = boundary(from).day(key: key)!
            return Laps.sections(dayStart: day.start, dayEnd: day.end)
        }
        let long = sections([("2026-10-01", 1320), ("2026-10-22", 1380)], "2026-10-22")
        #expect(long.count == 13)
        #expect(long.last?.duration == 3600)
        #expect(long.first?.start == jst("2026-10-21T22:00"))
        #expect(sections([("2026-10-01", 1320), ("2026-10-22", 1200)], "2026-10-22").count == 11)
        #expect(sections([("2026-10-01", 1200), ("2026-10-22", 1680)], "2026-10-22").count == 16)
        #expect(sections([("2026-10-01", 1680), ("2026-10-22", 1200)], "2026-10-22").count == 8)
        #expect(sections([("2026-10-01", 1320)], "2026-10-22").count == 12)
        // 25時間の日の最後の区間の境目まで通過する
        let day = boundary([("2026-10-01", 1320), ("2026-10-22", 1380)]).day(key: "2026-10-22")!
        #expect(Laps.passedBoundary(dayStart: day.start, dayEnd: day.end, head: jst("2026-10-22T23:00")) == jst("2026-10-22T23:00"))
        #expect(Laps.passedBoundary(dayStart: day.start, dayEnd: day.end, head: jst("2026-10-22T22:59")) == jst("2026-10-22T22:00"))
    }

    @Test func ghostCurveCoversTheWholeDay() throws {
        let t = try TestStore(now: jst("2026-10-22T09:00"))
        let categories = try t.seeded()
        try t.store.setBoundary(endMinutes: 22 * 60, fromDayKey: "2026-10-01", timeZone: tokyo)
        try t.store.setBoundary(endMinutes: 23 * 60, fromDayKey: "2026-10-22", timeZone: tokyo)
        let lastWeek = FocusSessionRecord(dayKey: "2026-10-15", timeZoneId: "Asia/Tokyo", planBlockId: nil, categoryId: categories[0].id,
                                          countsAsFocus: true, projectId: nil, startAt: jst("2026-10-15T10:00"), plannedEndAt: nil,
                                          plannedDurationSec: nil, at: jst("2026-10-15T10:00"))
        lastWeek.endAt = jst("2026-10-15T11:00")
        t.context.insert(lastWeek)
        try t.context.save()
        let widgets = MemoryWidgetPublisher()
        let blockStore = MemoryBlockStore()
        let settings = MemorySettings()
        settings.didShowBlockingIntro = true
        let m = AppModel(store: t.store, clock: t.clock, timeZone: { tokyo }, settings: settings, blockStore: blockStore, widgets: widgets)
        #expect(m.snapshot.dayEnd.timeIntervalSince(m.snapshot.dayStart) == 25 * 3600)
        // ウィジェットは10分ごと（25時間なら151点）、シールドは15分ごと（101点）
        #expect(widgets.published.last?.ghostCurve.count == 151)
        #expect(blockStore.raceSnapshot?.opponentCurve.count == 101)
        #expect(blockStore.raceSnapshot?.dayEnd == jst("2026-10-22T23:00"))
        #expect(widgets.published.last?.ghostCurve.last == 3600)
    }

    // MARK: 習慣の時刻の当てはめ（1b-80）

    @Test func habitTimesMapAroundTheBoundary() {
        let habits = PlanHabits(blocks: [PlanTemplate.Block(hour: 23, minute: 0, minutes: 30, category: .gameSNS),
                                         PlanTemplate.Block(hour: 7, minute: 0, minutes: 30, category: DefaultCategories.all[0]),
                                         PlanTemplate.Block(hour: 0, minute: 30, minutes: 30, category: DefaultCategories.all[1])])
        // 区切り 22:00：区切り以降の 23:00・0:30 は前の夜
        let evening = boundary([("2026-10-01", 1320)]).day(key: "2026-10-21")!
        #expect(habits.draft(day: evening, calendar: tokyoCalendar).sortedBlocks.map(\.start)
                == [jst("2026-10-20T23:00"), jst("2026-10-21T00:30"), jst("2026-10-21T07:00")])
        // 区切り 1:00（夜中）：区切りより前の 0:30 は翌日の夜中、23:00 はその日の夜
        let midnight = boundary([("2026-10-01", 1500)]).day(key: "2026-10-21")!
        #expect(habits.draft(day: midnight, calendar: tokyoCalendar).sortedBlocks.map(\.start)
                == [jst("2026-10-21T07:00"), jst("2026-10-21T23:00"), jst("2026-10-22T00:30")])
        // 区切り 20:00：23:00 も 0:30 も前の夜
        let early = boundary([("2026-10-01", 1200)]).day(key: "2026-10-21")!
        #expect(habits.draft(day: early, calendar: tokyoCalendar).sortedBlocks.map(\.start)
                == [jst("2026-10-20T23:00"), jst("2026-10-21T00:30"), jst("2026-10-21T07:00")])
        // 区切りをまたぐようになったブロックは入れない（21:45〜22:15）
        let crossing = PlanHabits(blocks: [PlanTemplate.Block(hour: 21, minute: 45, minutes: 30, category: DefaultCategories.all[0])])
        #expect(crossing.draft(day: evening, calendar: tokyoCalendar).blocks.isEmpty)
    }

    // MARK: 止め忘れの確認は朝4:00（1b-85）

    @Test func needsEndTimeCheckAcrossBoundaryNotFourAm() {
        // 21:30 に始めて 22:10 に終える（25分の計画外）：区切りをまたいだだけでは聞かない
        let evening = session("2026-10-20T21:30", nil, plannedMinutes: 60)
        #expect(!evening.needsEndTimeCheck(at: jst("2026-10-20T22:10"), calendar: tokyoCalendar))
        // ストップウォッチで 21:00 に始めて翌 4:00：3時間を超え、朝4:00 もまたいだ
        let night = session("2026-10-20T21:00", nil)
        #expect(night.needsEndTimeCheck(at: jst("2026-10-21T04:00"), calendar: tokyoCalendar))
        // 計画外25分を 2:00 に始めて 4:10 に終える（30分以上の超過・朝4:00 またぎ）
        let late = session("2026-10-21T02:00", nil, plannedMinutes: 25)
        #expect(late.needsEndTimeCheck(at: jst("2026-10-21T04:10"), calendar: tokyoCalendar))
        // 3:30 に始めた60分は 3:59:59 まで聞かず、4:00 から聞く
        let dawn = session("2026-10-21T03:30", nil, plannedMinutes: 60)
        #expect(!dawn.needsEndTimeCheck(at: jst("2026-10-21T03:59:59"), calendar: tokyoCalendar))
        #expect(dawn.needsEndTimeCheck(at: jst("2026-10-21T04:00"), calendar: tokyoCalendar))
    }
}
