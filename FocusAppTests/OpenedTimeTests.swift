import Foundation
import Testing
@testable import FocusApp

/// 開けた時間と回数（DTX-05、digital-detox.md「画面に出す数字」。2026-10-03 オーナー決定）。
struct OpenedTimeTests {
    private let dayStart = jst("2026-10-19T04:00")
    private let dayEnd = jst("2026-10-20T04:00")

    private func event(_ kind: BlockEvent.Kind, _ time: String, since: String? = nil) -> BlockEvent {
        BlockEvent(occurredAt: jst(time), timeZoneId: "Asia/Tokyo", kind: kind, unlockMinutes: kind == .unlocked ? 15 : nil,
                   sinceAt: since.map(jst))
    }

    private func interval(_ start: String, _ end: String) -> DateInterval { DateInterval(start: jst(start), end: jst(end)) }

    private func day(events: [BlockEvent] = [], focus: [DateInterval] = [], games: [DateInterval] = [],
                     sleep: [DateInterval] = [], startedAt: String = "2026-10-01T09:00",
                     until: String = "2026-10-20T04:00") -> DetoxDay {
        DetoxDay.make(.init(dayStart: dayStart, dayEnd: dayEnd, until: jst(until),
                            events: [event(.started, startedAt)] + events,
                            focus: focus, detoxTimers: [], sleep: sleep, gameWindows: games))
    }

    // MARK: 数え方

    /// 長押しで開けていた時間と、ゲーム・SNS の時間を過ぎても開いていた分を足す。決めた30分は入れない
    @Test func unlocksAndGameOverrunAreOpened() {
        let d = day(events: [event(.unlocked, "2026-10-19T10:00"), event(.reblocked, "2026-10-19T10:15"),
                             event(.unlocked, "2026-10-19T15:00"), event(.reblocked, "2026-10-19T15:10"),
                             event(.unblockStarted, "2026-10-19T20:00"), event(.unblockEnded, "2026-10-19T20:35")],
                    games: [interval("2026-10-19T20:00", "2026-10-19T20:30")])
        #expect(d.openedSeconds(until: dayEnd) == 30 * 60)
        #expect(d.openedCount(until: dayEnd) == 2)
    }

    /// 予定を過ぎて開いていた分は時間にだけ入り、回数には入れない
    @Test func overrunAloneHasNoCount() {
        let d = day(events: [event(.unblockStarted, "2026-10-19T20:00"), event(.unblockEnded, "2026-10-19T20:35")],
                    games: [interval("2026-10-19T20:00", "2026-10-19T20:30")])
        #expect(d.openedSeconds(until: dayEnd) == 5 * 60)
        #expect(d.openedCount(until: dayEnd) == 0)
    }

    /// 集中中に開けた分も入れる（重なりは1回）
    @Test func unlockDuringFocusCountsOnce() {
        let d = day(events: [event(.unlocked, "2026-10-19T10:00"), event(.reblocked, "2026-10-19T10:15")],
                    focus: [interval("2026-10-19T09:00", "2026-10-19T11:00")])
        #expect(d.openedSeconds(until: dayEnd) == 15 * 60)
        #expect(d.openedCount(until: dayEnd) == 1)
    }

    /// 許可が外れていた間・始める前・選択が読めない間は、開けた時間に入れない
    @Test func notBlockingIsNotOpened() {
        let lost = day(events: [event(.authorizationLost, "2026-10-19T09:00", since: "2026-10-19T08:00"),
                                event(.authorizationRestored, "2026-10-19T10:00")])
        #expect(lost.openedSeconds(until: dayEnd) == 0)
        let midDay = day(startedAt: "2026-10-19T12:00")
        #expect(midDay.openedSeconds(until: dayEnd) == 0)
        let selection = day(events: [event(.selectionLost, "2026-10-19T08:00"), event(.started, "2026-10-19T09:00")])
        #expect(selection.openedSeconds(until: dayEnd) == 0)
    }

