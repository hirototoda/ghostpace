import Foundation
import Testing
@testable import FocusApp

/// 裏のポイントのグラフの範囲と動き（GHO-13、2026-10-03 今のまわりの3時間）。
struct RaceChartLayoutTests {
    /// 10/19 4:00〜10/20 4:00 の日の、`now` の時刻での形
    private func layout(_ now: String) -> RaceChartLayout {
        RaceChartLayout(dayStart: jst("2026-10-19T04:00"), dayEnd: jst("2026-10-20T04:00"), now: jst(now))
    }

    private func range(_ from: String, _ to: String) -> ClosedRange<Date> { jst(from)...jst(to) }

    // MARK: 止まったときの3時間（今の2時間前〜1時間先）

    @Test func homeWindowIsTwoHoursBeforeToOneHourAfter() {
        #expect(layout("2026-10-19T15:20").homeWindow == range("2026-10-19T13:20", "2026-10-19T16:20"))
    }

    /// 4:00〜翌4:00 からはみ出すときは端に寄せる
    @Test func homeWindowStaysInsideTheDay() {
        #expect(layout("2026-10-19T04:00").homeWindow == range("2026-10-19T04:00", "2026-10-19T07:00"))
        #expect(layout("2026-10-19T05:00").homeWindow == range("2026-10-19T04:00", "2026-10-19T07:00"))
        #expect(layout("2026-10-19T05:59").homeWindow == range("2026-10-19T04:00", "2026-10-19T07:00"))
        #expect(layout("2026-10-19T06:00").homeWindow == range("2026-10-19T04:00", "2026-10-19T07:00"))
        #expect(layout("2026-10-19T06:01").homeWindow == range("2026-10-19T04:01", "2026-10-19T07:01"))
        #expect(layout("2026-10-20T02:59").homeWindow == range("2026-10-20T00:59", "2026-10-20T03:59"))
        // 0:00〜3:59 は前の日の続き。翌3:00・3:59 は 翌1:00〜翌4:00
        #expect(layout("2026-10-20T03:00").homeWindow == range("2026-10-20T01:00", "2026-10-20T04:00"))
        #expect(layout("2026-10-20T03:59").homeWindow == range("2026-10-20T01:00", "2026-10-20T04:00"))
    }

    /// 開いたまま時間がたつと、今のまわりの3時間も右へ進む
    @Test func homeWindowAdvancesWithNow() {
        let base = layout("2026-10-19T15:20")
        let later = RaceChartLayout(dayStart: base.dayStart, dayEnd: base.dayEnd, now: base.now.addingTimeInterval(30 * 60))
        #expect(later.homeWindow == range("2026-10-19T13:50", "2026-10-19T16:50"))
    }

    /// 1日は 4:00〜翌4:00。3時間はずらした位置から3時間、ずらしていなければ今のまわり
    @Test func visibleRangeForWholeDayAndWindow() {
        let layout = layout("2026-10-19T15:20")
        #expect(layout.visibleRange(wholeDay: true, scrollStart: jst("2026-10-19T06:00")) == range("2026-10-19T04:00", "2026-10-20T04:00"))
        #expect(layout.visibleRange(wholeDay: false, scrollStart: nil) == layout.homeWindow)
        #expect(layout.visibleRange(wholeDay: false, scrollStart: jst("2026-10-19T06:00")) == range("2026-10-19T06:00", "2026-10-19T09:00"))
    }

    /// 指で横にずらす：右へずらす（＋）と前の時刻へ、左へずらす（−）と先の時刻へ。幅300pt＝3時間なので100pt＝1時間。4:00〜翌4:00 の端で止まる
    @Test func panMovesTheWindowAndStopsAtTheDayEdges() {
        let layout = layout("2026-10-19T15:20")
        let start = jst("2026-10-19T13:20")
        #expect(layout.panned(from: start, by: 100, plotWidth: 300) == jst("2026-10-19T12:20"))
        #expect(layout.panned(from: start, by: -50, plotWidth: 300) == jst("2026-10-19T13:50"))
        // 端で止まる
        #expect(layout.panned(from: start, by: 10_000, plotWidth: 300) == jst("2026-10-19T04:00"))
        #expect(layout.panned(from: start, by: -10_000, plotWidth: 300) == jst("2026-10-20T01:00"))
        // 幅がまだ決まっていない（0）ときは動かさない
        #expect(layout.panned(from: start, by: 100, plotWidth: 0) == start)
    }

    // MARK: 開いたときの動き（3時間の幅で 4:00 から追いかけ、だんだんゆっくり今に着く）

