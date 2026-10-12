import Foundation
import Testing
@testable import FocusApp

/// ホームの裏とその日のグラフのラップの一覧（GHO-06・13、ANA-05、2026-10-12）：
/// ［▶］で流している間は空から始め、線の先が2時間の区切りを過ぎるたびに、その区間を最後まで数えた行を1行ずつ足す。
/// 止める・流し終わると今の一覧（今の区間の「途中」まで）に戻る。
/// 2026-10-12 からラップは集中した時間ではなくポイント（区間で増えたポイント）で出し、両者 0.0 の区間を省く
@MainActor
struct RaceLapListTests {
    private let dayStart = jst("2026-10-19T04:00")

    private func seg(_ from: String, _ to: String, day: String = "2026-10-19") -> TimeSegment {
        TimeSegment(start: jst("\(day)T\(from)"), end: jst("\(day)T\(to)"), countsAsFocus: true)
    }

    /// 10分＝1pt のポイント（逓減なし。数え方の確かめやすさのため）
    private func tenMinutes(_ segments: [TimeSegment]) -> (Date) -> Double {
        { Double(segments.focusSeconds(until: $0)) / 600 }
    }

    /// 自分：4:30–5:00・8:30–9:30・10:00–11:15。相手：9:00–10:00・11:00–11:30。今は 11:15（10:00–12:00 の途中）。
    /// 6:00–8:00 は両者とも 0.0pt
    private var laps: [Lap] {
        let mine = [seg("04:30", "05:00"), seg("08:30", "09:30"), seg("10:00", "11:15")]
        let opponent = [seg("09:00", "10:00"), seg("11:00", "11:30")]
        return Laps.make(mine: mine, opponent: { opponent.focusSeconds(until: $0) },
                         minePoints: tenMinutes(mine), opponentPoints: tenMinutes(opponent),
                         dayStart: dayStart, now: jst("2026-10-19T11:15"))
    }

    private func starts(_ laps: [Lap]) -> [Date] { laps.map(\.interval.start) }

    // MARK: 流していないとき（今の一覧）

    @Test func withoutReplayTheListIsUpToTheCurrentSection() {
        let shown = Laps.listed(laps, replayHead: nil)
        // 6:00–8:00（両者0）は省き、今の区間（途中）まで
        #expect(starts(shown) == [jst("2026-10-19T04:00"), jst("2026-10-19T08:00"), jst("2026-10-19T10:00")])
        #expect(shown.last?.isCurrent == true)
    }

    // MARK: 流している間

    /// 流し始め（線の先が 4:00）は空。4:00–6:00 の最初の区間は 6:00 を過ぎるまで出ない
    @Test func replayStartsEmptyAndTheFirstSectionWaitsForSix() {
        #expect(Laps.listed(laps, replayHead: jst("2026-10-19T04:00")).isEmpty)
        #expect(Laps.listed(laps, replayHead: jst("2026-10-19T05:59")).isEmpty)
        #expect(starts(Laps.listed(laps, replayHead: jst("2026-10-19T06:00"))) == [jst("2026-10-19T04:00")])
    }

    /// 区切りちょうど（8:00）で、その区間（両者0の 6:00–8:00）は省かれる。10:00 ちょうどで 8:00–10:00 が足される
    @Test func rowIsAddedExactlyAtTheBoundary() {
        #expect(starts(Laps.listed(laps, replayHead: jst("2026-10-19T08:00"))) == [jst("2026-10-19T04:00")])
        #expect(starts(Laps.listed(laps, replayHead: jst("2026-10-19T09:59"))) == [jst("2026-10-19T04:00")])
        let ten = Laps.listed(laps, replayHead: jst("2026-10-19T10:00"))
        #expect(starts(ten) == [jst("2026-10-19T04:00"), jst("2026-10-19T08:00")])
    }

    /// 足す行の値は区間を最後まで数えた値（線の先の時刻までではない）
    @Test func addedRowsHaveTheWholeSection() throws {
        let shown = Laps.listed(laps, replayHead: jst("2026-10-19T10:30"))
        let eight = try #require(shown.last)
        #expect(eight.interval.start == jst("2026-10-19T08:00"))
        #expect(eight.minePoints.isApprox(6.0))
        #expect(eight.opponentPoints.isApprox(6.0))
        #expect(!eight.isCurrent)
    }

