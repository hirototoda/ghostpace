import Foundation
import Testing
@testable import FocusApp

/// デジタルデトックスの時間とポイント（digital-detox.md、DTX-01・DTX-03）。
struct DetoxDayTests {
    private let dayStart = jst("2026-10-19T04:00")
    private let dayEnd = jst("2026-10-20T04:00")

    private func event(_ kind: BlockEvent.Kind, _ time: String, since: String? = nil, minutes: Int? = nil) -> BlockEvent {
        BlockEvent(occurredAt: jst(time), timeZoneId: "Asia/Tokyo", kind: kind, unlockMinutes: minutes,
                   sinceAt: since.map(jst))
    }

    private func interval(_ start: String, _ end: String) -> DateInterval { DateInterval(start: jst(start), end: jst(end)) }

    private func day(events: [BlockEvent] = [], focus: [DateInterval] = [], timers: [DateInterval] = [],
                     sleep: [DateInterval] = [], games: [DateInterval] = [], until: Date? = nil) -> DetoxDay {
        DetoxDay.make(.init(dayStart: dayStart, dayEnd: dayEnd, until: until ?? dayEnd,
                            events: [event(.started, "2026-10-01T09:00")] + events,
                            focus: focus, detoxTimers: timers.map { DetoxTimer(interval: $0, group: .rest) }, sleep: sleep,
                            gameWindows: games))
    }

    /// digital-detox.md の例の日：デトックス 21時間
    @Test func exampleDayIsTwentyOneHours() {
        let d = day(
            events: [event(.unlocked, "2026-10-19T10:00", minutes: 15), event(.reblocked, "2026-10-19T10:15"),
                     event(.unblockStarted, "2026-10-19T20:00"), event(.unblockEnded, "2026-10-19T20:30")],
            focus: [interval("2026-10-19T09:00", "2026-10-19T12:00")],
            timers: [interval("2026-10-19T17:00", "2026-10-19T17:30")],
            sleep: [interval("2026-10-19T00:00", "2026-10-19T07:00"), interval("2026-10-20T00:00", "2026-10-20T07:00")],
            games: [interval("2026-10-19T20:00", "2026-10-19T20:30")])
        #expect(d.detoxSeconds(until: dayEnd) == 21 * 3600)
        #expect(d.isComplete)
    }

    /// ポイントの例：起きてから3時間、開けずにブロック中 → 9.0pt（2026-10-03 から続けたボーナスなし、ADR-0019）
    @Test func threeHoursBlockedIsNinePoints() {
        let d = day(until: jst("2026-10-19T07:00"))
        // 4:00〜7:00 の3時間（寝ていない）
        #expect(abs(d.points(until: jst("2026-10-19T07:00")) - 9.0) < 0.0001)
    }

    @Test func weightsByKind() {
        let d = day(timers: [interval("2026-10-19T04:00", "2026-10-19T04:10")],
                    sleep: [interval("2026-10-19T04:10", "2026-10-19T04:20")], until: jst("2026-10-19T04:30"))
        // 休みのタイマー 0.75、寝ている（寝てから7時間まで）0.75、ふつう 0.5
        #expect(abs(d.points(until: jst("2026-10-19T04:30")) - 2.0) < 0.0001)
        #expect(d.detoxSeconds(until: jst("2026-10-19T04:30")) == 30 * 60)
    }

    /// 予定どおりのゲーム・SNS の時間はそのまま数え、予定を過ぎて開いていた分は数えない
    @Test func gameOverrunIsNotDetox() {
        let d = day(events: [event(.unblockStarted, "2026-10-19T20:00"), event(.unblockEnded, "2026-10-19T20:45")],
                    games: [interval("2026-10-19T20:00", "2026-10-19T20:30")], until: jst("2026-10-19T21:00"))
        let full = 17 * 3600
        #expect(d.detoxSeconds(until: jst("2026-10-19T21:00")) == full - 15 * 60)
    }

