import Foundation
import Testing
@testable import FocusApp

/// ウィジェット（WID-01）の材料と、先の時刻の表示
struct WidgetSnapshotTests {
    private func block(_ title: String, _ from: String, _ to: String, game: Bool = false) -> WidgetSnapshot.Block {
        .init(title: title, start: jst("2026-10-19T\(from)"), end: jst("2026-10-19T\(to)"), isGameTime: game)
    }

    private func snapshot(running: Bool = false, ghost: [Int] = []) -> WidgetSnapshot {
        WidgetSnapshot(generatedAt: jst("2026-10-19T10:00"), dayStart: jst("2026-10-19T04:00"), dayEnd: jst("2026-10-20T04:00"),
                       blocks: [block("英語", "09:00", "10:30"), block("ゼミ準備", "11:00", "13:00"),
                                block("ゲーム・SNS", "20:00", "20:30", game: true)],
                       focusSeconds: 3600, runningStart: running ? jst("2026-10-19T10:00") : nil,
                       runningEnd: running ? jst("2026-10-19T10:30") : nil, ghostCurve: ghost)
    }

    @Test func nowOrNextBlock() {
        let s = snapshot()
        #expect(s.entry(at: jst("2026-10-19T10:00")).line == .now(block("英語", "09:00", "10:30")))
        #expect(s.entry(at: jst("2026-10-19T10:45")).line == .next(block("ゼミ準備", "11:00", "13:00")))
        #expect(s.entry(at: jst("2026-10-19T19:00")).line == .next(block("ゲーム・SNS", "20:00", "20:30", game: true)))
        #expect(s.entry(at: jst("2026-10-19T21:00")).line == .none)
    }

    @Test func runningTimerKeepsCountingUntilItsPlannedEnd() {
        let s = snapshot(running: true)
        #expect(s.entry(at: jst("2026-10-19T10:15")).focusSeconds == 3600 + 900)
        #expect(s.entry(at: jst("2026-10-19T11:00")).focusSeconds == 3600 + 1800)
        // タイマーなしなら増えない
        #expect(snapshot().entry(at: jst("2026-10-19T11:00")).focusSeconds == 3600)
    }

    @Test func diffAgainstLastWeekInterpolatesTheCurve() {
        // 4:00 から10分ごと：先週は 10:00（36コマ目）に 3000秒、10:10 に 3600秒
        var curve = Array(repeating: 0, count: 145)
        for index in 36..<145 { curve[index] = index == 36 ? 3000 : 3600 }
        let s = snapshot(ghost: curve)
        #expect(s.entry(at: jst("2026-10-19T10:00")).ghostSeconds == 3000)
        #expect(s.entry(at: jst("2026-10-19T10:05")).ghostSeconds == 3300)
        #expect(s.entry(at: jst("2026-10-19T10:05")).diffSeconds == 300)
        #expect(snapshot().entry(at: jst("2026-10-19T10:05")).diffSeconds == nil)
    }

    @Test func afterTheDayEndsAskToOpenTheApp() {
        let entry = snapshot().entry(at: jst("2026-10-20T04:00"))
        #expect(entry.isStale)
    }

    @Test func entriesEveryFifteenMinutesAndAtBlockEdges() {
        let dates = snapshot().entryDates(from: jst("2026-10-19T10:20"))
        #expect(dates.first == jst("2026-10-19T10:20"))
        #expect(dates.contains(jst("2026-10-19T10:35")))
        #expect(dates.contains(jst("2026-10-19T10:30")))  // 英語の終わり
        #expect(dates.contains(jst("2026-10-19T11:00")))  // ゼミ準備の始まり
        #expect(dates.last! <= jst("2026-10-19T16:20"))
        // 夜は日の終わり（翌4:00）まで
        #expect(snapshot().entryDates(from: jst("2026-10-20T01:00")).last == jst("2026-10-20T04:00"))
    }

    @Test func roundTripsThroughUserDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "widget-test-\(UUID())"))
        let s = snapshot(running: true, ghost: [0, 600])
        defaults.set(try JSONEncoder().encode(s), forKey: WidgetSnapshot.key)
        #expect(WidgetSnapshot.load(from: defaults) == s)
        #expect(WidgetSnapshot.load(from: UserDefaults(suiteName: "widget-empty-\(UUID())")) == nil)
    }
}

/// 本体からウィジェットへ渡す材料
@MainActor
struct WidgetPublishTests {
    @Test func modelPublishesTheConfirmedPlanAndLastWeek() throws {
        let t = try TestStore(now: jst("2026-10-12T09:00"))
        let c = try t.seeded()
        _ = try t.store.start(StartRequest(category: c[0], timeZone: tokyo))
        t.clock.set(jst("2026-10-12T10:00"))
        _ = try t.store.end(id: try #require(try t.store.runningSession()).id, reportedEnd: nil)
        t.clock.set(jst("2026-10-19T07:00"))
        let widgets = MemoryWidgetPublisher()
        let settings = MemorySettings()
        settings.didShowBlockingIntro = true
        let m = AppModel(store: t.store, clock: t.clock, timeZone: { tokyo }, settings: settings, widgets: widgets)
        // 下書きのうちは予定を渡さない
        #expect(widgets.published.last?.blocks.isEmpty == true)
        m.confirmPlan(PlanDraft(blocks: [PlanBlockDraft(start: jst("2026-10-19T11:00"), minutes: 120, category: c[0])]))
        let last = try #require(widgets.published.last)
        #expect(last.blocks.map(\.title) == ["勉強"])
        #expect(last.ghost(at: jst("2026-10-19T10:00")) == 3600)
        #expect(last.runningStart == nil)
        // タイマーを始めると数え始めを渡す
        t.clock.set(jst("2026-10-19T11:05"))
        m.reload()
        m.startPlanned(block: try #require(m.snapshot.currentBlock))
        #expect(widgets.published.last?.runningStart == jst("2026-10-19T11:05"))
        // 5分遅れて始めたので終わりも5分後ろ（TMR-15）
        #expect(widgets.published.last?.runningEnd == jst("2026-10-19T13:05"))
    }

    @Test func pausedTimerStopsCountingAndPlanChangesArePublished() throws {
        let t = try TestStore(now: jst("2026-10-19T07:00"))
        let c = try t.seeded()
        let widgets = MemoryWidgetPublisher()
        let settings = MemorySettings()
        settings.didShowBlockingIntro = true
        let m = AppModel(store: t.store, clock: t.clock, timeZone: { tokyo }, settings: settings, widgets: widgets)
        m.confirmPlan(PlanDraft(blocks: [PlanBlockDraft(start: jst("2026-10-19T09:00"), minutes: 60, category: c[0])]))
        t.clock.set(jst("2026-10-19T09:05"))
        m.reload()
        m.startPlanned(block: try #require(m.snapshot.currentBlock))
        m.pause()
        // 一時停止中は数え始めを渡さない（差が進まない）
        let paused = try #require(widgets.published.last)
        #expect(paused.runningStart == nil)
        #expect(paused.entry(at: jst("2026-10-19T09:30")).focusSeconds == paused.focusSeconds)
        // 計画を変えると渡し直す
        var plan = try #require(m.plan)
        plan.upsert(PlanBlockDraft(start: jst("2026-10-19T14:00"), minutes: 60, category: c[2]))
        m.savePlanChanges(plan)
        #expect(widgets.published.last?.blocks.count == 2)
        // 先週の記録がなければ差は出さない
        #expect(widgets.published.last?.entry(at: jst("2026-10-19T10:00")).diffSeconds == nil)
    }
}