    /// 長押しで開けている間に許可が外れたら、その重なりは許可が外れた方（自分で開けた時間に入れない）
    @Test func unlockOverlappingLostAuthorization() {
        let d = day(events: [event(.unlocked, "2026-10-19T10:00"), event(.reblocked, "2026-10-19T10:30"),
                             // 戻ったのは5分後（2分以内は一瞬の誤記録として数えないため）
                             event(.authorizationLost, "2026-10-19T11:00", since: "2026-10-19T10:20"),
                             event(.authorizationRestored, "2026-10-19T11:05")])
        #expect(d.openedSeconds(until: dayEnd) == 20 * 60)
        #expect(d.openedCount(until: dayEnd) == 1)
    }

    /// 3:59 に開けて 4:10 に戻した：時間は 4:00〜4:10 がこの日、回数は開けた前の日
    @Test func unlockAcrossFourAm() {
        let d = day(events: [event(.unlocked, "2026-10-19T03:59"), event(.reblocked, "2026-10-19T04:10")])
        #expect(d.openedSeconds(until: dayEnd) == 10 * 60)
        #expect(d.openedCount(until: dayEnd) == 0)
        // 前の日：3:59〜4:00 の1分と、1回
        let yesterday = DetoxDay.make(.init(dayStart: jst("2026-10-18T04:00"), dayEnd: dayStart, until: dayStart,
                                            events: [event(.started, "2026-10-01T09:00"), event(.unlocked, "2026-10-19T03:59"),
                                                     event(.reblocked, "2026-10-19T04:10")],
                                            focus: [], detoxTimers: [], sleep: [], gameWindows: []))
        #expect(yesterday.openedSeconds(until: dayStart) == 60)
        #expect(yesterday.openedCount(until: dayStart) == 1)
    }

    /// 3:59 に戻した／4:00 ちょうどに開けた：境目の1分がどちらの日に入るか
    @Test func fourAmEdges() {
        let d = day(events: [event(.unlocked, "2026-10-19T04:00"), event(.reblocked, "2026-10-19T04:05"),
                             event(.unlocked, "2026-10-20T03:59"), event(.reblocked, "2026-10-20T04:30")])
        #expect(d.openedSeconds(until: dayEnd) == 6 * 60)
        #expect(d.openedCount(until: dayEnd) == 2)
    }

    /// 今開けている途中なら今の時刻まで。今より後の回数は数えない
    @Test func stillOpenCountsUntilNow() {
        let d = day(events: [event(.unlocked, "2026-10-19T11:50")], until: "2026-10-19T12:00")
        #expect(d.openedSeconds(until: jst("2026-10-19T12:00")) == 10 * 60)
        #expect(d.openedCount(until: jst("2026-10-19T12:00")) == 1)
        #expect(d.openedCount(until: jst("2026-10-19T11:00")) == 0)
        #expect(d.openedSeconds(until: jst("2026-10-19T11:00")) == 0)
    }

    /// 同じ「開けた」が2回・順番が前後していても1回
    @Test func duplicatesCountOnce() {
        let d = day(events: [event(.reblocked, "2026-10-19T10:15"), event(.unlocked, "2026-10-19T10:00"),
                             event(.unlocked, "2026-10-19T10:05")])
        #expect(d.openedSeconds(until: dayEnd) == 15 * 60)
        #expect(d.openedCount(until: dayEnd) == 1)
    }

    /// 開けたことで、デトックスの時間とポイントは減る（DTX-01・03）
    @Test func detoxStillExcludesOpened() {
        let d = day(events: [event(.unlocked, "2026-10-19T10:00"), event(.reblocked, "2026-10-19T10:15")],
                    until: "2026-10-19T12:00")
        #expect(d.detoxSeconds(until: jst("2026-10-19T12:00")) == 8 * 3600 - 15 * 60)
        // 4:00〜12:00 のうち開けた15分を除く465分×0.05 − 1回目の1pt ＝ 22.25
        #expect(abs(d.points(until: jst("2026-10-19T12:00")) - 22.25) < 0.0001)
    }