    /// 許可が外れていた間は、前に確かめた時刻から数えない
    /// 「外れた」から2分以内に「戻った」組は、一瞬「未確認」と返った誤記録とみなして数えない（過去の記録にも、2026-10-03）
    @Test func briefAuthorizationBlipIsIgnored() {
        let blip = day(events: [event(.authorizationLost, "2026-10-19T09:00", since: "2026-10-19T08:00"),
                                event(.authorizationRestored, "2026-10-19T09:02")], until: jst("2026-10-19T12:00"))
        #expect(blip.detoxSeconds(until: jst("2026-10-19T12:00")) == 8 * 3600)
        #expect(abs(blip.points(until: jst("2026-10-19T12:00")) - 24.0) < 0.0001)
        // 2分を超えたら、前に確かめた時刻から外れていた
        let real = day(events: [event(.authorizationLost, "2026-10-19T09:00", since: "2026-10-19T08:00"),
                                event(.authorizationRestored, "2026-10-19T09:03")], until: jst("2026-10-19T12:00"))
        #expect(real.detoxSeconds(until: jst("2026-10-19T12:00")) == 8 * 3600 - 63 * 60)
    }

    @Test func authorizationLostCountsFromLastCheck() {
        let d = day(events: [event(.authorizationLost, "2026-10-19T09:00", since: "2026-10-19T08:00"),
                             event(.authorizationRestored, "2026-10-19T10:00")], until: jst("2026-10-19T12:00"))
        #expect(d.detoxSeconds(until: jst("2026-10-19T12:00")) == 8 * 3600 - 2 * 3600)
    }

    @Test func selectionLostStopsUntilPickedAgain() {
        let d = day(events: [event(.selectionLost, "2026-10-19T08:00"), event(.started, "2026-10-19T09:00")],
                    until: jst("2026-10-19T10:00"))
        #expect(d.detoxSeconds(until: jst("2026-10-19T10:00")) == 5 * 3600)
    }

    /// 重なりは1回だけ除く。集中中に開けた15分もデトックスに入らず、開けた1回目の1pt を引く
    @Test func overlapsAreRemovedOnce() {
        let d = day(events: [event(.unlocked, "2026-10-19T10:00", minutes: 15), event(.reblocked, "2026-10-19T10:15")],
                    focus: [interval("2026-10-19T09:00", "2026-10-19T11:00")], until: jst("2026-10-19T12:00"))
        #expect(d.detoxSeconds(until: jst("2026-10-19T12:00")) == 8 * 3600 - 2 * 3600)
        #expect(d.pieces.first { $0.start == jst("2026-10-19T10:00") }?.kind == .opened)
        // 4:00〜9:00 の 15 ＋ 11:00〜12:00 の 3 − 1 ＝ 17
        #expect(abs(d.points(until: jst("2026-10-19T12:00")) - 17.0) < 0.0001)
    }

    // MARK: 記録の端（レビューで足した）

    /// 3:59 に開けて 4:10 に戻した：4:00〜4:10 は開いている
    @Test func unlockAcrossFourAm() {
        let d = day(events: [event(.unlocked, "2026-10-19T03:59", minutes: 15), event(.reblocked, "2026-10-19T04:10")],
                    until: jst("2026-10-19T05:00"))
        #expect(d.detoxSeconds(until: jst("2026-10-19T05:00")) == 50 * 60)
    }

    /// 許可が外れたまま戻っていない（前の日から）
    @Test func authorizationStillLost() {
        let d = day(events: [event(.authorizationLost, "2026-10-19T09:00", since: "2026-10-18T22:00")],
                    until: jst("2026-10-19T12:00"))
        #expect(d.detoxSeconds(until: jst("2026-10-19T12:00")) == 0)
    }

    /// 同じ記録が2回・順番が前後していても同じ
    @Test func duplicatesAndOrderDoNotMatter() {
        let events = [event(.reblocked, "2026-10-19T10:15"), event(.unlocked, "2026-10-19T10:00", minutes: 15),
                      event(.unlocked, "2026-10-19T10:05", minutes: 15), event(.started, "2026-10-05T09:00")]
        let d = day(events: events, until: jst("2026-10-19T12:00"))
        #expect(d.detoxSeconds(until: jst("2026-10-19T12:00")) == 8 * 3600 - 15 * 60)
    }

