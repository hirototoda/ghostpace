import Foundation
import Testing
@testable import FocusApp

/// 計画ブロックの前の通知（TMR-12）。計算の部分。
struct BlockNoticeTests {
    private func summary(_ start: String, _ minutes: Int, _ category: CategoryOption = DefaultCategories.all[0],
                         title: String = "英語") -> PlanBlockSummary {
        PlanBlockSummary(id: UUID(), category: category, project: nil, title: title, categoryName: category.name,
                         start: jst(start), end: jst(start).addingTimeInterval(Double(minutes * 60)),
                         countsAsFocus: category.countsAsFocus)
    }

    private func make(_ blocks: [PlanBlockSummary], now: String, lead: Int? = 5, running: FocusSession? = nil,
                      started: Set<UUID> = [], plannedEndEnabled: Bool = true) -> [AppNotification] {
        NotificationPlan.make(running: running, now: jst(now), plannedEndEnabled: plannedEndEnabled, reviewMinutes: 22 * 60,
                              calendar: tokyoCalendar, planBlocks: running == nil ? [] : blocks,
                              blockNotice: BlockNotice(leadMinutes: lead, blocks: blocks, startedBlockIds: started))
    }

    private func notices(_ notifications: [AppNotification]) -> [AppNotification] {
        notifications.filter { $0.id.hasPrefix(AppNotification.blockNoticePrefix) }
    }

    // MARK: 時刻と文言

    @Test func fiveMinutesBeforeEachUpcomingBlock() {
        let english = summary("2026-10-19T09:00", 90)
        let seminar = summary("2026-10-19T11:00", 120, title: "ゼミ準備")
        let game = summary("2026-10-19T20:00", 30, .gameSNS, title: "ゲーム・SNS")
        let n = notices(make([english, seminar, game], now: "2026-10-19T08:00"))
        #expect(n.map(\.trigger) == [.at(jst("2026-10-19T08:55")), .at(jst("2026-10-19T10:55"))])
        #expect(n.map(\.id) == [AppNotification.blockNoticeID(english.id), AppNotification.blockNoticeID(seminar.id)])
        #expect(n[0].title == "まもなく英語")
        #expect(n[0].body == "09:00 から。開いて［今から始める］で記録できます。")
        #expect(n[1].title == "まもなくゼミ準備")
    }

    @Test func leadMinutesChoices() {
        let block = summary("2026-10-19T11:00", 60)
        #expect(notices(make([block], now: "2026-10-19T08:00", lead: 10)).first?.trigger == .at(jst("2026-10-19T10:50")))
        #expect(notices(make([block], now: "2026-10-19T08:00", lead: 15)).first?.trigger == .at(jst("2026-10-19T10:45")))
        let exact = notices(make([block], now: "2026-10-19T08:00", lead: 0)).first
        #expect(exact?.trigger == .at(jst("2026-10-19T11:00")))
        #expect(exact?.title == "英語の時間です")
        #expect(exact?.body == "11:00 になりました。開いて始めましょう。")
        #expect(notices(make([block], now: "2026-10-19T08:00", lead: nil)).isEmpty)
    }

    // MARK: 出さないとき

    /// 通知の時刻が今か、それより前（ブロック開始後も）
    @Test func noNoticeAtOrAfterItsTime() {
        let block = summary("2026-10-19T11:00", 60)
        #expect(notices(make([block], now: "2026-10-19T10:54:59")).count == 1)
        #expect(notices(make([block], now: "2026-10-19T10:55")).isEmpty)
        #expect(notices(make([block], now: "2026-10-19T10:57")).isEmpty)
        #expect(notices(make([block], now: "2026-10-19T11:10")).isEmpty)
        #expect(notices(make([block], now: "2026-10-19T11:00", lead: 0)).isEmpty)
    }

    @Test func noNoticeForStartedBlocks() {
        let block = summary("2026-10-19T11:00", 60)
        #expect(notices(make([block], now: "2026-10-19T10:00", started: [block.id])).isEmpty)
    }

    /// 4:00ちょうどのブロックの5分前は前の日のうち。夜中のブロックは今日の計画として出す
    @Test func dayBoundary() {
        let atFour = summary("2026-10-19T04:00", 60)
        #expect(notices(make([atFour], now: "2026-10-19T04:00")).isEmpty)
        let lateNight = summary("2026-10-20T03:30", 20)
        #expect(notices(make([lateNight], now: "2026-10-19T23:00")).first?.trigger == .at(jst("2026-10-20T03:25")))
    }

