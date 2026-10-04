import Foundation
import Testing
@testable import FocusApp

/// ロック画面と画面上部のタイマー（focus-timer.md TMR-06）。
@MainActor
struct TimerActivityTests {
    private let study = CategoryOption(name: "勉強", countsAsFocus: true)

    private func session(start: String, plannedEnd: String? = nil, minutes: Int? = nil,
                         pauses: [PauseInterval] = []) -> FocusSession {
        FocusSession(id: UUID(), dayKey: "2026-10-19", category: study, project: ProjectOption(id: UUID(), name: "ゼミ準備", category: study),
                     planBlockId: nil, startAt: jst(start), endAt: nil, plannedEndAt: plannedEnd.map(jst),
                     plannedDurationSec: minutes.map { $0 * 60 }, pauses: pauses)
    }

    private func state(_ s: FocusSession, at now: String) -> TimerActivityAttributes.ContentState {
        TimerActivity.make(s, now: jst(now), timeZone: tokyo).state
    }

    // MARK: 中身

    @Test func attributesCarryNamesAndKind() {
        let s = session(start: "2026-10-19T11:20", plannedEnd: "2026-10-19T13:00")
        let a = TimerActivity.make(s, now: jst("2026-10-19T11:30"), timeZone: tokyo).attributes
        #expect(a.sessionId == s.id)
        #expect(a.title == "ゼミ準備")
        #expect(a.categoryName == "勉強")
        #expect(a.countsAsFocus)
    }

    @Test func plannedBlockCountsDownToBlockEnd() {
        let s = session(start: "2026-10-19T11:20", plannedEnd: "2026-10-19T13:00")
        let st = state(s, at: "2026-10-19T11:30")
        #expect(st.caption == "13:00 まで")
        #expect(st.reading == .countdown(to: jst("2026-10-19T13:00")))
        #expect(st.progress == .live(start: jst("2026-10-19T11:20"), end: jst("2026-10-19T13:00")))
    }

    @Test func captionUsesTwoDigitsAndTimeZone() {
        let s = session(start: "2026-10-19T08:30", minutes: 25)
        #expect(state(s, at: "2026-10-19T08:31").caption == "08:55 まで")
    }

    /// 0を過ぎても同じ値のまま（数字はそのまま超過を数え上げる。見出しは切り替えない）
    @Test func overtimeKeepsTheSameState() {
        let s = session(start: "2026-10-19T09:00", minutes: 25)
        #expect(state(s, at: "2026-10-19T09:10") == state(s, at: "2026-10-19T09:40"))
    }

    /// 時間がたっても値が変わらない（毎分の読み直しで無駄に書き換えない）
    @Test func runningStateDoesNotChangeOverTime() {
        let s = session(start: "2026-10-19T09:00", pauses: [PauseInterval(start: jst("2026-10-19T09:10"), end: jst("2026-10-19T09:15"))])
        let early = TimerActivity.make(s, now: jst("2026-10-19T09:20").addingTimeInterval(0.3), timeZone: tokyo).state
        let late = TimerActivity.make(s, now: jst("2026-10-19T09:51:07").addingTimeInterval(0.8), timeZone: tokyo).state
        #expect(early == late)
    }

    @Test func unplannedCountdownShiftsByPauses() {
        let s = session(start: "2026-10-19T09:00", minutes: 25,
                        pauses: [PauseInterval(start: jst("2026-10-19T09:10"), end: jst("2026-10-19T09:15"))])
        let st = state(s, at: "2026-10-19T09:20")
        #expect(st.caption == "09:30 まで")
        #expect(st.reading == .countdown(to: jst("2026-10-19T09:30")))
        #expect(st.progress == .live(start: jst("2026-10-19T09:05"), end: jst("2026-10-19T09:30")))
    }

    @Test func stopwatchCountsUpWithoutPauses() {
        let s = session(start: "2026-10-19T09:00", pauses: [PauseInterval(start: jst("2026-10-19T09:10"), end: jst("2026-10-19T09:15"))])
        let st = state(s, at: "2026-10-19T09:20")
        #expect(st.caption == "経過")
        #expect(st.reading == .countUp(from: jst("2026-10-19T09:05")))
        #expect(st.progress == .none)
    }

    // MARK: 一時停止中