    /// 4:00 ちょうどはまだ線がないので動かない。1分でも過ぎたら動く
    @Test func introPlaysOnlyAfterTheDayStarts() {
        #expect(!layout("2026-10-19T04:00").playsIntro)
        #expect(layout("2026-10-19T04:01").playsIntro)
        #expect(layout("2026-10-20T03:59").playsIntro)
    }

    /// 起動・ほかのアプリから戻ってから最初の1回だけ。視差効果を減らす設定・1日で始めるときは動かない
    @Test func introPlaysOnlyTheFirstTimeAndNotWithReduceMotion() {
        let layout = layout("2026-10-19T15:20")
        #expect(layout.playsIntro(alreadyPlayed: false, reduceMotion: false, wholeDay: false))
        #expect(!layout.playsIntro(alreadyPlayed: true, reduceMotion: false, wholeDay: false))
        #expect(!layout.playsIntro(alreadyPlayed: false, reduceMotion: true, wholeDay: false))
        #expect(!layout.playsIntro(alreadyPlayed: false, reduceMotion: false, wholeDay: true))
        #expect(!self.layout("2026-10-19T04:00").playsIntro(alreadyPlayed: false, reduceMotion: false, wholeDay: false))
    }

    /// 動く時間は 4:00 からの時間に合わせて2〜4.5秒（12時間で4秒）
    @Test func introSecondsFollowElapsedHours() {
        #expect(layout("2026-10-19T04:01").introSeconds.isApprox(2.0, tolerance: 0.01))
        #expect(layout("2026-10-19T07:00").introSeconds.isApprox(2.5))
        #expect(layout("2026-10-19T16:00").introSeconds.isApprox(4.0))
        #expect(layout("2026-10-19T19:00").introSeconds.isApprox(4.5))
        #expect(layout("2026-10-20T03:59").introSeconds.isApprox(4.5))
    }

    /// 歩いている間も3時間。線の先は止まったときと同じ位置（2時間前〜1時間先の境目）
    @Test func walkWindowIsThreeHoursWithTheHeadLikeHome() {
        let layout = layout("2026-10-19T15:20")
        #expect(layout.walkWindow(head: jst("2026-10-19T04:00")) == range("2026-10-19T04:00", "2026-10-19T07:00"))
        #expect(layout.walkWindow(head: jst("2026-10-19T12:00")) == range("2026-10-19T10:00", "2026-10-19T13:00"))
        #expect(layout.walkWindow(head: jst("2026-10-20T03:50")) == range("2026-10-20T01:00", "2026-10-20T04:00"))
        #expect(layout.walkWindow(head: layout.now) == layout.homeWindow)
    }

    @Test func introStartsAtDayStartAndEndsAtHome() {
        let layout = layout("2026-10-19T15:20")
        let start = layout.introFrame(0)
        #expect(start.head == jst("2026-10-19T04:00"))
        #expect(start.domain == range("2026-10-19T04:00", "2026-10-19T07:00"))

        let end = layout.introFrame(1)
        #expect(end.head == jst("2026-10-19T15:20"))
        #expect(end.domain == layout.homeWindow)

        // 途中もずっと3時間の幅
        for progress in stride(from: 0.0, through: 1.0, by: 0.1) {
            let domain = layout.introFrame(progress).domain
            #expect(domain.upperBound.timeIntervalSince(domain.lowerBound) == 3 * 3600)
        }
    }

    @Test func introHeadNeverGoesBack() {
        let layout = layout("2026-10-19T15:20")
        let heads = stride(from: 0.0, through: 1.0, by: 0.05).map { layout.introFrame($0).head }
        #expect(heads == heads.sorted())
    }

    /// だんだんゆっくり：同じ時間で進む量が少しずつ減る。12時間の日は、半分の時間がたってもまだ最後の1時間に入らない
    @Test func introSlowsDownTowardNow() {
        let layout = layout("2026-10-19T16:00")
        let heads = stride(from: 0.0, through: 1.0, by: 0.1).map { layout.introFrame($0).head }
        let steps = zip(heads.dropFirst(), heads).map { $0.timeIntervalSince($1) }
        #expect(steps == steps.sorted(by: >))
        #expect(steps.first! > steps.last! * 5)
        #expect(layout.introFrame(0.5).head < jst("2026-10-19T15:00"))
    }

    // MARK: 縦の範囲

    /// 3時間は見えている線に合わせて上下に15%ずつ広げる（0から始めない）
    @Test func yDomainFitsVisibleLinesInTheWindow() {
        let domain = RaceChartLayout.yDomain(values: [15, 50, 30], wholeDay: false)
        #expect(domain.lowerBound.isApprox(9.75))
        #expect(domain.upperBound.isApprox(55.25))
    }

