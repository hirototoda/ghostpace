import Foundation
import Testing
@testable import FocusApp

/// ホームの裏とその日のグラフのラップの一覧（GHO-06・13、ANA-05、2026-10-12）：
/// ［▶］で流している間は空から始め、線の先が2時間の区切りを過ぎるたびに、その区間を最後まで数えた行を1行ずつ足す。
/// 止める・流し終わると今の一覧（今の区間の「途中」まで）に戻る
@MainActor
struct RaceLapListTests {
    private let dayStart = jst("2026-10-19T04:00")

    private func seg(_ from: String, _ to: String, day: String = "2026-10-19") -> TimeSegment {
        TimeSegment(start: jst("\(day)T\(from)"), end: jst("\(day)T\(to)"), countsAsFocus: true)
    }

    /// 自分：4:30–5:00・8:30–9:30・10:00–11:15。相手：9:00–10:00・11:00–11:30。今は 11:15（10:00–12:00 の途中）。
    /// 6:00–8:00 は両者とも集中していない
    private var laps: [Lap] {
        let opponent = [seg("09:00", "10:00"), seg("11:00", "11:30")]
        return Laps.make(mine: [seg("04:30", "05:00"), seg("08:30", "09:30"), seg("10:00", "11:15")],
                         opponent: { opponent.focusSeconds(until: $0) }, dayStart: dayStart, now: jst("2026-10-19T11:15"))
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
        #expect(eight.mine == 60 * 60)
        #expect(eight.opponent == 60 * 60)
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
        #expect(ten.mine == 60 * 60)
        #expect(ten.opponent == 60 * 60)  // 2時間を半分の速さで
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
        #expect(RaceRival.today.lapDiff(try #require(end.first)) == -12 * 60)
        // 止めると今の区間（途中）まで
        #expect(Laps.listed(laps, replayHead: nil).last?.isCurrent == true)
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