    /// ふだん（集中していない）に開けた分はポイントが付かず、1回目の1pt を引く（DTX-03、2026-10-03）
    @Test func openedGivesNoPointsAndCostsOnePoint() {
        let opened = day(events: [event(.unlocked, "2026-10-19T05:00"), event(.reblocked, "2026-10-19T05:10")],
                         until: "2026-10-19T05:10")
        let piece = opened.pieces.first { $0.start == jst("2026-10-19T05:00") }
        #expect(piece?.kind == .opened)
        // 4:00〜5:00 の1時間分だけ（開けた10分は0点）から1pt 引く
        #expect(abs(opened.points(until: jst("2026-10-19T05:10")) - 2.0) < 0.0001)
    }

    /// その日にブロックが一度も効いていなければ「出さない」
    @Test func wasBlocking() {
        #expect(day(until: "2026-10-19T05:00").wasBlocking(until: jst("2026-10-19T05:00")))
        let none = DetoxDay.make(.init(dayStart: dayStart, dayEnd: dayEnd, until: jst("2026-10-19T12:00"), events: [],
                                       focus: [], detoxTimers: [], sleep: [], gameWindows: []))
        #expect(!none.wasBlocking(until: jst("2026-10-19T12:00")))
        let lostAllDay = day(events: [event(.authorizationLost, "2026-10-19T09:00", since: "2026-10-18T22:00")],
                             until: "2026-10-19T12:00")
        #expect(!lostAllDay.wasBlocking(until: jst("2026-10-19T12:00")))
        // 昼から始めた日は、始めるまでは出さない
        let midDay = day(startedAt: "2026-10-19T12:00", until: "2026-10-19T13:00")
        #expect(!midDay.wasBlocking(until: jst("2026-10-19T12:00")))
        #expect(midDay.wasBlocking(until: jst("2026-10-19T13:00")))
    }

    // MARK: 予定を過ぎて開いていた分の端（レビューで足した）

    /// 前の夜のゲーム・SNS の時間（3:20–3:50）を過ぎて 4:20 まで開いていた：この日は 4:00〜4:20
    @Test func overrunAcrossFourAm() {
        let d = day(events: [event(.unblockStarted, "2026-10-19T03:20"), event(.unblockEnded, "2026-10-19T04:20")])
        #expect(d.openedSeconds(until: dayEnd) == 20 * 60)
        #expect(d.openedCount(until: dayEnd) == 0)
    }

    /// 予定を過ぎて開いている間に許可が外れたら、その重なりは入れない
    @Test func overrunOverlappingLostAuthorization() {
        let d = day(events: [event(.unblockStarted, "2026-10-19T20:00"), event(.unblockEnded, "2026-10-19T20:45"),
                             // 戻ったのは5分後（2分以内は一瞬の誤記録として数えないため）
                             event(.authorizationLost, "2026-10-19T21:00", since: "2026-10-19T20:40"),
                             event(.authorizationRestored, "2026-10-19T21:05")],
                    games: [interval("2026-10-19T20:00", "2026-10-19T20:30")])
        #expect(d.openedSeconds(until: dayEnd) == 10 * 60)
    }

    /// 予定を過ぎて開いている間に長押しでも開けた：重なりは1回、回数は1
    @Test func unlockDuringOverrunCountsOnce() {
        let d = day(events: [event(.unblockStarted, "2026-10-19T20:00"), event(.unblockEnded, "2026-10-19T20:40"),
                             event(.unlocked, "2026-10-19T20:35"), event(.reblocked, "2026-10-19T20:50")],
                    games: [interval("2026-10-19T20:00", "2026-10-19T20:30")])
        #expect(d.openedSeconds(until: dayEnd) == 20 * 60)
        #expect(d.openedCount(until: dayEnd) == 1)
    }

    /// 戻した記録がまだない（合図が届かず開いたまま）：今の時刻まで
    @Test func overrunNeverEndedCountsUntilNow() {
        let d = day(events: [event(.unblockStarted, "2026-10-19T20:00")],
                    games: [interval("2026-10-19T20:00", "2026-10-19T20:30")], until: "2026-10-19T21:00")
        #expect(d.openedSeconds(until: jst("2026-10-19T21:00")) == 30 * 60)
    }