    // MARK: タイマー中の出し分け

    @Test func noticeWhileTimersRunAndPaused() {
        let first = summary("2026-10-19T09:00", 60)
        let next = summary("2026-10-19T10:00", 60, title: "ゼミ準備")
        // 計画ブロックのタイマー中も次のブロックに出す（本文は［今から始める］を約束しない）
        var planned = session("2026-10-19T09:00", nil, plannedEnd: "2026-10-19T10:00")
        planned.planBlockId = first.id
        let n = notices(make([first, next], now: "2026-10-19T09:30", running: planned, started: [first.id]))
        #expect(n.map(\.trigger) == [.at(jst("2026-10-19T09:55"))])
        #expect(n.first?.body == "10:00 から。開いて始めましょう。")
        // 計画外・一時停止中でも同じ
        let paused = session("2026-10-19T09:00", nil, pauses: [("2026-10-19T09:20", nil)], plannedMinutes: 60)
        #expect(notices(make([next], now: "2026-10-19T09:30", running: paused)).map(\.trigger) == [.at(jst("2026-10-19T09:55"))])
    }

    /// 前のブロックにくっついているときは［今から始める］が出ないので、本文を変える
    @Test func bodyWithoutEarlyStartWhenAnotherBlockIsOn() {
        let first = summary("2026-10-19T10:00", 60)
        let next = summary("2026-10-19T11:00", 60, title: "ゼミ準備")
        let n = notices(make([first, next], now: "2026-10-19T08:00"))
        #expect(n.map(\.body) == ["10:00 から。開いて［今から始める］で記録できます。", "11:00 から。開いて始めましょう。"])
        // ゲーム・SNS の時間の最中も［今から始める］は出ない
        let game = summary("2026-10-19T13:30", 30, .gameSNS, title: "ゲーム・SNS")
        let afterGame = summary("2026-10-19T14:00", 60)
        #expect(notices(make([game, afterGame], now: "2026-10-19T08:00")).first?.body == "14:00 から。開いて始めましょう。")
        // 15分前に、間に短いブロックがある
        let short = summary("2026-10-19T16:50", 5, title: "片付け")
        let later = summary("2026-10-19T17:00", 60, title: "卒論")
        let bodies = notices(make([short, later], now: "2026-10-19T08:00", lead: 15)).map(\.body)
        #expect(bodies == ["16:50 から。開いて［今から始める］で記録できます。", "17:00 から。開いて始めましょう。"])
    }

    /// 「ちょうど」で同じ時刻に TMR-11 の通知が出るときはそちらだけ。5分前なら両方
    @Test func exactDefersToBlockStartWhileOffPlan() {
        let block = summary("2026-10-19T11:00", 60)
        let later = summary("2026-10-19T14:00", 60, title: "卒論")
        let offPlan = session("2026-10-19T10:30", nil)
        let exact = make([block, later], now: "2026-10-19T10:35", lead: 0, running: offPlan)
        #expect(exact.contains { $0.id == AppNotification.blockStartID })
        #expect(notices(exact).map(\.trigger) == [.at(jst("2026-10-19T14:00"))])
        let five = make([block, later], now: "2026-10-19T10:35", lead: 5, running: offPlan)
        #expect(five.contains { $0.id == AppNotification.blockStartID })
        #expect(notices(five).map(\.trigger) == [.at(jst("2026-10-19T10:55")), .at(jst("2026-10-19T13:55"))])
        // 「予定の時間の通知」がオフで TMR-11 が出ないなら、こちらを出す
        let off = make([block, later], now: "2026-10-19T10:35", lead: 0, running: offPlan, plannedEndEnabled: false)
        #expect(!off.contains { $0.id == AppNotification.blockStartID })
        #expect(notices(off).map(\.trigger) == [.at(jst("2026-10-19T11:00")), .at(jst("2026-10-19T14:00"))])
    }