    /// ゲーム・SNS の時間で戻した記録がない（合図が届かず、まだ開いている）→ 予定を過ぎた分は数えない
    @Test func unblockNeverEnded() {
        let d = day(events: [event(.unblockStarted, "2026-10-19T20:00")],
                    games: [interval("2026-10-19T20:00", "2026-10-19T20:30")], until: jst("2026-10-19T21:00"))
        #expect(d.detoxSeconds(until: jst("2026-10-19T21:00")) == 16 * 3600 + 30 * 60)
    }

    /// 予定のない時間に外した記録（ほかの理由）→ 数えない
    @Test func unblockOutsidePlanIsOpen() {
        let d = day(events: [event(.unblockStarted, "2026-10-19T08:00"), event(.unblockEnded, "2026-10-19T08:30")],
                    until: jst("2026-10-19T09:00"))
        #expect(d.detoxSeconds(until: jst("2026-10-19T09:00")) == 4 * 3600 + 30 * 60)
    }

    /// 途中で選択が読めなくなった日は、丸1日分ではない扱いにはしない（4:00 に始めていれば完全）
    @Test func completenessDependsOnFourAm() {
        let lostAtNoon = day(events: [event(.selectionLost, "2026-10-19T12:00")])
        #expect(lostAtNoon.isComplete)
        let lostBefore = day(events: [event(.selectionLost, "2026-10-18T12:00"), event(.started, "2026-10-19T09:00")])
        #expect(!lostBefore.isComplete)
    }

    /// 始める前と、4:00 の時点で始めていなかった日（丸1日分ない）
    @Test func startedMidDayIsIncomplete() {
        let d = DetoxDay.make(.init(dayStart: dayStart, dayEnd: dayEnd, until: jst("2026-10-19T12:00"),
                                    events: [event(.started, "2026-10-19T10:00")], focus: [], detoxTimers: [], sleep: [],
                                    gameWindows: []))
        #expect(!d.isComplete)
        #expect(d.detoxSeconds(until: jst("2026-10-19T12:00")) == 2 * 3600)
        let none = DetoxDay.make(.init(dayStart: dayStart, dayEnd: dayEnd, until: dayEnd, events: [], focus: [],
                                       detoxTimers: [], sleep: [], gameWindows: []))
        #expect(none.detoxSeconds(until: dayEnd) == 0)
    }

    /// まだ戻っていない開けた時間は、今も開いているとみなす
    @Test func unlockStillOpenIsNotDetox() {
        let d = day(events: [event(.unlocked, "2026-10-19T11:50", minutes: 15)], until: jst("2026-10-19T12:00"))
        #expect(d.detoxSeconds(until: jst("2026-10-19T12:00")) == 8 * 3600 - 10 * 60)
    }

    @Test func untilStopsCounting() {
        let d = day(until: jst("2026-10-19T05:00"))
        #expect(d.detoxSeconds(until: dayEnd) == 3600)
        #expect(d.detoxSeconds(until: jst("2026-10-19T04:30")) == 1800)
    }

    @Test func shiftMovesLastWeekToToday() {
        let d = day(until: jst("2026-10-19T05:00")).shifted(by: 7 * 86400)
        #expect(d.pieces.first?.start == jst("2026-10-26T04:00"))
    }
}

/// 本体（AppModel）でのデトックス（DTX-04：ホーム・振り返り・先週の自分。画面の数字は DTX-05 の開けた時間）。
@MainActor
struct DetoxModelTests {
    private func model(_ t: TestStore, events: [BlockEvent]) -> AppModel {
        let log = MemoryBlockEventLog()
        for event in events { try? log.append(event) }
        let settings = MemorySettings()
        settings.didShowBlockingIntro = true
        settings.didLogBlockStart = true
        settings.lastBlockingAuthorized = true
        let blockStore = MemoryBlockStore()
        blockStore.state = BlockState(isEnabled: true)
        blockStore.selection = Data("sel".utf8)
        return AppModel(store: t.store, clock: t.clock, timeZone: { tokyo }, settings: settings,
                        blocking: FakeBlocking(), blockStore: blockStore, blockLog: log)
    }

