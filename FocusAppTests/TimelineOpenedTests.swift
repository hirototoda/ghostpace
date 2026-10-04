import Foundation
import Testing
@testable import FocusApp

/// タイムラインの開けた時間と回数（TML-05。数え方・言葉・出さない日はホームと夜の振り返りと同じ DTX-05）。
@MainActor
struct TimelineOpenedTests {
    private func event(_ kind: BlockEvent.Kind, _ time: String, since: String? = nil) -> BlockEvent {
        BlockEvent(occurredAt: jst(time), timeZoneId: "Asia/Tokyo", kind: kind, unlockMinutes: kind == .unlocked ? 15 : nil,
                   sinceAt: since.map(jst))
    }

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

    /// ずっと前から始めていて、今日（10/19）・昨日・1週間前にそれぞれ開けた
    private var history: [BlockEvent] {
        [event(.started, "2026-10-01T09:00"),
         // 1週間前（10/12）：3回、合わせて45分
         event(.unlocked, "2026-10-12T10:00"), event(.reblocked, "2026-10-12T10:15"),
         event(.unlocked, "2026-10-12T13:00"), event(.reblocked, "2026-10-12T13:20"),
         event(.unlocked, "2026-10-12T21:00"), event(.reblocked, "2026-10-12T21:10"),
         // 昨日（10/18）：1回、20分
         event(.unlocked, "2026-10-18T20:00"), event(.reblocked, "2026-10-18T20:20"),
         // 今日（10/19）：1回、10分
         event(.unlocked, "2026-10-19T09:00"), event(.reblocked, "2026-10-19T09:10")]
    }

    @Test func todayYesterdayAndAWeekAgo() throws {
        let t = try TestStore(now: jst("2026-10-19T12:00"))
        try t.seeded()
        let m = model(t, events: history)
        #expect(m.timelineDay(daysAgo: 0)?.opened == OpenedTime(seconds: 10 * 60, count: 1))
        #expect(m.timelineDay(daysAgo: 1)?.opened == OpenedTime(seconds: 20 * 60, count: 1))
        #expect(m.timelineDay(daysAgo: 7)?.opened == OpenedTime(seconds: 45 * 60, count: 3))
        #expect(m.timelineDay(daysAgo: 7)?.opened?.text == "開けた 45分（3回）")
        // 一度も開けていない日（10/15）
        #expect(m.timelineDay(daysAgo: 4)?.opened?.text == "開けていない")
    }

    /// 今日の分はホームと同じ値
    @Test func todayMatchesHome() throws {
        let t = try TestStore(now: jst("2026-10-19T12:00"))
        try t.seeded()
        let m = model(t, events: history)
        m.skipPlan()
        #expect(m.timelineDay(daysAgo: 0)?.opened == m.snapshot.opened)
        #expect(m.timelineDay(daysAgo: 0)?.opened != nil)
    }

    /// ブロックが一度も効いていない日は出さない（始める前の日・許可が丸1日外れていた日）
    @Test func notBlockingDaysShowNothing() throws {
        let t = try TestStore(now: jst("2026-10-19T12:00"))
        try t.seeded()
        let m = model(t, events: [event(.started, "2026-10-15T09:00"),
                                  event(.authorizationLost, "2026-10-17T12:00", since: "2026-10-16T22:00"),
                                  event(.authorizationRestored, "2026-10-18T09:00")])
        // 10/14 はまだ始めていない
        #expect(m.timelineDay(daysAgo: 5)?.opened == nil)
        // 10/15 は 9:00 から始めた
        #expect(m.timelineDay(daysAgo: 4)?.opened?.text == "開けていない")
        // 10/17 は丸1日許可が外れていた
        #expect(m.timelineDay(daysAgo: 2)?.opened == nil)
        // 10/18 は 9:00 に戻った
        #expect(m.timelineDay(daysAgo: 1)?.opened != nil)
    }