    /// 「ちょうど」で予定の時間（TMR-05）と同じ時刻なら予定の時間の通知だけ
    @Test func exactDefersToPlannedEnd() {
        let first = summary("2026-10-19T10:00", 60)
        let next = summary("2026-10-19T11:00", 60, title: "ゼミ準備")
        var planned = session("2026-10-19T10:00", nil, plannedEnd: "2026-10-19T11:00")
        planned.planBlockId = first.id
        let n = make([first, next], now: "2026-10-19T10:30", lead: 0, running: planned, started: [first.id])
        #expect(n.contains { $0.id == AppNotification.plannedEndID })
        #expect(notices(n).isEmpty)
        // 予定の時間の通知がオフならこちらを出す
        let off = make([first, next], now: "2026-10-19T10:30", lead: 0, running: planned, started: [first.id],
                       plannedEndEnabled: false)
        #expect(notices(off).map(\.trigger) == [.at(jst("2026-10-19T11:00"))])
    }

    /// 3:59 に足した 4:05 のブロックは、5分前の 4:00 に出す（3:59 から見て先なので）
    @Test func justBeforeFourAm() {
        let block = summary("2026-10-20T04:05", 60)
        #expect(notices(make([block], now: "2026-10-20T03:59")).first?.trigger == .at(jst("2026-10-20T04:00")))
    }

    /// ゲーム・SNS の時間だけの日は何も出さない
    @Test func gameTimeNeverGetsANotice() {
        let game = summary("2026-10-19T20:00", 60, .gameSNS, title: "ゲーム・SNS")
        #expect(notices(make([game], now: "2026-10-19T08:00")).isEmpty)
        #expect(notices(make([game], now: "2026-10-19T08:00", lead: 0)).isEmpty)
    }

    /// 前のブロックの終わりちょうどに始まるブロックは、前のブロックがもう終わっていれば［今から始める］の本文
    @Test func adjacentBlockEndIsNotOngoing() {
        let first = summary("2026-10-19T10:00", 55)
        let next = summary("2026-10-19T11:00", 60, title: "ゼミ準備")
        // 10:55 に前のブロックは終わっている（終わりは含まない）
        #expect(notices(make([first, next], now: "2026-10-19T08:00")).last?.body == "11:00 から。開いて［今から始める］で記録できます。")
    }

    /// 「予定の時間の通知」がオフでも、5分前は出る
    @Test func plannedEndOffDoesNotStopNotices() {
        let block = summary("2026-10-19T11:00", 60)
        #expect(notices(make([block], now: "2026-10-19T08:00", plannedEndEnabled: false)).map(\.trigger) == [.at(jst("2026-10-19T10:55"))])
    }

    /// 近い順に60件まで
    @Test func atMostSixtyNearest() {
        let blocks = (0..<70).map { i in summary("2026-10-19T05:00", 1).moved(by: Double(i * 15 * 60)) }
        let n = notices(make(blocks, now: "2026-10-19T04:30"))
        #expect(n.count == 60)
        #expect(n.first?.trigger == .at(jst("2026-10-19T04:55")))
    }
}

private extension PlanBlockSummary {
    func moved(by seconds: TimeInterval) -> PlanBlockSummary {
        var copy = self
        copy.id = UUID()
        copy.start = start.addingTimeInterval(seconds)
        copy.end = end.addingTimeInterval(seconds)
        return copy
    }
}

/// 予約の置き換え（本物の UserNotificationScheduler を偽の通知センターで）。
@MainActor
struct NotificationSchedulerTests {
    private final class FakeCenter: NotificationCenterScheduling {
        var pending: [String: Date] = [:]
        func removeAllPendingNotificationRequests() { pending = [:] }
        func add(_ request: PendingNotification) {
            if case .at(let date) = request.trigger { pending[request.identifier] = date } else { pending[request.identifier] = .distantFuture }
        }
    }

    private func notification(_ id: String, at date: String) -> AppNotification {
        AppNotification(id: id, title: "t", body: "b", trigger: .at(jst(date)))
    }

    /// 計画の時刻の通知（TMR-11）が、なくなったら取り消される（2026-10-04 までは残っていた）
    @Test func droppedNotificationsAreRemoved() {
        let center = FakeCenter()
        let scheduler = UserNotificationScheduler(center: center, calendar: { tokyoCalendar })
        scheduler.replaceAll(with: [notification(AppNotification.blockStartID, at: "2026-10-19T10:00"),
                                    notification(AppNotification.reviewID, at: "2026-10-19T22:00")])
        scheduler.replaceAll(with: [notification(AppNotification.reviewID, at: "2026-10-19T22:00")])
        #expect(Set(center.pending.keys) == [AppNotification.reviewID])
    }