    @Test func pausedUnplannedCountdownStops() {
        let s = session(start: "2026-10-19T09:00", minutes: 25, pauses: [PauseInterval(start: jst("2026-10-19T09:10"), end: nil)])
        let st = state(s, at: "2026-10-19T09:20")
        #expect(st.caption == "一時停止中")
        #expect(st.reading == .fixed(seconds: 15 * 60, overtime: false))
        #expect(st.progress == .fixed(10.0 / 25.0))
    }

    @Test func pausedInOvertimeShowsOvertime() {
        let s = session(start: "2026-10-19T09:00", minutes: 25, pauses: [PauseInterval(start: jst("2026-10-19T09:28"), end: nil)])
        let st = state(s, at: "2026-10-19T09:40")
        #expect(st.reading == .fixed(seconds: 3 * 60, overtime: true))
        #expect(st.progress == .fixed(1))
    }

    /// 計画ブロックから始めたものは、一時停止中も減り続ける
    @Test func pausedPlannedBlockKeepsCountingDown() {
        let s = session(start: "2026-10-19T11:00", plannedEnd: "2026-10-19T13:00",
                        pauses: [PauseInterval(start: jst("2026-10-19T11:30"), end: nil)])
        let st = state(s, at: "2026-10-19T12:00")
        #expect(st.caption == "一時停止中")
        #expect(st.reading == .countdown(to: jst("2026-10-19T13:00")))
        #expect(st.progress == .fixed(30.0 / 90.0))
    }

    @Test func pausedStopwatchStops() {
        let s = session(start: "2026-10-19T09:00", pauses: [PauseInterval(start: jst("2026-10-19T09:42"), end: nil)])
        let st = state(s, at: "2026-10-19T10:00")
        #expect(st.caption == "一時停止中")
        #expect(st.reading == .fixed(seconds: 42 * 60, overtime: false))
        #expect(st.progress == .none)
    }

    /// 見本の時計（-fixedNow）のときは、iPhone の時計に合わせて時刻をずらす。見出しの時刻はずらさない
    @Test func shiftedMovesOnlyDates() {
        let s = session(start: "2026-10-19T09:00", minutes: 25)
        let st = state(s, at: "2026-10-19T09:10")
        let shifted = st.shifted(by: 3600)
        #expect(shifted.caption == "09:25 まで")
        #expect(shifted.reading == .countdown(to: jst("2026-10-19T10:25")))
        #expect(shifted.progress == .live(start: jst("2026-10-19T10:00"), end: jst("2026-10-19T10:25")))
        #expect(st.shifted(by: 0) == st)
    }

    @Test func detoxCategoryIsNotFocus() {
        let rest = CategoryOption(name: "運動", countsAsFocus: false)
        var s = session(start: "2026-10-19T09:00")
        s.category = rest
        s.project = nil
        let a = TimerActivity.make(s, now: jst("2026-10-19T09:10"), timeZone: tokyo).attributes
        #expect(a.title == "運動")
        #expect(!a.countsAsFocus)
    }

    @Test func captionFollowsGivenTimeZone() {
        let s = session(start: "2026-10-19T09:00", minutes: 25)
        #expect(TimerActivity.make(s, now: jst("2026-10-19T09:10"), timeZone: TimeZone(identifier: "UTC")!).state.caption == "00:25 まで")
    }

    /// 0ちょうどでも、0を過ぎても、数え下げの値のまま（iPhone が超過を数え上げる）
    @Test func exactlyAtPlannedEndKeepsCountdown() {
        let s = session(start: "2026-10-19T09:00", minutes: 25)
        let st = state(s, at: "2026-10-19T09:25")
        #expect(st.reading == .countdown(to: jst("2026-10-19T09:25")))
        #expect(st == state(s, at: "2026-10-19T09:10"))
    }

    /// ブロックの終わりを過ぎてから始めたときも、円の範囲が逆にならない（拡張が落ちない）
    @Test func startedAfterBlockEndHasFullRing() {
        let s = session(start: "2026-10-19T13:30", plannedEnd: "2026-10-19T13:00")
        let st = state(s, at: "2026-10-19T13:31")
        #expect(st.reading == .countdown(to: jst("2026-10-19T13:00")))
        #expect(st.progress == .live(start: jst("2026-10-19T13:00"), end: jst("2026-10-19T13:00")))
    }

    @Test func shiftedBackwardAndFixedValuesStay() {
        let paused = state(session(start: "2026-10-19T09:00", minutes: 25, pauses: [PauseInterval(start: jst("2026-10-19T09:10"), end: nil)]),
                           at: "2026-10-19T09:20")
        #expect(paused.shifted(by: -600) == paused)
        let running = state(session(start: "2026-10-19T09:00"), at: "2026-10-19T09:20")
        #expect(running.shifted(by: -600).reading == .countUp(from: jst("2026-10-19T08:50")))
    }