    /// 線が平らでも4pt（＋余白）の高さを取る。0より下になるなら上へずらす
    @Test func yDomainHasAMinimumHeightAndNoNegative() {
        let flat = RaceChartLayout.yDomain(values: [20, 20], wholeDay: false)
        #expect(flat.lowerBound.isApprox(17.4))
        #expect(flat.upperBound.isApprox(22.6))
        let nearZero = RaceChartLayout.yDomain(values: [0.1, 0.2], wholeDay: false)
        #expect(nearZero.lowerBound.isApprox(0))
        #expect(nearZero.upperBound.isApprox(5.2))
    }

    @Test func yDomainForWholeDayStartsAtZero() {
        let domain = RaceChartLayout.yDomain(values: [12, 89], wholeDay: true)
        #expect(domain.lowerBound.isApprox(0))
        #expect(domain.upperBound.isApprox(93.45))
        #expect(RaceChartLayout.yDomain(values: [0], wholeDay: true).upperBound.isApprox(1))
    }

    /// 点が1つでも、余白で0より下になる値でも、つぶれず0から始まる
    @Test func yDomainWithASinglePointOrNearZero() {
        let single = RaceChartLayout.yDomain(values: [10], wholeDay: false)
        #expect(single.lowerBound.isApprox(7.4))
        #expect(single.upperBound.isApprox(12.6))
        let low = RaceChartLayout.yDomain(values: [0, 8], wholeDay: false)
        #expect(low.lowerBound.isApprox(0))
        #expect(low.upperBound.isApprox(10.4))
    }

    /// 朝4:00すぐに開けて点がマイナスになったときだけ、0より下も出す（GHO-14、2026-10-03）
    @Test func yDomainShowsNegativePoints() {
        // 3時間：−1〜3 → 高さ4、余白0.6 → −1.6〜3.6（上へずらさない）
        let window = RaceChartLayout.yDomain(values: [-1, 3], wholeDay: false)
        #expect(window.lowerBound.isApprox(-1.6))
        #expect(window.upperBound.isApprox(3.6))
        // 1日：一番下の点から少し余白
        let whole = RaceChartLayout.yDomain(values: [-1, 89], wholeDay: true)
        #expect(whole.lowerBound < -1)
        #expect(whole.upperBound > 89)
        // 全部マイナスでも点が枠の中に入る
        let allNegative = RaceChartLayout.yDomain(values: [-3, -1], wholeDay: true)
        #expect(allNegative.lowerBound < -3)
        #expect(allNegative.upperBound > -1)
    }

    @Test func yDomainWithoutValues() {
        #expect(RaceChartLayout.yDomain(values: [], wholeDay: false) == 0...10)
    }

    // MARK: 線を途中で切る

    @Test func cutAddsAnInterpolatedPointAtTheHead() {
        let values = [
            RaceCurve.Value(date: jst("2026-10-19T09:00"), value: 10),
            RaceCurve.Value(date: jst("2026-10-19T09:05"), value: 12),
            RaceCurve.Value(date: jst("2026-10-19T09:10"), value: 20),
        ]
        let cut = RaceChartLayout.cut(values, at: jst("2026-10-19T09:07:30"))
        #expect(cut.count == 3)
        #expect(cut.last?.date == jst("2026-10-19T09:07:30"))
        #expect(cut.last?.value.isApprox(16) == true)
        // 点の上ちょうどなら足さない
        #expect(RaceChartLayout.cut(values, at: jst("2026-10-19T09:05")).count == 2)
        // 最後の点より後ろなら全部（足さない）
        #expect(RaceChartLayout.cut(values, at: jst("2026-10-19T10:00")) == values)
        // 最初より前なら何も描かない
        #expect(RaceChartLayout.cut(values, at: jst("2026-10-19T08:00")).isEmpty)
    }

    // MARK: 上の行の差

    /// 相手のポイントがない日は差を出さない。丸めて0なら前向きな色
    @Test func gapIsHiddenWithoutOpponentAndZeroCountsAsAhead() {
        #expect(RaceChartLayout.gap(mine: 37.7, theirs: nil) == nil)
        #expect(RaceChartLayout.gap(mine: 37.7, theirs: 47.7)?.isApprox(-10) == true)
        #expect(RaceChartLayout.isAhead(3))
        #expect(RaceChartLayout.isAhead(-0.04))
        #expect(!RaceChartLayout.isAhead(-0.05))
        #expect(!RaceChartLayout.isAhead(-10))
    }

    @Test func gapTextShowsSignAndOneDecimal() {
        #expect(RaceChartLayout.gapText(-10) == "差 −10.0pt")
        #expect(RaceChartLayout.gapText(3.25) == "差 +3.3pt")
        #expect(RaceChartLayout.gapText(0.04) == "差 0.0pt")
        #expect(RaceChartLayout.gapText(-0.04) == "差 0.0pt")
    }
}