    /// 開き直したアプリ（新しい予約係）でも、前に予約したものを残さない
    @Test func freshSchedulerClearsStaleRequests() {
        let center = FakeCenter()
        UserNotificationScheduler(center: center, calendar: { tokyoCalendar })
            .replaceAll(with: [notification("blockNotice-old", at: "2026-10-19T10:55")])
        UserNotificationScheduler(center: center, calendar: { tokyoCalendar })
            .replaceAll(with: [notification("blockNotice-new", at: "2026-10-19T11:55")])
        #expect(Set(center.pending.keys) == ["blockNotice-new"])
        #expect(center.pending["blockNotice-new"] == jst("2026-10-19T11:55"))
    }

    /// タイムゾーンが変わったら、同じ中身でも予約し直す
    @Test func timeZoneChangeReschedules() {
        let center = FakeCenter()
        var calendar = tokyoCalendar
        let scheduler = UserNotificationScheduler(center: center, calendar: { calendar })
        let list = [notification("blockNotice-a", at: "2026-10-19T10:55")]
        scheduler.replaceAll(with: list)
        center.pending = [:]
        scheduler.replaceAll(with: list)
        #expect(center.pending.isEmpty)  // 同じなら何もしない
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        scheduler.replaceAll(with: list)
        #expect(center.pending["blockNotice-a"] == jst("2026-10-19T10:55"))
    }
}

/// 計画ブロックの前の通知（本体 AppModel）。
@MainActor
struct BlockNoticeModelTests {
    /// 確定した計画（9:00–10:30 英語、11:00–13:00 ゼミ準備）を持つ AppModel
    private func model(_ t: TestStore, notifications: NoNotifications, settings: MemorySettings = MemorySettings(),
                       confirm: Bool = true) async throws -> AppModel {
        settings.didShowBlockingIntro = true
        let m = AppModel(store: t.store, clock: t.clock, timeZone: { tokyo }, settings: settings, notifications: notifications)
        let seminar = try #require(m.createProject(name: "ゼミ準備", category: m.categories[0]))
        let draft = PlanDraft(blocks: [
            PlanBlockDraft(start: jst("2026-10-19T09:00"), minutes: 90, category: m.categories[0]),
            PlanBlockDraft(start: jst("2026-10-19T11:00"), minutes: 120, category: m.categories[0], project: seminar),
        ])
        if confirm { m.confirmPlan(draft) } else { m.saveDraft(draft) }
        await m.refreshNotificationStatus()
        return m
    }

    private func noticeTimes(_ n: NoNotifications) -> [AppNotification.Trigger] {
        n.scheduled.filter { $0.id.hasPrefix(AppNotification.blockNoticePrefix) }.map(\.trigger)
    }

    @Test func confirmedPlanSchedulesNotices() async throws {
        let t = try TestStore(now: jst("2026-10-19T08:00"))
        let n = NoNotifications(status: .authorized)
        _ = try await model(t, notifications: n)
        #expect(noticeTimes(n) == [.at(jst("2026-10-19T08:55")), .at(jst("2026-10-19T10:55"))])
    }

    /// 計画を変えたら予約も置き換わる（動かす・消す・足す）
    @Test func editingThePlanReplacesNotices() async throws {
        let t = try TestStore(now: jst("2026-10-19T08:00"))
        let n = NoNotifications(status: .authorized)
        let m = try await model(t, notifications: n)
        var draft = try #require(m.plan)
        let seminarIndex = try #require(draft.blocks.firstIndex { $0.start == jst("2026-10-19T11:00") })
        draft.blocks[seminarIndex].start = jst("2026-10-19T12:00")
        #expect(m.savePlanChanges(draft))
        #expect(noticeTimes(n) == [.at(jst("2026-10-19T08:55")), .at(jst("2026-10-19T11:55"))])

        draft.blocks.removeAll { $0.start == jst("2026-10-19T09:00") }
        draft.blocks.append(PlanBlockDraft(start: jst("2026-10-19T15:00"), minutes: 30, category: m.categories[0]))
        #expect(m.savePlanChanges(draft))
        #expect(noticeTimes(n) == [.at(jst("2026-10-19T11:55")), .at(jst("2026-10-19T14:55"))])
    }