    private func started(_ time: String) -> BlockEvent {
        BlockEvent(occurredAt: jst(time), timeZoneId: "Asia/Tokyo", kind: .started)
    }

    @Test func homeAndReviewUseBlockedTime() throws {
        let t = try TestStore(now: jst("2026-10-19T08:00"))
        try t.seeded()
        let m = model(t, events: [started("2026-10-01T09:00"),
                                  BlockEvent(occurredAt: jst("2026-10-19T10:00"), timeZoneId: "Asia/Tokyo", kind: .unlocked,
                                             unlockMinutes: 15),
                                  BlockEvent(occurredAt: jst("2026-10-19T10:15"), timeZoneId: "Asia/Tokyo", kind: .reblocked)])
        m.skipPlan()
        m.startUnplanned(category: m.categories[0], minutes: nil)  // 勉強
        t.clock.set(jst("2026-10-19T09:00"))
        m.end(reportedEnd: nil)
        t.clock.set(jst("2026-10-19T12:00"))
        m.reload()
        // デトックス（ポイントに使う）：4:00〜12:00 の8時間から、集中の1時間と開けた15分を除く
        #expect(m.snapshot.detox?.detoxSeconds(until: m.snapshot.now) == 7 * 3600 - 15 * 60)
        // 画面の数字は開けた時間（DTX-05）。ホームと振り返りで同じ
        #expect(m.snapshot.opened == OpenedTime(seconds: 15 * 60, count: 1))
        #expect(m.reviewContent()?.opened == m.snapshot.opened)
    }

