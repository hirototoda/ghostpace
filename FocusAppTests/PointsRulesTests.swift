import Foundation
import Testing
@testable import FocusApp

/// ポイントの逓減と逓増（2026-10-03、ADR-0019。ghost-race.md GHO-14・digital-detox.md DTX-03・GHO-10）。
struct PointsRulesTests {
    private let calendar = tokyoCalendar
    private let c = DefaultCategories.all
    private let dayStart = jst("2026-10-19T04:00")
    private let dayEnd = jst("2026-10-20T04:00")

    private func focus(_ sessions: [FocusSession], until time: String) -> Double {
        FocusPoints.points(sessions.flatMap { $0.activeSegments(now: jst(time)) }, until: jst(time))
    }

    private func interval(_ start: String, _ end: String) -> DateInterval { DateInterval(start: jst(start), end: jst(end)) }

    private func event(_ kind: BlockEvent.Kind, _ time: String, minutes: Int? = nil) -> BlockEvent {
        BlockEvent(occurredAt: jst(time), timeZoneId: "Asia/Tokyo", kind: kind, unlockMinutes: minutes)
    }

    /// 10分開けて戻した
    private func opened(_ time: String, minutes: Int = 10) -> [BlockEvent] {
        let start = jst(time)
        return [BlockEvent(occurredAt: start, timeZoneId: "Asia/Tokyo", kind: .unlocked, unlockMinutes: minutes),
                BlockEvent(occurredAt: start.addingTimeInterval(Double(minutes) * 60), timeZoneId: "Asia/Tokyo", kind: .reblocked)]
    }

    /// ずっと前からブロックを始めている日
    private func detox(events: [BlockEvent] = [], focus: [DateInterval] = [], timers: [DetoxTimer] = [],
                       sleep: [DateInterval] = [], games: [DateInterval] = [], until: String? = nil) -> DetoxDay {
        DetoxDay.make(.init(dayStart: dayStart, dayEnd: dayEnd, until: until.map(jst) ?? dayEnd,
                            events: [event(.started, "2026-10-01T09:00")] + events,
                            focus: focus, detoxTimers: timers, sleep: sleep, gameWindows: games))
    }

    // MARK: 集中：1回の長さ（90分で×0.75、3時間で×0.5）

    @Test func ninetyMinutesIsFullValue() {
        #expect(focus([session("2026-10-19T09:00", "2026-10-19T10:30")], until: "2026-10-19T12:00").isApprox(9.0))
    }

    @Test func twoHoursInOneGoSlowsAfterNinety() {
        // 90分×0.1 ＋ 30分×0.1×0.75 ＝ 11.25（docs の例）
        #expect(focus([session("2026-10-19T09:00", "2026-10-19T11:00")], until: "2026-10-19T12:00").isApprox(11.25))
    }

    @Test func fourHoursInOneGoHalvesAfterThree() {
        // 9 ＋ 90分×0.075 ＋ 60分×0.05 ＝ 18.75
        #expect(focus([session("2026-10-19T09:00", "2026-10-19T13:00")], until: "2026-10-19T14:00").isApprox(18.75))
    }

    @Test func fiveMinuteBreakStartsOver() {
        let two = [session("2026-10-19T09:00", "2026-10-19T10:30"), session("2026-10-19T10:35", "2026-10-19T12:05")]
        #expect(focus(two, until: "2026-10-19T13:00").isApprox(18.0))
    }

    @Test func shorterBreakContinuesTheSameRun() {
        // 4分で始め直した → 続き。止めていた4分は数えない：9 ＋ 30分×0.075 ＝ 11.25
        let two = [session("2026-10-19T09:00", "2026-10-19T10:30"), session("2026-10-19T10:34", "2026-10-19T11:04")]
        #expect(focus(two, until: "2026-10-19T13:00").isApprox(11.25))
    }

    @Test func pauseOfFiveMinutesStartsOver() {
        let paused = session("2026-10-19T09:00", "2026-10-19T12:05", pauses: [("2026-10-19T10:30", "2026-10-19T10:35")])
        #expect(focus([paused], until: "2026-10-19T13:00").isApprox(18.0))
        let short = session("2026-10-19T09:00", "2026-10-19T12:04", pauses: [("2026-10-19T10:30", "2026-10-19T10:34")])
        // 続き：9 ＋ 90分×0.075 ＝ 15.75
        #expect(focus([short], until: "2026-10-19T13:00").isApprox(15.75))
    }

    @Test func runningSessionSlowsAfterNinety() {
        let running = session("2026-10-19T09:00", nil)
        #expect(focus([running], until: "2026-10-19T10:30").isApprox(9.0))
        #expect(focus([running], until: "2026-10-19T11:00").isApprox(11.25))
    }