    /// 前の日の 3:50 に開けて戻していない：この日は 4:00 から今まで、回数は前の日
    @Test func stillOpenAcrossFourAm() {
        let d = day(events: [event(.unlocked, "2026-10-19T03:50")], until: "2026-10-19T05:00")
        #expect(d.openedSeconds(until: jst("2026-10-19T05:00")) == 3600)
        #expect(d.openedCount(until: jst("2026-10-19T05:00")) == 0)
    }

    /// 寝ている間に開けた分も入れる
    @Test func unlockWhileAsleepIsOpened() {
        let d = day(events: [event(.unlocked, "2026-10-19T05:00"), event(.reblocked, "2026-10-19T05:10")],
                    sleep: [interval("2026-10-19T00:00", "2026-10-19T07:00")])
        #expect(d.openedSeconds(until: dayEnd) == 10 * 60)
        #expect(d.openedCount(until: dayEnd) == 1)
    }

    /// 先週を今日に揃えても、時間と回数は同じ
    @Test func shiftKeepsOpened() {
        let d = day(events: [event(.unlocked, "2026-10-19T10:00"), event(.reblocked, "2026-10-19T10:15")])
            .shifted(by: 7 * 86400)
        #expect(d.openedSeconds(until: jst("2026-10-26T10:10")) == 10 * 60)
        #expect(d.openedCount(until: jst("2026-10-26T10:10")) == 1)
        #expect(d.openedCount(until: jst("2026-10-26T09:59")) == 0)
    }

    // MARK: 言い方

    @Test func wording() {
        #expect(OpenedTime(seconds: 25 * 60, count: 2).text == "開けた 25分（2回）")
        #expect(OpenedTime(seconds: 5 * 60, count: 0).text == "開けた 5分")
        #expect(OpenedTime(seconds: 0, count: 0).text == "開けていない")
        #expect(OpenedTime(seconds: 59, count: 1).text == "開けた 1分未満（1回）")
        #expect(OpenedTime(seconds: 0, count: 1).text == "開けた 1分未満（1回）")
        #expect(OpenedTime(seconds: 30, count: 0).text == "開けた 1分未満")
        #expect(OpenedTime(seconds: 3600 + 5 * 60, count: 3).text == "開けた 1時間05分（3回）")
        #expect(OpenedTime(seconds: 60, count: 0).text == "開けた 1分")
        #expect(OpenedTime(seconds: 3599, count: 0).text == "開けた 59分")
        #expect(OpenedTime(seconds: 3600, count: 12).text == "開けた 1時間（12回）")
        #expect(OpenedTime(seconds: 25 * 60, count: 2).durationText == "25分")
        #expect(OpenedTime(seconds: 0, count: 0).isNone)
        #expect(!OpenedTime(seconds: 0, count: 1).isNone)
    }
}

/// ホーム・振り返り・勝ち負けの開けた時間（DTX-05、GHO-04）。
struct OpenedTimeScreenTests {
    private let calendar = tokyoCalendar
    private let now = jst("2026-10-19T22:30")

    private func detox(_ dayStart: String, until: String, startedAt: String = "2026-10-01T09:00",
                       unlocks: [(String, String)] = []) -> DetoxDay {
        var events = [BlockEvent(occurredAt: jst(startedAt), timeZoneId: "Asia/Tokyo", kind: .started)]
        for (open, close) in unlocks {
            events += [BlockEvent(occurredAt: jst(open), timeZoneId: "Asia/Tokyo", kind: .unlocked, unlockMinutes: 15),
                       BlockEvent(occurredAt: jst(close), timeZoneId: "Asia/Tokyo", kind: .reblocked)]
        }
        return DetoxDay.make(.init(dayStart: jst(dayStart), dayEnd: jst(dayStart).addingTimeInterval(86400), until: jst(until),
                                   events: events, focus: [], detoxTimers: [], sleep: [], gameWindows: []))
    }

