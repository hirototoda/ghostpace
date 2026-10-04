import Foundation
import Testing
@testable import FocusApp

struct FocusSessionTests {
    private let calendar = tokyoCalendar

    @Test func activeSecondsExcludesPauses() {
        let s = session("2026-10-19T09:00", "2026-10-19T09:30", pauses: [("2026-10-19T09:10", "2026-10-19T09:15")])
        #expect(s.activeSeconds(at: jst("2026-10-19T12:00")) == 25 * 60)
        #expect(s.activeSegments(now: jst("2026-10-19T12:00")).map { [$0.start, $0.end] } == [
            [jst("2026-10-19T09:00"), jst("2026-10-19T09:10")],
            [jst("2026-10-19T09:15"), jst("2026-10-19T09:30")],
        ])
        #expect(s.pauseCount == 1)
    }

    @Test func activeSecondsWhilePausedIsFrozen() {
        let s = session("2026-10-19T09:00", nil, pauses: [("2026-10-19T09:10", nil)])
        #expect(s.isPaused)
        #expect(s.activeSeconds(at: jst("2026-10-19T09:12")) == 10 * 60)
        #expect(s.activeSeconds(at: jst("2026-10-19T09:40")) == 10 * 60)
        // 時計のずれで now が開始より前
        #expect(s.activeSeconds(at: jst("2026-10-19T08:59")) == 0)
    }

    @Test func blockCountdownIgnoresPauses() {
        let s = session("2026-10-19T09:20", nil, pauses: [("2026-10-19T09:30", "2026-10-19T09:35")],
                        plannedEnd: "2026-10-19T10:10")
        #expect(s.isCountdown)
        #expect(s.remainingSeconds(at: jst("2026-10-19T09:50")) == 20 * 60)
        let paused = session("2026-10-19T09:20", nil, pauses: [("2026-10-19T09:30", nil)], plannedEnd: "2026-10-19T10:10")
        #expect(paused.remainingSeconds(at: jst("2026-10-19T09:40")) == 30 * 60)
    }

    @Test func lengthCountdownShiftsByPauses() {
        let s = session("2026-10-19T09:00", nil, pauses: [("2026-10-19T09:10", "2026-10-19T09:15")], plannedMinutes: 25)
        #expect(s.plannedEnd(at: jst("2026-10-19T09:20")) == jst("2026-10-19T09:30"))
        #expect(s.remainingSeconds(at: jst("2026-10-19T09:20")) == 10 * 60)

        // 停止中は残りが減らず、終了予定が後ろへずれていく
        let paused = session("2026-10-19T09:00", nil, pauses: [("2026-10-19T09:10", nil)], plannedMinutes: 25)
        #expect(paused.remainingSeconds(at: jst("2026-10-19T09:12")) == 15 * 60)
        #expect(paused.remainingSeconds(at: jst("2026-10-19T09:40")) == 15 * 60)
        #expect(paused.plannedEnd(at: jst("2026-10-19T09:40")) == jst("2026-10-19T09:55"))
    }

    @Test func stopwatchHasNoPlannedEnd() {
        let s = session("2026-10-19T09:00", nil)
        #expect(!s.isCountdown)
        #expect(s.plannedEnd(at: jst("2026-10-19T09:10")) == nil)
        #expect(s.remainingSeconds(at: jst("2026-10-19T09:10")) == nil)
    }

    @Test func overtimeIsNegativeRemaining() {
        let s = session("2026-10-19T09:00", nil, plannedMinutes: 25)
        #expect(s.remainingSeconds(at: jst("2026-10-19T09:28")) == -3 * 60)
    }

    @Test func endTimeCheckOvertimeBoundary() {
        let s = session("2026-10-19T09:00", nil, plannedMinutes: 25)
        #expect(!s.needsEndTimeCheck(at: jst("2026-10-19T09:54:59"), calendar: calendar))
        #expect(s.needsEndTimeCheck(at: jst("2026-10-19T09:55:00"), calendar: calendar))
    }

    @Test func endTimeCheckOvertimeWhilePaused() {
        // 計画ブロックのカウントダウンは停止中も終わりが動かないので、止め忘れの停止も拾う
        let s = session("2026-10-19T09:20", nil, pauses: [("2026-10-19T09:30", nil)], plannedEnd: "2026-10-19T10:10")
        #expect(s.needsEndTimeCheck(at: jst("2026-10-19T10:40"), calendar: calendar))
    }

    @Test func endTimeCheckStopwatchBoundary() {
        let s = session("2026-10-19T09:00", nil)
        #expect(!s.needsEndTimeCheck(at: jst("2026-10-19T12:00:00"), calendar: calendar))
        #expect(s.needsEndTimeCheck(at: jst("2026-10-19T12:00:01"), calendar: calendar))
        // 壁時計で3時間30分、停止30分 → 3時間ちょうど
        let paused = session("2026-10-19T09:00", nil, pauses: [("2026-10-19T10:00", "2026-10-19T10:30")])
        #expect(!paused.needsEndTimeCheck(at: jst("2026-10-19T12:30"), calendar: calendar))
    }

    @Test func endTimeCheckDayBoundary() {
        let early = session("2026-10-19T03:30", nil)
        #expect(!early.needsEndTimeCheck(at: jst("2026-10-19T03:59:59"), calendar: calendar))
        #expect(early.needsEndTimeCheck(at: jst("2026-10-19T04:00:00"), calendar: calendar))

        let morning = session("2026-10-19T04:30", nil, plannedEnd: "2026-10-20T03:50")
        #expect(!morning.needsEndTimeCheck(at: jst("2026-10-20T03:59"), calendar: calendar))
        #expect(morning.needsEndTimeCheck(at: jst("2026-10-20T04:00"), calendar: calendar))
    }

    @Test func endingAtNow() throws {
        let now = jst("2026-10-19T09:30")
        let ended = try session("2026-10-19T09:00", nil).ending(at: now, reportedEnd: now)
        #expect(ended.endAt == now)
        #expect(ended.originalEndAt == nil)
    }

    @Test func endingEarlierKeepsOriginal() throws {
        let ended = try session("2026-10-19T09:00", nil, plannedMinutes: 25)
            .ending(at: jst("2026-10-19T14:00"), reportedEnd: jst("2026-10-19T09:25"))
        #expect(ended.endAt == jst("2026-10-19T09:25"))
        #expect(ended.originalEndAt == jst("2026-10-19T14:00"))
        #expect(ended.activeSeconds(at: jst("2026-10-19T14:00")) == 25 * 60)
    }

    @Test func endingInsidePauseUsesPauseStart() throws {
        let ended = try session("2026-10-19T09:00", nil, pauses: [("2026-10-19T09:10", "2026-10-19T09:20")])
            .ending(at: jst("2026-10-19T09:40"), reportedEnd: jst("2026-10-19T09:15"))
        #expect(ended.endAt == jst("2026-10-19T09:10"))
        #expect(ended.pauseCount == 0)
    }

    @Test func endingWhilePausedUsesPauseStart() throws {
        let now = jst("2026-10-19T09:40")
        let ended = try session("2026-10-19T09:00", nil, pauses: [("2026-10-19T09:05", "2026-10-19T09:06"), ("2026-10-19T09:30", nil)])
            .ending(at: now, reportedEnd: now)
        #expect(ended.endAt == jst("2026-10-19T09:30"))
        #expect(ended.pauseCount == 1)
        #expect(ended.originalEndAt == nil)
        #expect(ended.activeSeconds(at: now) == 29 * 60)
    }

    @Test func endingDropsLaterPauses() throws {
        let ended = try session("2026-10-19T09:00", nil, pauses: [("2026-10-19T09:10", "2026-10-19T09:11"), ("2026-10-19T09:40", "2026-10-19T09:45")])
            .ending(at: jst("2026-10-19T10:00"), reportedEnd: jst("2026-10-19T09:30"))
        #expect(ended.pauses == [PauseInterval(start: jst("2026-10-19T09:10"), end: jst("2026-10-19T09:11"))])
    }

    @Test func endingBounds() throws {
        let s = session("2026-10-19T09:00", nil)
        let now = jst("2026-10-19T10:00")
        #expect(throws: SessionError.invalidEnd) { try s.ending(at: now, reportedEnd: jst("2026-10-19T09:00")) }
        #expect(try s.ending(at: now, reportedEnd: jst("2026-10-19T09:00:01")).endAt == jst("2026-10-19T09:00:01"))
        #expect(throws: SessionError.invalidEnd) { try s.ending(at: now, reportedEnd: jst("2026-10-19T10:00:01")) }
    }

    // MARK: 終わった記録の終了時刻を早める（タイムライン、TMR-08）

    @Test func shortenedKeepsFirstOriginalEnd() throws {
        let ended = session("2026-10-19T09:00", "2026-10-19T14:00")
        let once = try ended.shortened(to: jst("2026-10-19T10:00"))
        #expect(once.endAt == jst("2026-10-19T10:00"))
        #expect(once.originalEndAt == jst("2026-10-19T14:00"))
        // 2回目も、いちばん最初の終了時刻が残る
        let twice = try once.shortened(to: jst("2026-10-19T09:30"))
        #expect(twice.endAt == jst("2026-10-19T09:30"))
        #expect(twice.originalEndAt == jst("2026-10-19T14:00"))
    }

    @Test func shortenedInsidePauseUsesPauseStart() throws {
        let ended = session("2026-10-19T09:00", "2026-10-19T10:00",
                            pauses: [("2026-10-19T09:10", "2026-10-19T09:20"), ("2026-10-19T09:40", "2026-10-19T09:45")])
        let shortened = try ended.shortened(to: jst("2026-10-19T09:15"))
        #expect(shortened.endAt == jst("2026-10-19T09:10"))
        #expect(shortened.pauseCount == 0)
    }

    @Test func shortenedDropsLaterPausesKeepsEarlier() throws {
        let ended = session("2026-10-19T09:00", "2026-10-19T10:00",
                            pauses: [("2026-10-19T09:10", "2026-10-19T09:15"), ("2026-10-19T09:40", "2026-10-19T09:45")])
        let shortened = try ended.shortened(to: jst("2026-10-19T09:30"))
        #expect(shortened.pauses == [PauseInterval(start: jst("2026-10-19T09:10"), end: jst("2026-10-19T09:15"))])
    }

    @Test func shortenedBounds() throws {
        let ended = session("2026-10-19T09:00", "2026-10-19T10:00")
        // 延ばせない・同じ時刻も不可・開始以前も不可
        #expect(throws: SessionError.invalidEnd) { try ended.shortened(to: jst("2026-10-19T10:01")) }
        #expect(throws: SessionError.invalidEnd) { try ended.shortened(to: jst("2026-10-19T10:00")) }
        #expect(throws: SessionError.invalidEnd) { try ended.shortened(to: jst("2026-10-19T09:00")) }
        #expect(try ended.shortened(to: jst("2026-10-19T09:59")).endAt == jst("2026-10-19T09:59"))
        // 実行中は直せない
        #expect(throws: SessionError.invalidEnd) { try session("2026-10-19T09:00", nil).shortened(to: jst("2026-10-19T09:30")) }
        // 開始と同時に一時停止していて、長さが0になるなら直せない
        let pausedAtStart = session("2026-10-19T09:00", "2026-10-19T10:00", pauses: [("2026-10-19T09:00", "2026-10-19T09:20")])
        #expect(throws: SessionError.invalidEnd) { try pausedAtStart.shortened(to: jst("2026-10-19T09:10")) }
    }

    @Test func endIfShortenedPreviewsPauseStart() {
        let ended = session("2026-10-19T09:00", "2026-10-19T10:00", pauses: [("2026-10-19T09:10", "2026-10-19T09:20")])
        #expect(ended.endIfShortened(to: jst("2026-10-19T09:15")) == jst("2026-10-19T09:10"))
        #expect(ended.endIfShortened(to: jst("2026-10-19T09:30")) == jst("2026-10-19T09:30"))
    }

    @Test func pausesJSONRoundTrip() {
        let pauses = [PauseInterval(start: jst("2026-10-19T09:10"), end: jst("2026-10-19T09:15")),
                      PauseInterval(start: jst("2026-10-19T09:30"), end: nil)]
        #expect(PauseInterval.decode(PauseInterval.encode(pauses)) == pauses)
        #expect(PauseInterval.decode(Data("not json".utf8)) == [])
    }
}