    @Test func threeHoursExactlyThenOneMinute() {
        // ちょうど3時間：9 ＋ 6.75 ＝ 15.75。もう1分は×0.5 → ＋0.05
        #expect(focus([session("2026-10-19T09:00", "2026-10-19T12:00")], until: "2026-10-19T13:00").isApprox(15.75))
        #expect(focus([session("2026-10-19T09:00", "2026-10-19T12:01")], until: "2026-10-19T13:00").isApprox(15.8))
    }

    // MARK: 集中：1日の合計（8時間で×0.75、10時間で×0.5）

    /// 6:00 から 90分ずつ、10分休みで n 回
    private func ninetyMinuteBlocks(_ count: Int) -> [FocusSession] {
        (0..<count).map { i in
            let start = jst("2026-10-19T06:00").addingTimeInterval(Double(i) * 100 * 60)
            return FocusSession(id: UUID(), dayKey: "2026-10-19", category: c[0], project: nil, planBlockId: nil,
                                startAt: start, endAt: start.addingTimeInterval(90 * 60), plannedEndAt: nil,
                                plannedDurationSec: nil, pauses: [], originalEndAt: nil)
        }
    }

    @Test func dailyTotalSlowsAfterEightAndTenHours() {
        let until = "2026-10-20T03:00"
        // 8時間（90分×5＋30分…）ちょうどまでは1倍：90分×5＝7.5時間 → 45pt
        #expect(focus(ninetyMinuteBlocks(5), until: until).isApprox(45.0))
        // 90分×8＝12時間：8時間まで48 ＋ 8〜10時間 2時間×0.075×60＝9 ＋ 10〜12時間 2時間×0.05×60＝6 ＝ 63
        #expect(focus(ninetyMinuteBlocks(8), until: until).isApprox(63.0))
    }

    /// 90分ずつ n 回に、`extra` の区間を足す
    private func blocks(_ count: Int, plus extra: [(String, String)]) -> [FocusSession] {
        ninetyMinuteBlocks(count) + extra.map { session($0.0, $0.1) }
    }

    @Test func dailyTotalExactlyEightThenSlower() {
        // 90分×5（〜14:10）＋ 14:20–14:50 ＝ ちょうど8時間 → 48
        let eight = blocks(5, plus: [("2026-10-19T14:20", "2026-10-19T14:50")])
        #expect(focus(eight, until: "2026-10-19T20:00").isApprox(48.0))
        // さらに 14:55–15:15（5分休んだので1回目から）：1日の8時間を超えた分は×0.75 → 20分×0.075 ＝ 1.5
        let more = eight + [session("2026-10-19T14:55", "2026-10-19T15:15")]
        #expect(focus(more, until: "2026-10-19T20:00").isApprox(49.5))
    }

    @Test func dailyTotalExactlyTenThenHalf() {
        // 90分×6（9時間、〜15:50）＋ 16:00–17:00 ＝ ちょうど10時間：48 ＋ 2時間×4.5 ＝ 57。もう1分は×0.5 → ＋0.05
        let ten = blocks(6, plus: [("2026-10-19T16:00", "2026-10-19T17:00")])
        #expect(focus(ten, until: "2026-10-19T20:00").isApprox(57.0))
        let more = blocks(6, plus: [("2026-10-19T16:00", "2026-10-19T17:01")])
        #expect(focus(more, until: "2026-10-19T20:00").isApprox(57.05))
    }

    @Test func lowerFactorWinsButNeverBelowHalf() {
        // 12時間続けて：9 ＋ 6.75 ＋ 3〜12時間目の9時間は0.5（1回の0.5と1日の1・0.75・0.5の低いほう。掛け合わせて0.25 にはしない）27 ＝ 42.75
        #expect(focus([session("2026-10-19T04:00", "2026-10-19T16:00")], until: "2026-10-19T17:00").isApprox(42.75))
    }