    /// 4:00 をまたいで開けていた時間は日ごとに分け、回数は開けた日に数える
    @Test func fourAmSplitsTimeAndCountsTheOpeningDay() throws {
        let t = try TestStore(now: jst("2026-10-19T12:00"))
        try t.seeded()
        let m = model(t, events: [event(.started, "2026-10-01T09:00"),
                                  event(.unlocked, "2026-10-19T03:50"), event(.reblocked, "2026-10-19T04:10")])
        #expect(m.timelineDay(daysAgo: 1)?.opened == OpenedTime(seconds: 10 * 60, count: 1))
        #expect(m.timelineDay(daysAgo: 0)?.opened == OpenedTime(seconds: 10 * 60, count: 0))
    }

    /// 今開けている途中なら、今の時刻まで（時計を進めると増える）
    @Test func stillOpenCountsUntilNow() throws {
        let t = try TestStore(now: jst("2026-10-19T12:00"))
        try t.seeded()
        let m = model(t, events: [event(.started, "2026-10-01T09:00"), event(.unlocked, "2026-10-19T11:50")])
        #expect(m.timelineDay(daysAgo: 0)?.opened == OpenedTime(seconds: 10 * 60, count: 1))
        t.clock.set(jst("2026-10-19T12:05"))
        #expect(m.timelineDay(daysAgo: 0)?.opened == OpenedTime(seconds: 15 * 60, count: 1))
        // 昨日の分は変わらない
        #expect(m.timelineDay(daysAgo: 1)?.opened?.text == "開けていない")
    }

    /// 0:00〜3:59 に開くと、前の日が「今日」。その日の分を今の時刻まで数える
    @Test func beforeFourAmIsStillThePreviousDay() throws {
        let t = try TestStore(now: jst("2026-10-20T03:30"))
        try t.seeded()
        let m = model(t, events: [event(.started, "2026-10-01T09:00"),
                                  event(.unlocked, "2026-10-20T01:00"), event(.reblocked, "2026-10-20T01:15")])
        let today = m.timelineDay(daysAgo: 0)
        #expect(today?.dayKey == "2026-10-19")
        #expect(today?.opened == OpenedTime(seconds: 15 * 60, count: 1))
    }

    /// 過ぎた日に開けたまま日を越えた（戻した記録がない）：前の日は 4:00 まで、回数は前の日。
    /// 今日は一度もブロックが効いていないので出さない（DTX-05 の「出さない日」）。戻したらそこから出る
    @Test func stillOpenFromYesterday() throws {
        let t = try TestStore(now: jst("2026-10-19T12:00"))
        try t.seeded()
        let open = model(t, events: [event(.started, "2026-10-01T09:00"), event(.unlocked, "2026-10-18T23:00")])
        #expect(open.timelineDay(daysAgo: 1)?.opened == OpenedTime(seconds: 5 * 3600, count: 1))
        #expect(open.timelineDay(daysAgo: 0)?.opened == nil)
        let back = model(t, events: [event(.started, "2026-10-01T09:00"), event(.unlocked, "2026-10-18T23:00"),
                                     event(.reblocked, "2026-10-19T04:30")])
        #expect(back.timelineDay(daysAgo: 1)?.opened == OpenedTime(seconds: 5 * 3600, count: 1))
        #expect(back.timelineDay(daysAgo: 0)?.opened == OpenedTime(seconds: 30 * 60, count: 0))
    }

    /// ブロックの記録がまったくない（ブロックを使っていない）：どの日も出さない。ほかの表示は出る
    @Test func noBlockLogShowsNothing() throws {
        let t = try TestStore(now: jst("2026-10-19T12:00"))
        try t.seeded()
        let m = model(t, events: [])
        #expect(m.timelineDay(daysAgo: 0)?.opened == nil)
        #expect(m.timelineDay(daysAgo: 3)?.opened == nil)
        #expect(m.timelineDay(daysAgo: 0)?.dayKey == "2026-10-19")
    }

    /// 今日の分は夜の振り返りとも同じ
    @Test func todayMatchesReview() throws {
        let t = try TestStore(now: jst("2026-10-19T22:30"))
        try t.seeded()
        let m = model(t, events: history)
        m.skipPlan()
        #expect(m.reviewContent()?.opened == m.timelineDay(daysAgo: 0)?.opened)
        #expect(m.reviewContent()?.opened != nil)
    }
}