    @Test func noNoticesForDraftsOrWithoutPermission() async throws {
        let t = try TestStore(now: jst("2026-10-19T08:00"))
        let draftOnly = NoNotifications(status: .authorized)
        _ = try await model(t, notifications: draftOnly, confirm: false)
        #expect(noticeTimes(draftOnly).isEmpty)

        let t2 = try TestStore(now: jst("2026-10-19T08:00"))
        let denied = NoNotifications(status: .denied)
        _ = try await model(t2, notifications: denied)
        #expect(denied.scheduled.isEmpty)
    }

    /// 前倒しで始めたブロックには出さない。終えたあとも出さない
    @Test func earlyStartedBlockHasNoNotice() async throws {
        let t = try TestStore(now: jst("2026-10-19T10:40"))
        let n = NoNotifications(status: .authorized)
        let m = try await model(t, notifications: n)
        #expect(noticeTimes(n) == [.at(jst("2026-10-19T10:55"))])
        m.startPlanned(block: try #require(m.snapshot.earlyStartBlock))
        #expect(noticeTimes(n).isEmpty)
        t.clock.set(jst("2026-10-19T10:50"))
        m.end(reportedEnd: nil)
        #expect(noticeTimes(n).isEmpty)
    }

    /// 計画しない日は出さない
    @Test func skippedDayHasNoNotices() async throws {
        let t = try TestStore(now: jst("2026-10-19T08:00"))
        let n = NoNotifications(status: .authorized)
        let settings = MemorySettings()
        settings.didShowBlockingIntro = true
        let m = AppModel(store: t.store, clock: t.clock, timeZone: { tokyo }, settings: settings, notifications: n)
        m.skipPlan()
        await m.refreshNotificationStatus()
        #expect(noticeTimes(n).isEmpty)
    }

    /// 4:00 を過ぎて次の日になると、前の日の計画の予約は消える（次の日はまだ確定していない）
    @Test func rollingOverFourDropsYesterdaysNotices() async throws {
        let t = try TestStore(now: jst("2026-10-19T08:00"))
        let n = NoNotifications(status: .authorized)
        let m = try await model(t, notifications: n)
        var draft = try #require(m.plan)
        draft.blocks.append(PlanBlockDraft(start: jst("2026-10-20T03:30"), minutes: 20, category: m.categories[0]))
        #expect(m.savePlanChanges(draft))
        t.clock.set(jst("2026-10-19T23:00"))
        m.reload()
        #expect(noticeTimes(n) == [.at(jst("2026-10-20T03:25"))])
        t.clock.set(jst("2026-10-20T04:00"))
        m.reload()
        #expect(noticeTimes(n).isEmpty)
    }

    /// 設定で選んだ分。保存していなければ5分前。オフなら出さない
    @Test func leadMinutesSetting() async throws {
        let t = try TestStore(now: jst("2026-10-19T08:00"))
        let n = NoNotifications(status: .authorized)
        let settings = MemorySettings()
        let m = try await model(t, notifications: n, settings: settings)
        #expect(m.blockNoticeMinutes == 5)
        m.setBlockNoticeMinutes(15)
        #expect(settings.blockNoticeMinutes == 15)
        #expect(noticeTimes(n).first == .at(jst("2026-10-19T08:45")))
        m.setBlockNoticeMinutes(nil)
        #expect(settings.blockNoticeMinutes == nil)
        #expect(noticeTimes(n).isEmpty)
        #expect(n.scheduled.map(\.id) == [AppNotification.reviewID])
    }
}

@MainActor
struct BlockNoticeSettingsTests {
    @Test func storedLeadMinutes() throws {
        let defaults = try #require(UserDefaults(suiteName: "notice-test-\(UUID().uuidString)"))
        let settings = UserDefaultsSettings(defaults: defaults)
        #expect(settings.blockNoticeMinutes == 5)  // 項目がなければ5分前
        settings.blockNoticeMinutes = 0
        #expect(UserDefaultsSettings(defaults: defaults).blockNoticeMinutes == 0)
        settings.blockNoticeMinutes = nil
        #expect(UserDefaultsSettings(defaults: defaults).blockNoticeMinutes == nil)
        settings.blockNoticeMinutes = 10
        #expect(UserDefaultsSettings(defaults: defaults).blockNoticeMinutes == 10)
    }
}