    /// 今の区間（途中）は流している間は出さない。線の先が今に着いても出さず、止めたら（nil）出る
    @Test func currentSectionAppearsOnlyAfterStopping() {
        let atNow = Laps.listed(laps, replayHead: jst("2026-10-19T11:15"))
        #expect(!atNow.contains { $0.isCurrent })
        #expect(atNow.count == 2)
        #expect(Laps.listed(laps, replayHead: nil).contains { $0.isCurrent })
    }

    /// 相手がいない（ラップがない）日は、流していても止めていても空
    @Test func noRivalMeansNoRows() {
        #expect(Laps.listed([], replayHead: nil).isEmpty)
        #expect(Laps.listed([], replayHead: jst("2026-10-19T12:00")).isEmpty)
    }

    /// 線の先が通過した最後の区切り（一覧を変えるのは区切りを過ぎたときだけ）。区切りちょうども通過に数える
    @Test func passedBoundaryIsTheLastTwoHourMark() {
        #expect(Laps.passedBoundary(dayStart: dayStart, head: jst("2026-10-19T04:00")) == dayStart)
        #expect(Laps.passedBoundary(dayStart: dayStart, head: jst("2026-10-19T05:59")) == dayStart)
        #expect(Laps.passedBoundary(dayStart: dayStart, head: jst("2026-10-19T06:00")) == jst("2026-10-19T06:00"))
        #expect(Laps.passedBoundary(dayStart: dayStart, head: jst("2026-10-19T07:59")) == jst("2026-10-19T06:00"))
        #expect(Laps.passedBoundary(dayStart: dayStart, head: jst("2026-10-19T08:00")) == jst("2026-10-19T08:00"))
        #expect(Laps.passedBoundary(dayStart: dayStart, head: jst("2026-10-20T04:00")) == jst("2026-10-20T04:00"))
        // 1日の外には出ない
        #expect(Laps.passedBoundary(dayStart: dayStart, head: jst("2026-10-19T03:00")) == dayStart)
        #expect(Laps.passedBoundary(dayStart: dayStart, head: jst("2026-10-20T05:00")) == jst("2026-10-20T04:00"))
        // 区切りで決めても、線の先そのもので決めても同じ行になる
        for head in ["06:30", "08:00", "09:59", "10:00", "11:15"].map({ jst("2026-10-19T\($0)") }) {
            #expect(Laps.listed(laps, replayHead: Laps.passedBoundary(dayStart: dayStart, head: head))
                    == Laps.listed(laps, replayHead: head))
        }
    }

    // MARK: 相手ごと（目標・今日）

    /// 相手が目標（計画なし日・目標6時間＝8:00–20:00 に半分の速さ）：区間を最後まで数えた目標の値で足す
    @Test func goalRowsUseTheWholeSection() throws {
        let goal = GoalGhost(plan: nil, goalSeconds: 6 * 3600, sleep: [], dayStart: dayStart, calendar: tokyoCalendar)
        let s = HomeSnapshot(now: jst("2026-10-19T13:00"), dayStart: dayStart, dayEnd: jst("2026-10-20T04:00"),
                             sessions: [seg("08:30", "09:30")], planBlocks: [], isNoPlanDay: true, ghost: nil, goal: goal,
                             reviewTime: jst("2026-10-19T22:00"))
        let laps = s.rivalLaps(.opponent(.goal))
        // 9:00 では 8:00–10:00 はまだ足さない
        #expect(starts(Laps.listed(laps, replayHead: jst("2026-10-19T09:00"))).isEmpty)
        let ten = try #require(Laps.listed(laps, replayHead: jst("2026-10-19T10:00")).last)
        #expect(ten.interval.start == jst("2026-10-19T08:00"))
        #expect(ten.minePoints.isApprox(6.0))
        #expect(ten.opponentPoints.isApprox(6.0))  // 2時間を半分の速さで（目標は1回の逓減なし）
        #expect(RaceRival.opponent(.goal).lapGap(ten) == 0)
        // 12:00–14:00 は今の区間なので、線の先が今（13:00）でも出さない
        let atNow = Laps.listed(laps, replayHead: jst("2026-10-19T13:00"))
        #expect(starts(atNow) == [jst("2026-10-19T08:00"), jst("2026-10-19T10:00")])
        #expect(Laps.listed(laps, replayHead: nil).last?.isCurrent == true)
    }

    /// 今日を相手にした過ぎた日（ANA-05）：線の先が翌4:00 まで進んでも、今日の今の区間より後の行は出ない
    @Test func pastDayAgainstTodayStopsAtTodaysCurrentSection() throws {
        let t = try TestStore(now: jst("2026-10-22T11:00"))
        let c = try t.seeded()
        let focus = try #require(c.first { $0.countsAsFocus })
        func record(_ from: String, _ to: String) throws {
            let now = t.clock.now()
            t.clock.set(jst(from))
            _ = try t.store.start(StartRequest(category: focus, timeZone: tokyo))
            t.clock.set(jst(to))
            let running = try #require(try t.store.runningSession())
            _ = try t.store.end(id: running.id, reportedEnd: nil)
            t.clock.set(now)
        }
        try record("2026-10-13T08:00", "2026-10-13T09:20")
        try record("2026-10-13T14:00", "2026-10-13T15:00")
        try record("2026-10-22T08:00", "2026-10-22T09:08")
        try record("2026-10-22T10:00", "2026-10-22T10:30")  // 今日の今の区間（10:00–12:00）にも集中
        let settings = MemorySettings()
        settings.didShowBlockingIntro = true
        let m = AppModel(store: t.store, clock: t.clock, timeZone: { tokyo }, settings: settings,
                         blocking: FakeBlocking(), blockStore: MemoryBlockStore(), blockLog: MemoryBlockEventLog())
        let past = try #require(m.daySnapshot(of: jst("2026-10-13T04:00"), versusToday: true))
        let laps = past.rivalLaps(.today)
        let end = Laps.listed(laps, replayHead: Laps.passedBoundary(dayStart: past.dayStart, head: past.dayEnd))
        // 今日は 11:00（10:00–12:00 の途中）なので、14:00 の集中は一覧に入らない
        #expect(starts(end) == [jst("2026-10-13T08:00")])
        // この日 80分＝8.0pt、今日 68分＝6.8pt。差は今日−この日
        let eight = try #require(end.first)
        #expect(eight.minePoints.isApprox(8.0))
        #expect(eight.opponentPoints.isApprox(6.8))
        #expect(RaceRival.today.lapGap(eight).isApprox(-1.2))
        // 止めると今の区間（途中）まで
        #expect(Laps.listed(laps, replayHead: nil).last?.isCurrent == true)
    }

    // MARK: ポイントで出す（2026-10-12）

    /// 区間のポイント＝区間の終わり（今の区間は今）までのポイント − 始まりまで。相手も同じ時刻まで。
    /// 開けた時間で減った区間はマイナスになり、一覧に出る
    @Test func sectionPointsAreTheIncreaseAndCanBeNegative() throws {
        // 自分：4:00 から1時間ごとに 1pt（睡眠などのつもり）、12:30 に開けて 3pt 減る。相手：1時間ごとに 0.5pt
        let mine: (Date) -> Double = { date in
            let hours = date.timeIntervalSince(jst("2026-10-19T04:00")) / 3600
            return hours - (date >= jst("2026-10-19T12:30") ? 3 : 0)
        }
        let theirs: (Date) -> Double = { $0.timeIntervalSince(jst("2026-10-19T04:00")) / 7200 }
        let laps = Laps.make(mine: [], opponent: { _ in 0 }, minePoints: mine, opponentPoints: theirs,
                             dayStart: dayStart, now: jst("2026-10-19T13:00"))
        let shown = Laps.listed(laps, replayHead: nil)
        // 集中していなくてもポイントがあれば出る（4:00–6:00 から今の区間まで5行）
        #expect(shown.count == 5)
        let twelve = try #require(shown.last)
        #expect(twelve.isCurrent)
        // 12:00–13:00（途中）：自分 1 − 3 ＝ −2.0、相手は同じ時刻まで 0.5
        #expect(twelve.minePoints.isApprox(-2.0))
        #expect(twelve.opponentPoints.isApprox(0.5))
        #expect(twelve.pointsGap.isApprox(-2.5))
        #expect(!RaceChartLayout.isAhead(twelve.pointsGap))
        let first = try #require(shown.first)
        #expect(first.minePoints.isApprox(2.0) && first.opponentPoints.isApprox(1.0))
    }

    /// 省くのは表示（0.1pt）で両者 0.0 の区間。0.04 は 0.0、0.05 は 0.1 として出る。流している間も同じ
    @Test func sectionsShownAsZeroAreLeftOut() {
        let base = DateInterval(start: jst("2026-10-19T08:00"), duration: Laps.length)
        func lap(_ mine: Double, _ theirs: Double) -> Lap {
            Lap(interval: base, mine: 0, opponent: 0, isCurrent: false, minePoints: mine, opponentPoints: theirs)
        }
        #expect(Laps.listed([lap(0.04, -0.04)], replayHead: nil).isEmpty)
        #expect(Laps.listed([lap(-0.04, 0)], replayHead: nil).isEmpty)
        #expect(Laps.listed([lap(-0.05, 0)], replayHead: nil).count == 1)
        #expect(Laps.listed([lap(0.04, -0.04)], replayHead: jst("2026-10-19T10:00")).isEmpty)
        #expect(Laps.listed([lap(0.05, 0)], replayHead: nil).count == 1)
        #expect(Laps.listed([lap(0, -0.3)], replayHead: jst("2026-10-19T10:00")).count == 1)
        // 自分も相手も集中していなくても（mine・opponent が0秒でも）、ポイントがあれば一覧に出る
        #expect(lap(0.5, 0).hasNoFocus)
        #expect(!lap(0.5, 0).hasNoPoints)
    }

    /// 差は画面に出す2つの値（0.1pt）の引き算。別々に丸めて +0.1 にならない。相手が今日なら今日−この日
    @Test func gapIsTheDifferenceOfTheShownValues() {
        let base = DateInterval(start: jst("2026-10-19T08:00"), duration: Laps.length)
        // 12.04 と 11.96 はどちらも 12.0 と出るので差は 0.0（そのまま引くと +0.08 → +0.1）
        let even = Lap(interval: base, mine: 0, opponent: 0, isCurrent: false, minePoints: 12.04, opponentPoints: 11.96)
        #expect(even.pointsGap == 0)
        #expect(RaceChartLayout.isAhead(even.pointsGap))
        let ahead = Lap(interval: base, mine: 0, opponent: 0, isCurrent: false, minePoints: 9.46, opponentPoints: 7.94)
        // 9.5 − 7.9 ＝ +1.6（そのまま引くと 1.52 → +1.5）
        #expect(ahead.pointsGap.isApprox(1.6))
        #expect(RaceRival.opponent(.lastWeek).lapGap(ahead).isApprox(1.6))
        #expect(RaceRival.opponent(.goal).lapGap(ahead).isApprox(1.6))
        #expect(RaceRival.today.lapGap(ahead).isApprox(-1.6))
        #expect(RaceChartLayout.signedPoints(RaceRival.today.lapGap(ahead)) == "−1.6pt")
    }

    // MARK: 中間地点（ポイント、2026-10-12）

    /// 自分のポイントが目標の値に初めて届いた時刻（秒まで）。届く前に下がっても、初めて届いた所
    @Test func reachTimeFindsTheFirstMomentThePointsReachTheTarget() {
        // 4:00 から1時間に 2pt。10pt に届くのは 9:00
        let linear: (Date) -> Double = { $0.timeIntervalSince(jst("2026-10-19T04:00")) / 1800 }
        #expect(Laps.reachTime(points: 10, of: linear, from: dayStart, until: jst("2026-10-19T12:00")) == jst("2026-10-19T09:00"))
        // ちょうど今届いたときも
        #expect(Laps.reachTime(points: 10, of: linear, from: dayStart, until: jst("2026-10-19T09:00")) == jst("2026-10-19T09:00"))
        // まだ届いていない・目標が0以下なら nil
        #expect(Laps.reachTime(points: 10, of: linear, from: dayStart, until: jst("2026-10-19T08:59")) == nil)
        #expect(Laps.reachTime(points: 0, of: linear, from: dayStart, until: jst("2026-10-19T12:00")) == nil)
        // 9:00 に届いたあと開けて下がっても、届いたのは 9:00（秒の途中も詰める：10:00:30 に届く線）
        let dip: (Date) -> Double = { date in linear(date) - (date >= jst("2026-10-19T09:10") ? 5 : 0) }
        #expect(Laps.reachTime(points: 10, of: dip, from: dayStart, until: jst("2026-10-19T12:00")) == jst("2026-10-19T09:00"))
        let late: (Date) -> Double = { $0.timeIntervalSince(jst("2026-10-19T04:00:30")) / 1800 }
        #expect(Laps.reachTime(points: 12, of: late, from: dayStart, until: jst("2026-10-19T12:00")) == jst("2026-10-19T10:00:30"))
    }

    /// 中間地点は相手の1日分のポイントの半分に自分のポイントが届いた所。
    /// 目標（計画なし日・6時間）は1日 36pt → 半分の 18pt。自分は 8:00–12:00 続けて集中：
    /// 9:30 に 9pt、11:00（3時間）まで ×0.75 で 15.75pt、そこから ×0.5 で 11:45 に 18pt
    @Test func halfwayIsWhenMyPointsReachHalfOfTheirDay() {
        let goal = GoalGhost(plan: nil, goalSeconds: 6 * 3600, sleep: [], dayStart: dayStart, calendar: tokyoCalendar)
        func snapshot(_ now: String) -> HomeSnapshot {
            HomeSnapshot(now: jst(now), dayStart: dayStart, dayEnd: jst("2026-10-20T04:00"),
                         sessions: [seg("08:00", "12:00")], planBlocks: [], isNoPlanDay: true, ghost: nil, goal: goal,
                         reviewTime: jst("2026-10-19T22:00"))
        }
        #expect(snapshot("2026-10-19T13:00").halfwayTime(.goal) == jst("2026-10-19T11:45"))
        #expect(snapshot("2026-10-19T11:44").halfwayTime(.goal) == nil)
        // 先週のデータがない（相手がいない）なら出さない
        #expect(snapshot("2026-10-19T13:00").halfwayTime(.lastWeek) == nil)
        #expect(snapshot("2026-10-19T13:00").rivalHalfway(.today) == nil)
    }

    /// 相手のポイントがない日（先週のデトックスがない日など、グラフに相手の線を出さない日）は、ラップも出さない
    @Test func noRivalPointsMeansNoLaps() {
        let ghost = GhostSummary(segments: [seg("09:00", "10:00")])
        let s = HomeSnapshot(now: jst("2026-10-19T13:00"), dayStart: dayStart, dayEnd: jst("2026-10-20T04:00"),
                             sessions: [seg("08:30", "09:30")], planBlocks: [], isNoPlanDay: true, ghost: ghost,
                             reviewTime: jst("2026-10-19T22:00"))
        #expect(s.opponentPoints(.lastWeek, at: s.now) == nil)
        #expect(s.laps(.lastWeek).isEmpty)
        #expect(s.halfwayTime(.lastWeek) == nil)
    }

    // MARK: 表示の値と行の文言

    /// 0.0 に丸まる負の値は「0.0」（「-0.0」にしない）。マイナスは差と同じ「−」
    @Test func pointNumbersNeverShowMinusZero() {
        #expect(RaceChartLayout.pointNumber(-0.04) == "0.0")
        #expect(RaceChartLayout.pointNumber(-0.05) == "−0.1")
        #expect(RaceChartLayout.pointNumber(-1.25) == "−1.3")
        #expect(RaceChartLayout.pointNumber(0.04) == "0.0")
        #expect(RaceChartLayout.pointNumber(9.46) == "9.5")
        #expect(RaceChart.pointText(-0.04) == "0.0pt")
        #expect(RaceChart.pointText(-2) == "−2.0pt")
        #expect(RaceChartLayout.signedPoints(-0.04) == "0.0pt")
    }

    /// 一覧の行の文言：1行目「10:00–12:00」と「+1.6pt」、2行目「9.5pt・先週 7.9pt」（目標なら「目標」、今日なら「今日」で差は今日−この日）
    @Test func lapRowTexts() {
        let lap = Lap(interval: DateInterval(start: jst("2026-10-19T10:00"), duration: Laps.length), mine: 0, opponent: 0,
                      isCurrent: false, minePoints: 9.46, opponentPoints: 7.94)
        #expect(RaceLapList.titleText(lap) == "10:00–12:00")
        #expect(RaceLapList.gapText(lap, rival: .opponent(.lastWeek)) == "+1.6pt")
        #expect(RaceLapList.detailText(lap, rival: .opponent(.lastWeek)) == "9.5pt・先週 7.9pt")
        #expect(RaceLapList.detailText(lap, rival: .opponent(.goal)) == "9.5pt・目標 7.9pt")
        #expect(RaceLapList.detailText(lap, rival: .today) == "9.5pt・今日 7.9pt")
        #expect(RaceLapList.gapText(lap, rival: .today) == "−1.6pt")
        var current = lap
        current.isCurrent = true
        #expect(RaceLapList.titleText(current) == "10:00–12:00（途中）")
        let negative = Lap(interval: lap.interval, mine: 0, opponent: 0, isCurrent: false, minePoints: -0.04, opponentPoints: -1.2)
        #expect(RaceLapList.detailText(negative, rival: .opponent(.lastWeek)) == "0.0pt・先週 −1.2pt")
        #expect(RaceLapList.gapText(negative, rival: .opponent(.lastWeek)) == "+1.2pt")
    }

    // MARK: 4:00 をまたぐ

    /// 翌3:59 は最後の区間（翌2:00–翌4:00）の途中で一覧に入り、流すと線の先が翌4:00 に着くまで足さない。
    /// 翌4:00 は新しい日で、区間はまだない（一覧は空）
    @Test func lastSectionAroundFourAm() throws {
        let mine = [seg("02:30", "03:30", day: "2026-10-20")]
        let late = Laps.make(mine: mine, opponent: { _ in 0 }, minePoints: tenMinutes(mine), opponentPoints: { _ in 0 },
                             dayStart: dayStart, now: jst("2026-10-20T03:59"))
        let last = try #require(Laps.listed(late, replayHead: nil).last)
        #expect(last.interval.start == jst("2026-10-20T02:00"))
        #expect(last.isCurrent)
        #expect(last.minePoints.isApprox(6.0))
        #expect(!Laps.listed(late, replayHead: jst("2026-10-20T03:59")).contains { $0.interval.start == jst("2026-10-20T02:00") })
        // 過ぎた日（今が翌4:00）は最後の区間も終わっていて、線の先が翌4:00 に着いたら足す
        let whole = Laps.make(mine: mine, opponent: { _ in 0 }, minePoints: tenMinutes(mine), opponentPoints: { _ in 0 },
                              dayStart: dayStart, now: jst("2026-10-20T04:00"))
        #expect(whole.last?.isCurrent == false)
        #expect(Laps.listed(whole, replayHead: jst("2026-10-20T04:00")).last?.interval.start == jst("2026-10-20T02:00"))
        #expect(Laps.listed(whole, replayHead: jst("2026-10-20T03:59")).last?.interval.start != jst("2026-10-20T02:00"))
        // 新しい日の 4:00 ちょうどは区間がなく、一覧も空
        let next = Laps.make(mine: mine, opponent: { _ in 0 }, minePoints: tenMinutes(mine), opponentPoints: { _ in 0 },
                             dayStart: jst("2026-10-20T04:00"), now: jst("2026-10-20T04:00"))
        #expect(Laps.listed(next, replayHead: nil).isEmpty)
    }

    // MARK: 大きさ（GHO-13）

    /// カードの中のグラフの割合：ふつうは約6割、文字の大きい設定は5割
    @Test func graphShareOfTheCard() {
        #expect(RaceChartLayout.graphShare(isAccessibilitySize: false) == 0.6)
        #expect(RaceChartLayout.graphShare(isAccessibilitySize: true) == 0.5)
    }

    /// ホームのカードの大きさ：表は横幅いっぱい（最大440）で縦は横の1.25倍（文字が大きいと正方形・最大320）、
    /// 縦の上限を超えるなら縦横比のまま縮める。裏は横幅いっぱい（最大440）で、開始ボタンのすぐ上まで
    @Test func homeCardSize() {
        let container = CGSize(width: 402, height: 640)
        let front = HomeView.cardSize(container: container, headerHeight: 36, flipped: false,
                                      isAccessibilitySize: false, maxCardHeight: 600)
        #expect(front == CGSize(width: 362, height: 452.5))
        let small = HomeView.cardSize(container: container, headerHeight: 36, flipped: false,
                                      isAccessibilitySize: false, maxCardHeight: 400)
        #expect(small == CGSize(width: 320, height: 400))
        let large = HomeView.cardSize(container: container, headerHeight: 36, flipped: false,
                                      isAccessibilitySize: true, maxCardHeight: 600)
        #expect(large == CGSize(width: 320, height: 320))
        // 裏：640 − 見出し36 − 間24 − 下の余白12
        let back = HomeView.cardSize(container: container, headerHeight: 36, flipped: true,
                                     isAccessibilitySize: false, maxCardHeight: 400)
        #expect(back == CGSize(width: 362, height: 568))
        // 文字が大きくても裏は同じに伸ばす。iPad のように広い画面でも横は440まで
        let wide = HomeView.cardSize(container: CGSize(width: 800, height: 900), headerHeight: 50, flipped: true,
                                     isAccessibilitySize: true, maxCardHeight: 400)
        #expect(wide == CGSize(width: 440, height: 814))
    }
}