    /// 記録から数えるとき、デトックスのタイマーにグループ（上限）が付く（DTX-03、2026-10-03）
    @Test func timersCarryTheirGroupThroughTheModel() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        try t.seeded()
        let m = model(t, events: [started("2026-10-01T09:00")])
        m.skipPlan()
        let exercise = try #require(m.categories.first { $0.name == "運動" })
        m.startUnplanned(category: exercise, minutes: nil)
        t.clock.set(jst("2026-10-19T11:00"))
        m.end(reportedEnd: nil)
        t.clock.set(jst("2026-10-19T12:00"))
        m.reload()
        let timers = try #require(m.snapshot.detox).pieces.filter { $0.kind == .detoxTimer }
        #expect(!timers.isEmpty)
        #expect(timers.allSatisfy { $0.group == .exercise })
    }

    /// 設定でグループを変えると、過去のタイマーも新しいグループで数える。集中に切り替えるとグループは消える（CAT-04、BD-26）
    @Test func groupChangeAppliesToPastTimersAndFocusClearsIt() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        try t.seeded()
        let m = model(t, events: [started("2026-10-01T09:00")])
        m.skipPlan()
        let walk = try #require(m.createCategory(name: "散歩", countsAsFocus: false))
        m.startUnplanned(category: walk, minutes: nil)
        t.clock.set(jst("2026-10-19T10:00"))
        m.end(reportedEnd: nil)
        m.reload()
        let before = try #require(m.snapshot.detox).points(until: m.snapshot.now)
        #expect(m.setCategoryGroup(walk, .exercise))
        m.reload()
        #expect(m.categories.first { $0 == walk }?.detoxGroup == .exercise)
        #expect(try #require(m.snapshot.detox).pieces.filter { $0.kind == .detoxTimer }.allSatisfy { $0.group == .exercise })
        // 散歩の1時間が 0.5pt から 0.75pt に：60分×0.025 ＝ 1.5pt 増える
        #expect(abs(try #require(m.snapshot.detox).points(until: m.snapshot.now) - before - 1.5) < 0.0001)
        let exercise = try #require(m.categories.first { $0 == walk })
        #expect(m.updateCategory(exercise, name: "散歩", countsAsFocus: true))
        #expect(m.categories.first { $0 == walk }?.detoxGroup == nil)
    }

    /// 手で長く直した睡眠は、長くした所を低いほうで数える（AppModel を通して、DTX-02・03）
    @Test func manuallyLengthenedSleepThroughTheModel() throws {
        let t = try TestStore(now: jst("2026-10-19T08:00"))
        try t.seeded()
        let settings = MemorySettings()
        settings.didShowBlockingIntro = true
        settings.didLogBlockStart = true
        settings.lastBlockingAuthorized = true
        settings.sleepStartMinutes = 0
        settings.sleepEndMinutes = 5 * 60
        let log = MemoryBlockEventLog()
        try log.append(started("2026-10-01T09:00"))
        let blockStore = MemoryBlockStore()
        blockStore.state = BlockState(isEnabled: true)
        blockStore.selection = Data("sel".utf8)
        let m = AppModel(store: t.store, clock: t.clock, timeZone: { tokyo }, settings: settings,
                         blocking: FakeBlocking(), blockStore: blockStore, blockLog: log)
        // 設定の 0:00〜5:00 を 23:00〜8:00 に直した → 4:00〜8:00（寝てから5〜9時間目）は長くした所
        #expect(m.setSleepManually(start: jst("2026-10-18T23:00"), end: jst("2026-10-19T08:00")))
        m.reload()
        // 6.0（5〜7時間目を0.5pt）＋3.0（7〜8時間目）＋0 ＝ 9.0（直す前と比べなければ 12.0）
        #expect(abs(try #require(m.snapshot.detox).points(until: jst("2026-10-19T08:00")) - 9.0) < 0.0001)
    }

    /// 長押しで開けて戻ったあと、開き直す（reload）とホームの数字が増える（DTX-05）
    @Test func openedGrowsAfterUnlockAndReload() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        try t.seeded()
        let log = MemoryBlockEventLog()
        try log.append(started("2026-10-01T09:00"))
        let settings = MemorySettings()
        settings.didShowBlockingIntro = true
        settings.didLogBlockStart = true
        settings.lastBlockingAuthorized = true
        let blockStore = MemoryBlockStore()
        blockStore.state = BlockState(isEnabled: true)
        blockStore.selection = Data("sel".utf8)
        let m = AppModel(store: t.store, clock: t.clock, timeZone: { tokyo }, settings: settings,
                         blocking: FakeBlocking(), blockStore: blockStore, blockLog: log)
        m.skipPlan()
        #expect(m.snapshot.opened == OpenedTime(seconds: 0, count: 0))
        #expect(m.unlock(minutes: 15))
        t.clock.set(jst("2026-10-19T09:10"))
        m.reload()
        #expect(m.snapshot.opened == OpenedTime(seconds: 10 * 60, count: 1))
    }

    @Test func lastWeekWithoutAFullDayHasNoDetox() throws {
        let t = try TestStore(now: jst("2026-10-12T09:00"))
        let c = try t.seeded()
        _ = try t.store.start(StartRequest(category: c[0], project: nil, planBlockId: nil, plannedEndAt: nil,
                                           plannedDurationSec: nil, timeZone: tokyo))
        t.clock.set(jst("2026-10-12T10:00"))
        let first = model(t, events: [started("2026-10-12T08:00")])
        first.end(reportedEnd: nil)
        // 先週の同じ曜日（10/12）は途中から始めたので「先週のデトックスはなし」
        t.clock.set(jst("2026-10-19T12:00"))
        let m = model(t, events: [started("2026-10-12T08:00")])
        #expect(m.snapshot.ghost != nil)
        #expect(m.snapshot.ghostDetox == nil)

        // ずっと前から始めていれば、先週のデトックスがある
        let full = model(t, events: [started("2026-10-01T08:00")])
        #expect(full.snapshot.ghostDetox != nil)
    }
}