    // MARK: AppModel から出し入れする

    @Test func startPauseResumeEndDriveTheActivity() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        try t.seeded()
        let live = NoLiveActivity()
        let m = AppModel(store: t.store, clock: t.clock, timeZone: { tokyo }, liveActivity: live)
        #expect(live.shown == nil)

        m.startUnplanned(category: m.categories[0], minutes: 25)
        let started = try #require(live.shown)
        #expect(started.attributes.sessionId == m.running?.id)
        #expect(started.state.reading == .countdown(to: jst("2026-10-19T09:25")))

        t.clock.advance(600)
        m.pause()
        #expect(live.shown?.state.caption == "一時停止中")
        t.clock.advance(300)
        m.resume()
        #expect(live.shown?.state.reading == .countdown(to: jst("2026-10-19T09:30")))

        m.end(reportedEnd: nil)
        #expect(live.shown == nil)
    }

    /// アプリを開き直したとき（iPhone の再起動のあとなど）、実行中のタイマーがあれば出し直す
    @Test func relaunchShowsRunningTimerAgain() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        try t.seeded()
        let first = AppModel(store: t.store, clock: t.clock, timeZone: { tokyo })
        first.startUnplanned(category: first.categories[0], minutes: nil)

        t.clock.advance(3600)
        let live = NoLiveActivity()
        _ = AppModel(store: t.store, clock: t.clock, timeZone: { tokyo }, liveActivity: live)
        #expect(live.shown?.state.reading == .countUp(from: jst("2026-10-19T09:00")))
    }

    private func model(_ t: TestStore, _ live: NoLiveActivity) -> AppModel {
        AppModel(store: t.store, clock: t.clock, timeZone: { tokyo }, liveActivity: live)
    }

    /// 1分未満で記録しなかったときも消える
    @Test func discardedTooShortRemovesTheActivity() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        try t.seeded()
        let live = NoLiveActivity()
        let m = model(t, live)
        m.startUnplanned(category: m.categories[0], minutes: 25)
        t.clock.advance(30)
        m.end(reportedEnd: nil)
        #expect(m.notice == AppModel.discardedNotice)
        #expect(live.shown == nil)
    }

    /// 止め忘れの確認が出ている間・閉じたあとは残り、「この時刻で終了」で消える
    @Test func endTimeCheckKeepsActivityUntilEnded() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        try t.seeded()
        let live = NoLiveActivity()
        let m = model(t, live)
        m.startUnplanned(category: m.categories[0], minutes: 25)
        t.clock.advance(3600)
        m.requestEnd()
        #expect(m.endTimeCheck != nil)
        #expect(live.shown != nil)

        m.endTimeCheck = nil  // 閉じる（終了しない）
        m.reload()
        #expect(live.shown != nil)

        m.end(reportedEnd: jst("2026-10-19T09:25"))
        #expect(live.shown == nil)
    }

    /// 毎分の読み直しや朝4:00をまたいでも、同じ値のまま（無駄に書き換えない）
    @Test func repeatedReloadAndCrossing4amKeepTheSameState() throws {
        let t = try TestStore(now: jst("2026-10-20T03:50"))
        try t.seeded()
        let live = NoLiveActivity()
        let m = model(t, live)
        m.startUnplanned(category: m.categories[0], minutes: 60)
        let first = try #require(live.shown)
        for _ in 0..<25 {
            t.clock.advance(61)
            m.reload(quietly: true)
            #expect(live.shown == first)
        }
        #expect(t.clock.now() > jst("2026-10-20T04:00"))
    }

    /// 計画ブロックから始めたものは、ブロックの終わりまで数え下げる
    @Test func plannedStartShowsBlockEnd() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        try t.seeded()
        let live = NoLiveActivity()
        let m = model(t, live)
        m.confirmPlan(PlanDraft(blocks: [PlanBlockDraft(start: jst("2026-10-19T09:00"), minutes: 70, category: m.categories[0])]))
        t.clock.set(jst("2026-10-19T09:20"))
        m.reload()
        m.startPlanned(block: try #require(m.snapshot.currentBlock))
        #expect(live.shown?.state.caption == "10:10 まで")
        #expect(live.shown?.state.reading == .countdown(to: jst("2026-10-19T10:10")))
    }
}
