import Foundation
import Testing
@testable import FocusApp

/// ポイント（GHO-14）と、裏のグラフの線（GHO-13）。
struct RacePointsTests {
    private let calendar = tokyoCalendar
    private let c = DefaultCategories.all
    private var rest: CategoryOption { c[4] }

    private func points(_ sessions: [FocusSession], until time: String) -> Double {
        FocusPoints.points(sessions.flatMap { $0.activeSegments(now: jst(time)) }, until: jst(time))
    }

    // MARK: 重み

    @Test func focusTenMinutesIsOnePoint() {
        #expect(points([session("2026-10-19T09:00", "2026-10-19T09:10")], until: "2026-10-19T12:00")
            .isApprox(1.0))
        #expect(points([session("2026-10-19T09:00", "2026-10-19T10:00")], until: "2026-10-19T12:00")
            .isApprox(6.0))
    }

    /// デトックスの点はブロックが効いていた時間で数える（DetoxDay、DTX-03）。タイマーの点は集中だけ
    @Test func detoxTimerHasNoTimerPoints() {
        #expect(points([session("2026-10-19T09:00", "2026-10-19T10:00", category: rest)], until: "2026-10-19T12:00")
            .isApprox(0))
    }

    @Test func underOneMinuteCountsProportionally() {
        // 記録は1分以上だが、計算は秒単位で比例する（30秒＝0.05pt）
        #expect(points([session("2026-10-19T09:00:00", "2026-10-19T09:00:30")], until: "2026-10-19T12:00")
            .isApprox(0.05))
    }

    // MARK: 続けた長さ（1回90分で×0.75、PointsRulesTests に詳しく）

    @Test func backToBackSessionsAreOneRun() {
        // 9:00–10:00 と 10:00–11:00（休み0分）→ 続けて2時間：9 ＋ 30分×0.075 ＝ 11.25
        let two = [session("2026-10-19T09:00", "2026-10-19T10:00"), session("2026-10-19T10:00", "2026-10-19T11:00")]
        #expect(points(two, until: "2026-10-19T12:00").isApprox(11.25))
    }

    @Test func lastWeekGhostClippedAtFour() throws {
        // 先週の夜 1:00〜5:00（1:30〜2:00 一時停止＝30分休んだので数え直し）→ 翌4:00 で切る
        // 30分 3.0 ＋ 2:00〜4:00 の2時間 11.25 ＝ 14.25
        let late = session("2026-10-13T01:00", "2026-10-13T05:00", pauses: [("2026-10-13T01:30", "2026-10-13T02:00")])
        let ghost = try #require(GhostSummary(lastWeek: [late], lastWeekStart: jst("2026-10-12T04:00"),
                                              todayStart: jst("2026-10-19T04:00")))
        #expect(FocusPoints.points(ghost.segments, until: jst("2026-10-20T04:00")).isApprox(14.25))
    }

    // MARK: 目標のゴースト

    @Test func goalBlockCountsAsOneTimer() {
        // 9:00–11:00 の集中ブロック1つ → 9 ＋ 30分×0.075 ＝ 11.25pt
        let plan = PlanDraft(blocks: [PlanBlockDraft(start: jst("2026-10-19T09:00"), minutes: 120, category: c[0])])
        let goal = GoalGhost(plan: plan, goalSeconds: nil, sleep: [], dayStart: jst("2026-10-19T04:00"), calendar: calendar)
        #expect(FocusPoints.points(goal.segments, until: jst("2026-10-19T12:00")).isApprox(11.25))
    }

    @Test func goalBlocksAreSeparateTimers() {
        // 9:00–10:00 と 11:00–12:00 の2ブロック（1時間休み）→ 12.0
        let blocks = [PlanBlockDraft(start: jst("2026-10-19T09:00"), minutes: 60, category: c[0]),
                      PlanBlockDraft(start: jst("2026-10-19T11:00"), minutes: 60, category: c[0])]
        let goal = GoalGhost(plan: PlanDraft(blocks: blocks), goalSeconds: nil, sleep: [], dayStart: jst("2026-10-19T04:00"), calendar: calendar)
        #expect(FocusPoints.points(goal.segments, until: jst("2026-10-19T13:00")).isApprox(12.0))

        // 目標3時間：起きている時間が 9:00–12:00 なら、空き時間 10:00–11:00 に足す。足した分は休みを挟むとみなす
        // （続けて1回は計画のブロックだけ、2026-10-03）→ 18.0
        let awake9to12 = [DateInterval(start: jst("2026-10-19T00:00"), end: jst("2026-10-19T09:00")),
                          DateInterval(start: jst("2026-10-19T12:00"), end: jst("2026-10-20T07:00"))]
        let more = GoalGhost(plan: PlanDraft(blocks: blocks), goalSeconds: 3 * 3600, sleep: awake9to12,
                             dayStart: jst("2026-10-19T04:00"), calendar: calendar)
        #expect(FocusPoints.points(more.segments, until: jst("2026-10-19T13:00")).isApprox(18.0))
    }

    @Test func goalSpreadCountsAccumulatedFocus() {
        // 計画なし日、目標6時間 → 8:00–20:00 に半分の速さ。休みを挟むとみなして1回の逓減なし → 36
        let goal = GoalGhost(plan: nil, goalSeconds: 6 * 3600, sleep: [], dayStart: jst("2026-10-19T04:00"), calendar: calendar)
        #expect(FocusPoints.points(goal.segments, until: jst("2026-10-19T21:00")).isApprox(36.0))
        // 10:00 までは集中1時間分 → 6.0
        #expect(FocusPoints.points(goal.segments, until: jst("2026-10-19T10:00")).isApprox(6.0))
    }

    // MARK: グラフの線（GHO-13）

    /// 先週も今日も、ずっと前からブロックを始めている（デトックスはブロックの時間）
    private func detox(_ dayStart: String, until: String, sessions: [FocusSession]) -> DetoxDay {
        let segments = sessions.flatMap { $0.activeSegments(now: jst(until)) }
        return DetoxDay.make(.init(dayStart: jst(dayStart), dayEnd: jst(dayStart).addingTimeInterval(86400), until: jst(until),
                                   events: [BlockEvent(occurredAt: jst("2026-10-01T09:00"), timeZoneId: "Asia/Tokyo", kind: .started)],
                                   focus: segments.filter(\.countsAsFocus).map { DateInterval(start: $0.start, end: $0.end) },
                                   detoxTimers: segments.filter { !$0.countsAsFocus }.map {
                                       DetoxTimer(interval: DateInterval(start: $0.start, end: $0.end), group: $0.detoxGroup)
                                   },
                                   sleep: [], gameWindows: []))
    }

    private func snapshot(_ now: String, today: [FocusSession], lastWeek: [FocusSession], plan: PlanDraft? = nil,
                          noPlanGoal: Int? = nil) -> HomeSnapshot {
        HomeSnapshot.make(now: jst(now), calendar: calendar, todaySessions: today, plan: plan,
                          lastWeekSessions: lastWeek, noPlanGoalSeconds: noPlanGoal,
                          detox: detox("2026-10-19T04:00", until: now, sessions: today),
                          lastWeekDetox: detox("2026-10-12T04:00", until: "2026-10-13T04:00", sessions: lastWeek))
    }

    private let todaySessions = [
        session("2026-10-19T09:00", "2026-10-19T10:00"),
        session("2026-10-19T12:00", "2026-10-19T12:30", category: DefaultCategories.all[4]),
    ]
    private let lastWeekSessions = [
        session("2026-10-12T08:00", "2026-10-12T09:00"),
        session("2026-10-12T13:00", "2026-10-12T14:00", category: DefaultCategories.all[4]),
        session("2026-10-12T20:00", "2026-10-12T21:00"),
    ]

    /// グラフはポイントだけ（2026-10-02 オーナー決定、Q26）：自分と相手の2本
    @Test func curvesAreMyAndOpponentPoints() {
        let s = snapshot("2026-10-19T14:30", today: todaySessions, lastWeek: lastWeekSessions)
        #expect(Set(s.raceCurves(opponent: .lastWeek).map(\.kind)) == [.minePoints, .opponentPoints])
    }

    @Test func myCurveEndsNowAtCurrentPoints() throws {
        let s = snapshot("2026-10-19T14:30", today: todaySessions, lastWeek: lastWeekSessions)
        let mine = try #require(s.raceCurves(opponent: .lastWeek).first { $0.kind == .minePoints })
        #expect(mine.values.first?.date == jst("2026-10-19T04:00"))
        #expect(mine.values.first?.value == 0)
        #expect(mine.values.last?.date == jst("2026-10-19T14:30"))
        #expect((mine.values.last?.value ?? -1).isApprox(s.points))
    }

    @Test func opponentCurveCoversWholeDay() throws {
        let s = snapshot("2026-10-19T14:30", today: todaySessions, lastWeek: lastWeekSessions)
        let theirs = try #require(s.raceCurves(opponent: .lastWeek).first { $0.kind == .opponentPoints })
        #expect(theirs.values.last?.date == jst("2026-10-20T04:00"))
        // 今の時刻にも点がある（今より先を薄くする境目）
        #expect(theirs.values.contains { $0.date == jst("2026-10-19T14:30") })
    }

    /// 目標のゴーストはデトックスの点も貯める（2026-10-02 オーナー決定。2026-10-03 から2回だけ開けた日）
    @Test func goalEarnsIdealDetoxPoints() throws {
        let plan = PlanDraft(blocks: [PlanBlockDraft(start: jst("2026-10-19T09:00"), minutes: 120, category: c[0]),
                                      PlanBlockDraft(start: jst("2026-10-19T16:00"), minutes: 60, category: c[5])])
        let s = HomeSnapshot.make(now: jst("2026-10-19T14:30"), calendar: calendar, todaySessions: todaySessions, plan: plan,
                                  lastWeekSessions: [],
                                  sleep: [DateInterval(start: jst("2026-10-19T00:00"), end: jst("2026-10-19T07:00")),
                                          DateInterval(start: jst("2026-10-20T00:00"), end: jst("2026-10-20T07:00"))])
        let goalDetox = try #require(s.goalDetox)
        // 集中の2時間は集中、運動の1時間はタイマー中（1.5倍）、0:00〜4:00 と 4:00〜7:00 は寝ている
        #expect(goalDetox.pieces.contains { $0.kind == .focus && $0.start == jst("2026-10-19T09:00") })
        #expect(goalDetox.pieces.contains { $0.kind == .detoxTimer && $0.start == jst("2026-10-19T16:00") })
        #expect(goalDetox.pieces.contains { $0.kind == .asleep && $0.start == jst("2026-10-19T04:00") })
        #expect(goalDetox.detoxSeconds(until: s.dayEnd) == 22 * 3600)
        let whole = try #require(s.opponentPoints(.goal, at: s.dayEnd))
        // ＋計画どおりの点2つ（勉強と運動、GHO-16）
        #expect(whole.isApprox(11.25 + goalDetox.points(until: s.dayEnd) + 2))
        #expect(whole > 11.25 + 50)
        // 時間の線はないので、目標を選んでも自分と目標のポイントの2本
        #expect(Set(s.raceCurves(opponent: .goal).map(\.kind)) == [.minePoints, .opponentPoints])
    }

    @Test func noOpponentShowsOnlyMyLine() {
        // 先週はタイマーもブロックの記録もない
        let s = HomeSnapshot.make(now: jst("2026-10-19T14:30"), calendar: calendar, todaySessions: todaySessions, plan: nil,
                                  lastWeekSessions: [],
                                  detox: detox("2026-10-19T04:00", until: "2026-10-19T14:30", sessions: todaySessions))
        #expect(Set(s.raceCurves(opponent: nil).map(\.kind)) == [.minePoints])
        #expect(Set(s.raceCurves(opponent: .lastWeek).map(\.kind)) == [.minePoints])
    }

    /// 先週タイマーを使っていなくても、デトックスが丸1日分あれば先週の線を出す
    @Test func lastWeekDetoxOnlyStillShowsOpponent() throws {
        let s = snapshot("2026-10-19T14:30", today: todaySessions, lastWeek: [])
        #expect(Set(s.raceCurves(opponent: .lastWeek).map(\.kind)) == [.minePoints, .opponentPoints])
        let theirs = try #require(s.opponentPoints(.lastWeek, at: s.dayEnd))
        let ghostDetox = try #require(s.ghostDetox)
        #expect(theirs.isApprox(ghostDetox.points(until: s.dayEnd)))
    }

    @Test func pointCurvesAreMineAndOpponent() throws {
        let s = snapshot("2026-10-19T14:30", today: todaySessions, lastWeek: lastWeekSessions)
        let curves = s.raceCurves(opponent: .lastWeek)
        #expect(Set(curves.map(\.kind)) == [.minePoints, .opponentPoints])
        // 自分：集中1時間 6pt ＋ ブロックの時間のデトックス（DTX-03）
        let mine = try #require(curves.first { $0.kind == .minePoints })
        let myDetox = try #require(s.detox).points(until: jst("2026-10-19T14:30"))
        #expect(myDetox > 0)
        #expect((mine.values.last?.value ?? -1).isApprox(6 + myDetox))
        #expect(s.points.isApprox(6 + myDetox))
        // 先週：1日で 集中2時間（別々）12pt ＋ 1日分のデトックス
        let theirs = try #require(curves.first { $0.kind == .opponentPoints })
        let theirDetox = try #require(s.ghostDetox).points(until: jst("2026-10-20T04:00"))
        #expect((theirs.values.last?.value ?? -1).isApprox(12 + theirDetox))
    }

    /// 先週のデトックスがない日（丸1日分の記録がない）は、相手のデトックスの線を出さない
    @Test func noLastWeekDetoxHidesItsLine() {
        let s = HomeSnapshot.make(now: jst("2026-10-19T14:30"), calendar: calendar, todaySessions: todaySessions, plan: nil,
                                  lastWeekSessions: lastWeekSessions,
                                  detox: detox("2026-10-19T04:00", until: "2026-10-19T14:30", sessions: todaySessions),
                                  lastWeekDetox: nil)
        // ポイントは自分だけデトックスの点が付いて比べられないので、相手の線を出さない
        #expect(Set(s.raceCurves(opponent: .lastWeek).map(\.kind)) == [.minePoints])
        #expect(s.opponentPoints(.lastWeek, at: jst("2026-10-19T14:30")) == nil)
    }

    @Test func curvesAtDayStartAreEmptyButValid() {
        // 4:00 ちょうど（開いた直後）でも線が作れる。同じ時刻の点が2つにならない
        let s = snapshot("2026-10-19T04:00", today: [], lastWeek: lastWeekSessions)
        let curves = s.raceCurves(opponent: .lastWeek)
        #expect(curves.allSatisfy { !$0.values.isEmpty })
        #expect(curves.allSatisfy { Set($0.values.map(\.date)).count == $0.values.count })
        #expect(curves.first { $0.kind == .minePoints }?.values.last?.value == 0)
    }

    @Test func pausedRunningSessionStopsGrowing() throws {
        // 9:00 から実行中、9:40 から一時停止のまま今 10:30 → 40分のまま
        let paused = session("2026-10-19T09:00", nil, pauses: [("2026-10-19T09:40", nil)])
        let s = snapshot("2026-10-19T10:30", today: [paused], lastWeek: [])
        #expect(s.focusSeconds == 2400)
        // 集中の点は40分のまま（デトックスの点は一時停止中もブロックの時間として増える）
        #expect(FocusPoints.points(s.sessions, until: s.now).isApprox(4.0))
        #expect(s.points.isApprox(4.0 + (s.detox?.points(until: s.now) ?? 0)))
        #expect((s.detox?.points(until: s.now) ?? 0) > 0)
    }

    // MARK: トラックの進み（GHO-12）

    @Test func progressIsShareOfOpponentsWholeDay() {
        // 先週は1日で集中2時間。14:30 の時点で自分1時間・先週1時間 → どちらも半周
        let s = snapshot("2026-10-19T14:30", today: todaySessions, lastWeek: lastWeekSessions)
        let progress = s.raceProgress(.lastWeek)
        #expect(progress.me.isApprox(0.5))
        #expect((progress.opponent ?? -1).isApprox(0.5))
    }

    @Test func progressStopsAtFinishWhenAheadOfWholeDay() {
        // 自分が先週の1日分（2時間）を超えて3時間 → ゴールで止まる
        let long = [session("2026-10-19T09:00", "2026-10-19T12:00")]
        let s = snapshot("2026-10-19T14:30", today: long, lastWeek: lastWeekSessions)
        #expect(s.raceProgress(.lastWeek).me == 1)
    }

    @Test func progressWithoutOpponentUsesPlanOrZero() {
        let plan = PlanDraft(blocks: [PlanBlockDraft(start: jst("2026-10-19T09:00"), minutes: 240, category: rest)])
        // 計画に集中がなく、相手もいない → 0（0で割らない）
        let s = snapshot("2026-10-19T14:30", today: todaySessions, lastWeek: [], plan: plan)
        #expect(s.raceProgress(nil).me == 0)
        #expect(s.raceProgress(nil).opponent == nil)
    }

    @Test func lateNightBeforeFourBelongsToSameDay() throws {
        // 翌 1:00 は同じ日（4:00 区切り）。自分の線は 1:00 まで伸びる
        let late = session("2026-10-19T23:30", "2026-10-20T00:30")
        let s = snapshot("2026-10-20T01:00", today: [late], lastWeek: lastWeekSessions)
        let mine = try #require(s.raceCurves(opponent: .lastWeek).first { $0.kind == .minePoints })
        #expect(mine.values.last?.date == jst("2026-10-20T01:00"))
        #expect(s.focusSeconds == 3600)
    }

    /// 目標がないときは目標のゴーストも、そのデトックスもない
    @Test func noGoalHasNoGoalDetox() {
        let s = HomeSnapshot.make(now: jst("2026-10-19T14:30"), calendar: calendar, todaySessions: [], plan: nil,
                                  lastWeekSessions: [])
        #expect(s.goalDetox == nil)
        #expect(s.opponentPoints(.goal, at: s.now) == nil)
    }

    /// 計画なし日でも、目標を決めていれば目標のゴーストはデトックスの点を貯める
    @Test func noPlanGoalEarnsDetox() throws {
        let s = HomeSnapshot.make(now: jst("2026-10-19T14:30"), calendar: calendar, todaySessions: [], plan: nil,
                                  lastWeekSessions: [], noPlanGoalSeconds: 6 * 3600,
                                  sleep: [DateInterval(start: jst("2026-10-19T00:00"), end: jst("2026-10-19T07:00"))])
        let goalDetox = try #require(s.goalDetox)
        #expect(goalDetox.pieces.contains { $0.kind == .asleep })
        #expect(goalDetox.points(until: s.dayEnd) > 0)
    }
}

extension RaceCurve {
    /// その時刻ちょうどの点の値（なければ nil）
    func value(at date: Date) -> Double? { values.first { $0.date == date }?.value }
}

extension Double {
    func isApprox(_ other: Double, tolerance: Double = 0.0001) -> Bool { abs(self - other) < tolerance }
}