    private func home(today: DetoxDay?, lastWeek: DetoxDay?) -> HomeSnapshot {
        HomeSnapshot.make(now: now, calendar: calendar, todaySessions: [session("2026-10-19T09:00", "2026-10-19T10:00")],
                          plan: nil, lastWeekSessions: [session("2026-10-12T09:00", "2026-10-12T10:00")],
                          detox: today, lastWeekDetox: lastWeek)
    }

    private func verdict(_ home: HomeSnapshot) -> ReviewContent.Verdict? {
        ReviewContent.make(home: home, sessions: [], snapshot: nil).verdicts.first { $0.item == .opened }
    }

    /// ホームと振り返りは同じ値・同じ言い方
    @Test func homeAndReviewShowTheSameOpened() {
        let h = home(today: detox("2026-10-19T04:00", until: "2026-10-19T22:30",
                                  unlocks: [("2026-10-19T10:00", "2026-10-19T10:15"), ("2026-10-19T20:00", "2026-10-19T20:10")]),
                     lastWeek: nil)
        #expect(h.opened == OpenedTime(seconds: 25 * 60, count: 2))
        let r = ReviewContent.make(home: h, sessions: [], snapshot: nil)
        #expect(r.opened == h.opened)
        #expect(r.opened?.text == "開けた 25分（2回）")
    }

    /// ブロックが一度も効いていない日は出さない
    @Test func notBlockingHidesOpened() {
        let h = home(today: detox("2026-10-19T04:00", until: "2026-10-19T22:30", startedAt: "2026-10-20T09:00"), lastWeek: nil)
        #expect(h.opened == nil)
        #expect(ReviewContent.make(home: h, sessions: [], snapshot: nil).opened == nil)
        #expect(home(today: nil, lastWeek: nil).opened == nil)
    }

    /// 勝ち負けの行は「集中・開けた時間・ポイント」。開けた時間は少ないほうが勝ち
    @Test func fewerOpenedWins() {
        let lastWeek = detox("2026-10-12T04:00", until: "2026-10-13T04:00", unlocks: [("2026-10-12T13:00", "2026-10-12T14:00")])
        let today = detox("2026-10-19T04:00", until: "2026-10-19T22:30", unlocks: [("2026-10-19T13:00", "2026-10-19T13:10")])
        let r = ReviewContent.make(home: home(today: today, lastWeek: lastWeek), sessions: [], snapshot: nil)
        #expect(r.verdicts.map(\.item) == [.focus, .opened, .points])
        let v = r.verdicts.first { $0.item == .opened }
        #expect(v?.mine == 600)
        #expect(v?.theirs == 3600)
        #expect(v?.result == .win)
        // 逆なら負け
        let worse = detox("2026-10-19T04:00", until: "2026-10-19T22:30", unlocks: [("2026-10-19T13:00", "2026-10-19T15:00")])
        #expect(verdict(home(today: worse, lastWeek: lastWeek))?.result == .lose)
    }

    /// 先週は振り返りを開いた時刻までで比べる（先週の 22:30 より後に開けた分は入れない）
    @Test func lastWeekCountsUntilTheSameTime() {
        let lastWeek = detox("2026-10-12T04:00", until: "2026-10-13T04:00", unlocks: [("2026-10-12T23:00", "2026-10-12T23:30")])
        let today = detox("2026-10-19T04:00", until: "2026-10-19T22:30")
        let v = verdict(home(today: today, lastWeek: lastWeek))
        #expect(v?.theirs == 0)
        #expect(v?.result == .draw)
    }

    /// 分（1分未満は切り捨て）でそろえ、同じなら引き分け
    @Test func comparesInMinutes() {
        #expect(ReviewContent.Verdict(item: .opened, mine: 119, theirs: 61).result == .draw)
        #expect(ReviewContent.Verdict(item: .opened, mine: 60, theirs: 120).result == .win)
        #expect(ReviewContent.Verdict(item: .opened, mine: 180, theirs: 120).result == .lose)
        #expect(ReviewContent.Verdict(item: .opened, mine: 0, theirs: 0).result == .draw)
    }