    @Test func lastWeekGhostUsesSameRules() throws {
        let ghost = try #require(GhostSummary(lastWeek: [session("2026-10-12T09:00", "2026-10-12T11:00")],
                                              lastWeekStart: jst("2026-10-12T04:00"), todayStart: dayStart))
        #expect(FocusPoints.points(ghost.segments, until: jst("2026-10-19T12:00")).isApprox(11.25))
    }

    // MARK: 集中中に開けていた時間は0点（2026-10-03 オーナー決定）

    @Test func openedMinutesDuringFocusEarnNothing() {
        // 9:00〜11:00 のうち 10:00〜10:15 に開けた：60分 6 ＋ 15分 1.5 ＋ 30分×0.075 2.25 ＝ 9.75（開けなければ 11.25）
        let segments = session("2026-10-19T09:00", "2026-10-19T11:00").activeSegments(now: jst("2026-10-19T12:00"))
        #expect(FocusPoints.points(segments, until: jst("2026-10-19T12:00"),
                                   opened: [interval("2026-10-19T10:00", "2026-10-19T10:15")]).isApprox(9.75))
        // 開けている途中まで：10:00〜10:10 は0点
        #expect(FocusPoints.points(segments, until: jst("2026-10-19T10:10"),
                                   opened: [interval("2026-10-19T10:00", "2026-10-19T10:15")]).isApprox(6.0))
    }

    @Test func openingDuringFocusDoesNotRestartTheRun() {
        // 9:30〜9:45 に開けても数え直しにならない：30分 3 ＋ 45分 4.5 ＋ 90分を超えた30分 2.25 ＝ 9.75
        let segments = session("2026-10-19T09:00", "2026-10-19T11:00").activeSegments(now: jst("2026-10-19T12:00"))
        #expect(FocusPoints.points(segments, until: jst("2026-10-19T12:00"),
                                   opened: [interval("2026-10-19T09:30", "2026-10-19T09:45")]).isApprox(9.75))
    }

    // MARK: デトックス：ブロック中は一律0.5（続けたボーナスはなし）

    @Test func blockedIsFlatHalf() {
        // 起きてから3時間、開けずにブロック中 → 9.0pt（docs の例）
        #expect(detox(until: "2026-10-19T07:00").points(until: jst("2026-10-19T07:00")).isApprox(9.0))
        #expect(detox(until: "2026-10-19T09:00").points(until: jst("2026-10-19T09:00")).isApprox(15.0))
    }

    // MARK: 開けた n 回目に n pt 引く

    @Test func eachOpenCostsMoreThanTheLast() {
        let d = detox(events: opened("2026-10-19T05:00") + opened("2026-10-19T06:00") + opened("2026-10-19T06:30"),
                      until: "2026-10-19T07:00")
        // 1回目の直後：60分×0.05 − 1 ＝ 2.0
        #expect(d.points(until: jst("2026-10-19T05:05")).isApprox(2.0))
        // 3時間のうち開けていた30分は0、引くのは 1＋2＋3：150分×0.05 − 6 ＝ 1.5
        #expect(d.points(until: jst("2026-10-19T07:00")).isApprox(1.5))
    }

    @Test func docsExampleOneOpen() {
        // 3時間のうち1回開けて10分戻らなかった → 170分×0.05 − 1 ＝ 7.5（docs の例）
        let d = detox(events: opened("2026-10-19T05:00"), until: "2026-10-19T07:00")
        #expect(d.points(until: jst("2026-10-19T07:00")).isApprox(7.5))
    }

    @Test func openingRightAfterFourCanGoBelowZero() {
        let d = detox(events: opened("2026-10-19T04:01"), until: "2026-10-19T04:05")
        #expect(d.points(until: jst("2026-10-19T04:05")).isApprox(0.05 - 1))
    }

    @Test func gameOverrunIsNotCountedAsAnOpen() {
        // 予定 20:00〜20:30 を過ぎて 20:40 まで開いていた → その10分は0pt、回数に入れないので引かない
        let d = detox(events: [event(.unblockStarted, "2026-10-19T20:00"), event(.unblockEnded, "2026-10-19T20:40")],
                      games: [interval("2026-10-19T20:00", "2026-10-19T20:30")], until: "2026-10-19T21:00")
        #expect(d.points(until: jst("2026-10-19T21:00")).isApprox(1010 * 0.05))
    }

    // MARK: 家事・運動・休みのタイマー（1日の上限まで0.75）

    @Test func groupsComeFromTheCategory() {
        // 2026-10-03 からグループはカテゴリに保存した値（デフォルトは家事・休み・運動）
        #expect(DetoxGroup.of(c[3]) == .housework)   // 家事
        #expect(DetoxGroup.of(c[4]) == .rest)        // 休み
        #expect(DetoxGroup.of(c[5]) == .exercise)    // 運動
        #expect(DetoxGroup.of(c[0]) == nil)          // 勉強（集中）
        #expect(DetoxGroup.of(CategoryOption(name: "散歩", countsAsFocus: false)) == nil)
        #expect(DetoxGroup.of(CategoryOption(name: "散歩", countsAsFocus: false, detoxGroup: .exercise)) == .exercise)
        // 集中のカテゴリにはグループを持たせない
        #expect(DetoxGroup.of(CategoryOption(name: "ピアノ", countsAsFocus: true, detoxGroup: .rest)) == nil)
        #expect(DetoxGroup.of(.gameSNS) == nil)
    }

    @Test func houseworkSharesOneHour() {
        // 掃除40分＋料理30分：60分×0.075＋10分×0.05 ＝ 5.0。ほかの 4:00〜10:30 の320分はブロック中 16.0
        let d = detox(timers: [DetoxTimer(interval: interval("2026-10-19T09:00", "2026-10-19T09:40"), group: .housework),
                               DetoxTimer(interval: interval("2026-10-19T10:00", "2026-10-19T10:30"), group: .housework)],
                      until: "2026-10-19T10:30")
        #expect(d.points(until: jst("2026-10-19T10:30")).isApprox(21.0))
    }

    @Test func exerciseUpToThreeHours() {
        // 運動4時間：180分×0.075＋60分×0.05 ＝ 16.5。4:00〜9:00 のブロック中 15.0
        let d = detox(timers: [DetoxTimer(interval: interval("2026-10-19T09:00", "2026-10-19T13:00"), group: .exercise)],
                      until: "2026-10-19T13:00")
        #expect(d.points(until: jst("2026-10-19T13:00")).isApprox(31.5))
    }

    @Test func groupsHaveSeparateCaps() {
        // 家事1時間と休み1時間はどちらも0.75：4.5＋4.5、ほかの 4:00〜9:00 は 15.0
        let d = detox(timers: [DetoxTimer(interval: interval("2026-10-19T09:00", "2026-10-19T10:00"), group: .housework),
                               DetoxTimer(interval: interval("2026-10-19T10:00", "2026-10-19T11:00"), group: .rest)],
                      until: "2026-10-19T11:00")
        #expect(d.points(until: jst("2026-10-19T11:00")).isApprox(24.0))
    }

    @Test func timerWithoutGroupIsLikeBlocked() {
        let d = detox(timers: [DetoxTimer(interval: interval("2026-10-19T04:00", "2026-10-19T05:00"), group: nil)],
                      until: "2026-10-19T05:00")
        #expect(d.points(until: jst("2026-10-19T05:00")).isApprox(3.0))
    }

    @Test func sessionsCarryTheirGroup() {
        let segments = session("2026-10-19T09:00", "2026-10-19T10:00", category: c[5]).activeSegments(now: jst("2026-10-19T12:00"))
        #expect(segments.map(\.detoxGroup) == [.exercise])
    }

    // MARK: 睡眠（寝てから7時間まで0.75、8時間まで0.5、超えたら0）

    @Test func sleepTiersCountFromBedtime() {
        // 0:00〜9:00 に寝た：4:00〜7:00 は4〜7時間目 13.5、7:00〜8:00 は 3.0、8:00〜9:00 は0
        let d = detox(sleep: [interval("2026-10-19T00:00", "2026-10-19T09:00")], until: "2026-10-19T09:00")
        #expect(d.points(until: jst("2026-10-19T09:00")).isApprox(16.5))
    }

    @Test func nightSleepBeforeFourIsTheFirstHours() {
        // 23:00 に寝た：23:00〜翌4:00 は寝てから0〜5時間目 → 5時間×4.5 ＝ 22.5
        let d = detox(sleep: [interval("2026-10-19T23:00", "2026-10-20T07:00")])
        #expect((d.points(until: dayEnd) - d.points(until: jst("2026-10-19T23:00"))).isApprox(22.5))
    }

    @Test func bedtimeClockRunsThroughFocusInsideSleep() {
        // 0:00〜9:00 の睡眠のうち 5:00〜6:00 は集中：寝ている 4〜5・6〜7時間目 4.5＋4.5、7〜8時間目 3.0、8〜9時間目 0
        let d = detox(focus: [interval("2026-10-19T05:00", "2026-10-19T06:00")],
                      sleep: [interval("2026-10-19T00:00", "2026-10-19T09:00")], until: "2026-10-19T09:00")
        #expect(d.points(until: jst("2026-10-19T09:00")).isApprox(12.0))
    }

    @Test func sleepTierBoundaries() {
        let h: TimeInterval = 3600
        #expect(DetoxDay.sleepPoints(from: 0, to: 7 * h).isApprox(31.5))
        #expect(DetoxDay.sleepPoints(from: 0, to: 8 * h).isApprox(34.5))
        #expect(DetoxDay.sleepPoints(from: 0, to: 9 * h).isApprox(34.5))
        #expect(DetoxDay.sleepPoints(from: 7 * h, to: 8 * h).isApprox(3.0))
        #expect(DetoxDay.sleepPoints(from: 8 * h, to: 9 * h).isApprox(0))
        #expect(DetoxDay.sleepPoints(from: 6.5 * h, to: 7.5 * h).isApprox(3.75))
    }

    @Test func sleepStartedTheNightBeforeCountsFromBedtime() {
        // 前の日の 23:00 に寝た：4:00〜7:00 は寝てから5〜8時間目 → 9.0 ＋ 3.0
        let d = detox(sleep: [interval("2026-10-18T23:00", "2026-10-19T07:00")], until: "2026-10-19T07:00")
        #expect(d.points(until: jst("2026-10-19T07:00")).isApprox(12.0))
    }

    @Test func timerAcrossFourOnlyUsesTodaysPart() {
        // 3:00〜5:00 の家事：今日の分は 4:00〜5:00 の1時間 → 4.5
        let d = detox(timers: [DetoxTimer(interval: interval("2026-10-19T03:00", "2026-10-19T05:00"), group: .housework)],
                      until: "2026-10-19T05:00")
        #expect(d.points(until: jst("2026-10-19T05:00")).isApprox(4.5))
    }

    /// 先週の自分を今日に揃えても、寝てからの時間・開けた回数・タイマーのグループはそのまま
    @Test func shiftedKeepsSleepTiersOpensAndGroups() {
        let lastWeekStart = jst("2026-10-12T04:00")
        let lastWeek = DetoxDay.make(.init(
            dayStart: lastWeekStart, dayEnd: jst("2026-10-13T04:00"), until: jst("2026-10-13T04:00"),
            events: [event(.started, "2026-10-01T09:00")] + opened("2026-10-12T05:00"),
            focus: [],
            detoxTimers: [DetoxTimer(interval: interval("2026-10-12T10:00", "2026-10-12T12:00"), group: .housework)],
            sleep: [interval("2026-10-12T00:00", "2026-10-12T09:00")], gameWindows: []))
        let shifted = lastWeek.shifted(by: dayStart.timeIntervalSince(lastWeekStart))
        #expect(shifted.unlockStarts == [jst("2026-10-19T05:00")])
        // 4:00〜9:00：寝てから4〜7時間目のうち開けた10分を除く170分 12.75 ＋ 7〜8時間目 3.0 − 1 ＝ 14.75
        #expect(shifted.points(until: jst("2026-10-19T09:00")).isApprox(14.75))
        #expect(shifted.points(until: jst("2026-10-19T09:00")).isApprox(lastWeek.points(until: jst("2026-10-12T09:00"))))
        // 家事2時間は1時間だけ0.75：9:00〜12:00 で ブロック中1時間 3.0 ＋ 4.5 ＋ 3.0
        let morning = shifted.points(until: jst("2026-10-19T09:00"))
        #expect((shifted.points(until: jst("2026-10-19T12:00")) - morning).isApprox(10.5))
    }

    @Test func goalOpenTimesFallBack() {
        func times(_ sleep: [DateInterval]) -> [Date] { GoalGhost.openTimes(sleep: sleep, dayStart: dayStart, dayEnd: dayEnd) }
        // 睡眠なし → 4:00〜翌4:00 の3等分
        #expect(times([]) == [jst("2026-10-19T12:00"), jst("2026-10-19T20:00")])
        // 朝の睡眠だけ → 7:00〜翌4:00 の3等分
        #expect(times([interval("2026-10-19T00:00", "2026-10-19T07:00")]) == [jst("2026-10-19T14:00"), jst("2026-10-19T21:00")])
        // 起きた時刻が寝る時刻より後 → 1日の3等分
        #expect(times([interval("2026-10-19T00:00", "2026-10-19T23:00"), interval("2026-10-19T22:00", "2026-10-20T06:00")])
                == [jst("2026-10-19T12:00"), jst("2026-10-19T20:00")])
        // 4:00 より前に起きた → 4:00 から。寝る時刻が翌4:00 より後 → 翌4:00 まで
        #expect(times([interval("2026-10-18T22:00", "2026-10-19T03:00"), interval("2026-10-20T05:00", "2026-10-20T09:00")])
                == [jst("2026-10-19T12:00"), jst("2026-10-19T20:00")])
        #expect(times([interval("2026-10-18T22:00", "2026-10-19T03:00"), interval("2026-10-20T00:00", "2026-10-20T07:00")])
                == [jst("2026-10-19T10:40"), jst("2026-10-19T17:20")])
    }

    // MARK: 目標のゴースト（計画どおりで2回だけ開けた日）

    private let sleep = [DateInterval(start: jst("2026-10-19T00:00"), end: jst("2026-10-19T07:00")),
                         DateInterval(start: jst("2026-10-20T00:00"), end: jst("2026-10-20T07:00"))]

    /// docs の1日の例：集中 9:00–11:00・14:00–16:00、運動 18:00–19:00
    private var examplePlan: PlanDraft {
        PlanDraft(blocks: [PlanBlockDraft(start: jst("2026-10-19T09:00"), minutes: 120, category: c[0]),
                           PlanBlockDraft(start: jst("2026-10-19T14:00"), minutes: 120, category: c[0]),
                           PlanBlockDraft(start: jst("2026-10-19T18:00"), minutes: 60, category: c[5])])
    }

    /// 計画どおりに過ごした自分（開けた記録を足せる）
    /// タイマーは計画ブロックから始めたので、計画どおりの点（GHO-16）も3つ付く
    private func followedPlan(now: String, events: [BlockEvent]) -> HomeSnapshot {
        let plan = examplePlan
        var today = [session("2026-10-19T09:00", "2026-10-19T11:00"), session("2026-10-19T14:00", "2026-10-19T16:00"),
                     session("2026-10-19T18:00", "2026-10-19T19:00", category: c[5])]
        for index in today.indices { today[index].planBlockId = plan.blocks[index].id }
        let segments = today.flatMap { $0.activeSegments(now: jst(now)) }
        let mine = DetoxDay.make(.init(
            dayStart: dayStart, dayEnd: dayEnd, until: jst(now), events: [event(.started, "2026-10-01T09:00")] + events,
            focus: segments.filter(\.countsAsFocus).map { DateInterval(start: $0.start, end: $0.end) },
            detoxTimers: segments.filter { !$0.countsAsFocus }.map { DetoxTimer(interval: DateInterval(start: $0.start, end: $0.end),
                                                                                  group: $0.detoxGroup) },
            sleep: sleep, gameWindows: []))
        return HomeSnapshot.make(now: jst(now), calendar: calendar, todaySessions: today, plan: plan,
                                 lastWeekSessions: [], detox: mine, sleep: sleep,
                                 onPlan: OnPlanContext(morningBlockIds: Set(plan.blocks.map(\.id))))
    }

    @Test func exampleDayIsNinetySevenAndHalf() {
        // 94.5 ＋ 計画どおりの点 3（GHO-16、2026-10-06）
        let s = followedPlan(now: "2026-10-20T03:59:59", events: [])
        #expect(s.myPoints(until: dayEnd).isApprox(97.5, tolerance: 0.01))
    }

    @Test func openingDuringFocusCostsMoreThanOutside() {
        // 1日の例で、集中中の 10:00 に15分開けた → 97.5 − 1.5（集中の15分）− 1 ＝ 95.0。円の集中時間は減らない
        let s = followedPlan(now: "2026-10-20T03:59:59", events: opened("2026-10-19T10:00", minutes: 15))
        #expect(s.myPoints(until: dayEnd).isApprox(95.0, tolerance: 0.01))
        #expect(s.focusSeconds == 4 * 3600)
        // ブロック中の 12:00 に15分開けた → 97.5 − 0.75 − 1 ＝ 95.75（集中中のほうが損）
        let outside = followedPlan(now: "2026-10-20T03:59:59", events: opened("2026-10-19T12:00", minutes: 15))
        #expect(outside.myPoints(until: dayEnd).isApprox(95.75, tolerance: 0.01))
    }

    @Test func lastWeekOpenedDuringFocusEarnsNothingToo() throws {
        let lastWeekStart = jst("2026-10-12T04:00")
        let sessions = [session("2026-10-12T09:00", "2026-10-12T11:00")]
        let lastWeek = DetoxDay.make(.init(
            dayStart: lastWeekStart, dayEnd: jst("2026-10-13T04:00"), until: jst("2026-10-13T04:00"),
            events: [event(.started, "2026-10-01T09:00")] + opened("2026-10-12T10:00", minutes: 15),
            focus: [interval("2026-10-12T09:00", "2026-10-12T11:00")], detoxTimers: [], sleep: [], gameWindows: []))
        let s = HomeSnapshot.make(now: jst("2026-10-19T12:00"), calendar: calendar, todaySessions: [], plan: nil,
                                  lastWeekSessions: sessions, lastWeekDetox: lastWeek)
        let theirs = try #require(s.opponentPoints(.lastWeek, at: jst("2026-10-19T12:00")))
        let ghostDetox = try #require(s.ghostDetox)
        #expect((theirs - ghostDetox.points(until: jst("2026-10-19T12:00"))).isApprox(9.75))
    }

    @Test func goalGhostIsThreePointsBelowAPerfectDay() throws {
        // 2回開ける分（−3）を引き、計画どおりの点3つは自分と同じにもらう：97.5 − 3 ＝ 94.5
        let s = followedPlan(now: "2026-10-19T12:00", events: [])
        let whole = try #require(s.opponentPoints(.goal, at: dayEnd))
        #expect(whole.isApprox(94.5))
    }

    @Test func goalGhostOpensAtThirdsOfTheWakingDay() throws {
        // 起きている 7:00〜24:00（17時間）の3等分 → 12:40 と 18:20
        let s = followedPlan(now: "2026-10-19T12:00", events: [])
        let goalDetox = try #require(s.goalDetox)
        #expect(goalDetox.unlockStarts == [jst("2026-10-19T12:40"), jst("2026-10-19T18:20")])
        let before = try #require(s.opponentPoints(.goal, at: jst("2026-10-19T12:40")))
        let after = try #require(s.opponentPoints(.goal, at: jst("2026-10-19T12:41")))
        #expect((after - before).isApprox(0.05 - 1))
    }

    @Test func oneOpenStillWinsTwoOpensLose() throws {
        // 計画どおりで10分を1回 → +1.5pt で勝ち、2回 → −1.0pt で負け（オーナーの「1回ならギリ勝ち」）
        let one = followedPlan(now: "2026-10-20T03:59:59", events: opened("2026-10-19T12:00"))
        let goal = try #require(one.opponentPoints(.goal, at: dayEnd))
        #expect((one.myPoints(until: dayEnd) - goal).isApprox(1.5, tolerance: 0.01))
        let two = followedPlan(now: "2026-10-20T03:59:59", events: opened("2026-10-19T12:00") + opened("2026-10-19T20:00"))
        #expect((two.myPoints(until: dayEnd) - goal).isApprox(-1.0, tolerance: 0.01))
    }

    @Test func goalGapIsNotCountedTwice() throws {
        // 9:00–10:00 と 12:00–13:00 の勉強、目標9時間30分 → 起きている 7:00–0:00 の空き15時間に半分の速さで7時間30分。
        // 10:00–12:00 の2時間は 集中1時間分 6pt ＋ ブロック中1時間分 3pt ＝ 9pt
        let plan = PlanDraft(blocks: [PlanBlockDraft(start: jst("2026-10-19T09:00"), minutes: 60, category: c[0]),
                                      PlanBlockDraft(start: jst("2026-10-19T12:00"), minutes: 60, category: c[0])],
                             goalSeconds: 9 * 3600 + 30 * 60)
        let s = HomeSnapshot.make(now: jst("2026-10-19T09:00"), calendar: calendar, todaySessions: [], plan: plan,
                                  lastWeekSessions: [], sleep: sleep)
        let at10 = try #require(s.opponentPoints(.goal, at: jst("2026-10-19T10:00")))
        let at12 = try #require(s.opponentPoints(.goal, at: jst("2026-10-19T12:00")))
        #expect((at12 - at10).isApprox(9.0))
    }

    @Test func goalSpreadHasNoRunSlowdown() {
        // 計画なし日、目標6時間 → 8:00–20:00 に半分の速さ。休みを挟むとみなし、1回の逓減なし：6時間×6 ＝ 36
        let goal = GoalGhost(plan: nil, goalSeconds: 6 * 3600, sleep: [], dayStart: dayStart, calendar: calendar)
        #expect(FocusPoints.points(goal.segments, until: jst("2026-10-19T21:00")).isApprox(36.0))
        // 1日の合計の逓減は掛ける：目標10時間 → 8時間まで48 ＋ 2時間×4.5 ＝ 57
        let long = GoalGhost(plan: nil, goalSeconds: 10 * 3600, sleep: [], dayStart: dayStart, calendar: calendar)
        #expect(FocusPoints.points(long.segments, until: jst("2026-10-19T21:00")).isApprox(57.0))
    }

    @Test func goalBlocksBackToBackAreOneRun() {
        // 9:00–10:30 と 10:30–12:00 → 続けて3時間：9 ＋ 6.75 ＝ 15.75
        let plan = PlanDraft(blocks: [PlanBlockDraft(start: jst("2026-10-19T09:00"), minutes: 90, category: c[0]),
                                      PlanBlockDraft(start: jst("2026-10-19T10:30"), minutes: 90, category: c[0])])
        let goal = GoalGhost(plan: plan, goalSeconds: nil, sleep: [], dayStart: dayStart, calendar: calendar)
        #expect(FocusPoints.points(goal.segments, until: jst("2026-10-19T13:00")).isApprox(15.75))
    }

    @Test func goalPlannedDetoxBlocksUseTheCap() throws {
        // 計画の掃除2時間 → ゴーストも1時間だけ0.75（4.5＋3.0）。掃除の計画どおりの点 +1（14:36、GHO-16）
        let plan = PlanDraft(blocks: [PlanBlockDraft(start: jst("2026-10-19T09:00"), minutes: 60, category: c[0]),
                                      PlanBlockDraft(start: jst("2026-10-19T13:00"), minutes: 120, category: c[3])])
        let s = HomeSnapshot.make(now: jst("2026-10-19T09:00"), calendar: calendar, todaySessions: [], plan: plan,
                                  lastWeekSessions: [], sleep: sleep)
        let at13 = try #require(s.opponentPoints(.goal, at: jst("2026-10-19T13:00")))
        let at15 = try #require(s.opponentPoints(.goal, at: jst("2026-10-19T15:00")))
        #expect((at15 - at13).isApprox(8.5))
    }

    // MARK: 目標を上げればゴーストの点も上がる（2026-10-03）

    @Test func raisingTheGoalNeverLowersTheGhost() {
        // 計画 9:00〜12:00・14:00〜17:00（6時間）、起きている時間も 9:00〜17:00。目標7時間 → 空き時間に半分の速さ、8時間 → 空き時間がちょうど埋まる
        let awake9to17 = [DateInterval(start: jst("2026-10-19T00:00"), end: jst("2026-10-19T09:00")),
                          DateInterval(start: jst("2026-10-19T17:00"), end: jst("2026-10-20T07:00"))]
        let plan = PlanDraft(blocks: [PlanBlockDraft(start: jst("2026-10-19T09:00"), minutes: 180, category: c[0]),
                                      PlanBlockDraft(start: jst("2026-10-19T14:00"), minutes: 180, category: c[0])])
        func points(goalHours: Int) -> Double {
            let goal = GoalGhost(plan: plan, goalSeconds: goalHours * 3600, sleep: awake9to17, dayStart: dayStart, calendar: calendar)
            return FocusPoints.points(goal.segments, until: dayEnd)
        }
        #expect(points(goalHours: 6).isApprox(31.5))   // 15.75×2
        #expect(points(goalHours: 7).isApprox(37.5))   // ＋空き時間の1時間 6
        #expect(points(goalHours: 8).isApprox(43.5))   // ＋空き時間の2時間 12（休みなく続けた扱いにしない）
        // 空き時間に入りきらない分（17:00〜19:00）も休みを挟むとみなす：10時間 →
        // 9:00〜12:00 15.75 ＋ 空き2時間 12 ＋ 14:00〜17:00（1日6.5時間目から×0.75）9＋6.75 ＋ 17:00〜19:00（8時間目から×0.75）9 ＝ 52.5
        #expect(points(goalHours: 10).isApprox(52.5))
    }

    @Test func noPlanGoalOverTwelveHoursTakesBreaks() {
        // 計画なし日、目標14時間 → 7:00〜21:00 に進む。1日の合計の逓減だけ：48＋9＋4時間×3 ＝ 69
        let goal = GoalGhost(plan: nil, goalSeconds: 14 * 3600, sleep: [], dayStart: dayStart, calendar: calendar)
        #expect(FocusPoints.points(goal.segments, until: dayEnd).isApprox(69.0))
    }

    // MARK: 4:00 をまたいだタイマーは新しい日の集中に入れる（2026-10-03）

    @Test func timerAcrossFourCountsAfterFourForTheNewDay() {
        // 前の日（10/18 の日）に 3:00 から始めて 5:00 まで勉強 → 10/19 の日は 4:00〜5:00 の1時間
        let crossing = session("2026-10-19T03:00", "2026-10-19T05:00")
        let s = HomeSnapshot.make(now: jst("2026-10-19T06:00"), calendar: calendar, todaySessions: [crossing], plan: nil,
                                  lastWeekSessions: [])
        #expect(s.focusSeconds == 3600)
        #expect(FocusPoints.points(s.sessions, until: s.now).isApprox(6.0))
    }

    @Test func lastWeekGhostAlsoTakesTheTimerAcrossFour() throws {
        // 先週の同じ日の前夜 3:00〜5:00 → 先週のその日は 4:00〜5:00 の1時間
        let ghost = try #require(GhostSummary(lastWeek: [session("2026-10-12T03:00", "2026-10-12T05:00")],
                                              lastWeekStart: jst("2026-10-12T04:00"), todayStart: dayStart))
        #expect(ghost.wholeDayFocusSeconds == 3600)
        #expect(ghost.segments.first?.start == dayStart)
    }
}