struct RunningTimerTests {
    @Test func ghostDiffUpdatesWhileRunning() {
        let start = jst("2026-10-19T09:00")
        let running = RunningTimer(
            session: session("2026-10-19T09:00", nil, plannedMinutes: 25),
            focusSecondsBefore: 10 * 60,
            ghost: GhostSummary(segments: [TimeSegment(start: start, end: start.addingTimeInterval(20 * 60), countsAsFocus: true)]))
        #expect(running.ghostDiffSeconds(at: start.addingTimeInterval(5 * 60)) == 10 * 60)
        #expect(running.ghostDiffSeconds(at: start.addingTimeInterval(30 * 60)) == 20 * 60)
    }

    @Test func pausedTimeDoesNotAddToDiff() {
        let running = RunningTimer(
            session: session("2026-10-19T09:00", nil, pauses: [("2026-10-19T09:10", nil)]),
            focusSecondsBefore: 0, ghost: GhostSummary(segments: []))
        #expect(running.ghostDiffSeconds(at: jst("2026-10-19T09:30")) == 10 * 60)
    }
}

@MainActor
struct LengthSliderTests {
    @Test func lengthIsFiveMinutesToThreeHoursInFiveMinuteSteps() {
        #expect(LengthSlider.minuteRange == 5...180)
        #expect(LengthSlider.minuteStep == 5)
    }
}