    /// 先週の記録が丸1日分ない日は「先週の記録なし」。今日ブロックしていない日は行を出さない
    @Test func noRecordCases() {
        let today = detox("2026-10-19T04:00", until: "2026-10-19T22:30")
        #expect(verdict(home(today: today, lastWeek: nil))?.result == .noRecord)
        let lastWeek = detox("2026-10-12T04:00", until: "2026-10-13T04:00")
        let notBlocking = detox("2026-10-19T04:00", until: "2026-10-19T22:30", startedAt: "2026-10-20T09:00")
        let r = ReviewContent.make(home: home(today: notBlocking, lastWeek: lastWeek), sessions: [], snapshot: nil)
        #expect(r.verdicts.map(\.item) == [.focus, .points])
    }

    /// 先週のその日にブロックが一度も効いていなかった（4:00 には始めていたが、前の夜から許可が外れていた）→ 先週の記録なし
    @Test func lastWeekNotBlockingIsNoRecord() {
        var events = [BlockEvent(occurredAt: jst("2026-10-01T09:00"), timeZoneId: "Asia/Tokyo", kind: .started)]
        events.append(BlockEvent(occurredAt: jst("2026-10-13T09:00"), timeZoneId: "Asia/Tokyo", kind: .authorizationLost,
                                 sinceAt: jst("2026-10-11T22:00")))
        let lastWeek = DetoxDay.make(.init(dayStart: jst("2026-10-12T04:00"), dayEnd: jst("2026-10-13T04:00"),
                                           until: jst("2026-10-13T04:00"), events: events, focus: [], detoxTimers: [],
                                           sleep: [], gameWindows: []))
        #expect(lastWeek.isComplete)
        let today = detox("2026-10-19T04:00", until: "2026-10-19T22:30")
        #expect(verdict(home(today: today, lastWeek: lastWeek))?.result == .noRecord)
    }

    /// 先週は途中から始めた（丸1日分ない）→ 先週の記録なし
    @Test func lastWeekStartedMidDayIsNoRecord() {
        let lastWeek = detox("2026-10-12T04:00", until: "2026-10-13T04:00", startedAt: "2026-10-12T09:00")
        let today = detox("2026-10-19T04:00", until: "2026-10-19T22:30")
        #expect(verdict(home(today: today, lastWeek: lastWeek))?.result == .noRecord)
    }

    @Test func labelIsOpenedTime() {
        #expect(ReviewContent.Verdict.Item.opened.label == "開けた時間")
    }
}

/// 見本データの開けた記録（DTX-05 の画面確認用）
@MainActor
struct OpenedDemoTests {
    @Test func demoDayOpenedTwice() {
        let now = jst("2026-10-19T14:30")
        let events = DemoData.blockEvents(.day, now: now, calendar: tokyoCalendar)
        let d = DetoxDay.make(.init(dayStart: jst("2026-10-19T04:00"), dayEnd: jst("2026-10-20T04:00"), until: now, events: events,
                                    focus: [], detoxTimers: [], sleep: [], gameWindows: []))
        #expect(OpenedTime(seconds: d.openedSeconds(until: now), count: d.openedCount(until: now)).text == "開けた 25分（2回）")
        // 朝はまだ開けていない。今より後の記録は入れない
        let morning = DemoData.blockEvents(.day, now: jst("2026-10-19T08:00"), calendar: tokyoCalendar)
        #expect(morning.allSatisfy { $0.occurredAt <= jst("2026-10-19T08:00") })
    }

    /// 先週のデータなしの見本では、過去の日に開けた記録を入れない。ほかの場面では過去の日にもある
    @Test func demoPastDays() {
        let now = jst("2026-10-19T14:30")
        let dayStart = jst("2026-10-19T04:00")
        let firstweek = DemoData.blockEvents(.firstweek, now: now, calendar: tokyoCalendar)
        #expect(!firstweek.contains { $0.kind == .unlocked && $0.occurredAt < dayStart })
        let day = DemoData.blockEvents(.day, now: now, calendar: tokyoCalendar)
        #expect(day.contains { $0.kind == .unlocked && $0.occurredAt < dayStart })
    }
}
