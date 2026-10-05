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

    // MARK: 開いたときの動き（2026-10-05 から、3時間の窓のまま直前2時間の線が今まで伸びる）

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

    /// 窓は止まったときの3時間のまま動かず、線の先が今の2時間前から今まで伸びる
    @Test func introGrowsTheLastTwoHoursInTheHomeWindow() {
        let layout = layout("2026-10-19T15:20")
        #expect(layout.introFrame(0).head == jst("2026-10-19T13:20"))
        #expect(layout.introFrame(1).head == jst("2026-10-19T15:20"))
        for progress in stride(from: 0.0, through: 1.0, by: 0.1) {
            #expect(layout.introFrame(progress).domain == layout.homeWindow)
        }
    }

    /// 4:00〜6:00 はまだ2時間たっていないので 4:00 から。6:01 からは2時間前から
    @Test func introStartsAtDayStartBeforeSix() {
        #expect(layout("2026-10-19T04:01").introFrame(0).head == jst("2026-10-19T04:00"))
        #expect(layout("2026-10-19T05:00").introFrame(0).head == jst("2026-10-19T04:00"))
        #expect(layout("2026-10-19T06:00").introFrame(0).head == jst("2026-10-19T04:00"))
        #expect(layout("2026-10-19T06:01").introFrame(0).head == jst("2026-10-19T04:01"))
        #expect(layout("2026-10-20T03:59").introFrame(0).head == jst("2026-10-20T01:59"))
        #expect(layout("2026-10-20T03:59").introFrame(1).domain == range("2026-10-20T01:00", "2026-10-20T04:00"))
    }

    /// 2時間ぶんで1.5秒。2時間たっていないときは伸びる長さに合わせて短く、最短0.5秒
    @Test func introSecondsFollowTheGrowingLength() {
        #expect(layout("2026-10-19T15:20").introSeconds.isApprox(1.5))
        #expect(layout("2026-10-19T06:00").introSeconds.isApprox(1.5))
        #expect(layout("2026-10-20T03:59").introSeconds.isApprox(1.5))
        #expect(layout("2026-10-19T05:00").introSeconds.isApprox(0.75))
        #expect(layout("2026-10-19T04:20").introSeconds.isApprox(0.5))
        #expect(layout("2026-10-19T04:01").introSeconds.isApprox(0.5))
    }

    @Test func introHeadNeverGoesBack() {
        let layout = layout("2026-10-19T15:20")
        let heads = stride(from: 0.0, through: 1.0, by: 0.05).map { layout.introFrame($0).head }
        #expect(heads == heads.sorted())
    }

    /// だんだんゆっくり：同じ時間で進む量が少しずつ減る
    @Test func introSlowsDownTowardNow() {
        let layout = layout("2026-10-19T16:00")
        let heads = stride(from: 0.0, through: 1.0, by: 0.1).map { layout.introFrame($0).head }
        let steps = zip(heads.dropFirst(), heads).map { $0.timeIntervalSince($1) }
        #expect(steps == steps.sorted(by: >))
        #expect(steps.first! > steps.last! * 5)
    }

    // MARK: 1日を流す（2026-10-05、4:00 から1時間＝1秒、最後の1時間は2秒でだんだん遅く）

    /// 歩いている間も3時間。線の先は止まったときと同じ位置（2時間前〜1時間先の境目）
    @Test func walkWindowIsThreeHoursWithTheHeadLikeHome() {
        let layout = layout("2026-10-19T15:20")
        #expect(layout.walkWindow(head: jst("2026-10-19T04:00")) == range("2026-10-19T04:00", "2026-10-19T07:00"))
        #expect(layout.walkWindow(head: jst("2026-10-19T12:00")) == range("2026-10-19T10:00", "2026-10-19T13:00"))
        #expect(layout.walkWindow(head: jst("2026-10-20T03:50")) == range("2026-10-20T01:00", "2026-10-20T04:00"))
        #expect(layout.walkWindow(head: layout.now) == layout.homeWindow)
    }

    /// 1時間たったあとは「たった時間＋1秒」。1時間より前は、たった時間の2倍（最短1秒）
    @Test func replaySecondsAreOneSecondPerHour() {
        #expect(layout("2026-10-19T16:00").replaySeconds.isApprox(13))
        #expect(layout("2026-10-19T05:00").replaySeconds.isApprox(2))
        #expect(layout("2026-10-19T04:45").replaySeconds.isApprox(1.5))
        #expect(layout("2026-10-19T04:30").replaySeconds.isApprox(1))
        #expect(layout("2026-10-19T04:10").replaySeconds.isApprox(1))
        #expect(layout("2026-10-20T03:59").replaySeconds.isApprox(24 + 59.0 / 60, tolerance: 0.001))
    }

    /// 4:00 から3時間の幅で追いかけ、今に着いたら止まったときの3時間
    @Test func replayStartsAtDayStartAndEndsAtHome() {
        let layout = layout("2026-10-19T16:00")
        #expect(layout.replayFrame(0).head == jst("2026-10-19T04:00"))
        #expect(layout.replayFrame(0).domain == range("2026-10-19T04:00", "2026-10-19T07:00"))
        #expect(layout.replayFrame(1).head == jst("2026-10-19T16:00"))
        #expect(layout.replayFrame(1).domain == layout.homeWindow)
        for progress in stride(from: 0.0, through: 1.0, by: 0.1) {
            let domain = layout.replayFrame(progress).domain
            #expect(domain.upperBound.timeIntervalSince(domain.lowerBound) == 3 * 3600)
        }
    }

    /// 1秒で1時間ずつ同じ速さで進み、最後の1時間（2秒）だけだんだん遅くなる
    @Test func replayMovesOneHourPerSecondThenSlowsDown() {
        let layout = layout("2026-10-19T16:00")
        let seconds = layout.replaySeconds
        func head(at second: Double) -> Date { layout.replayFrame(second / seconds).head }
        #expect(abs(head(at: 5).timeIntervalSince(jst("2026-10-19T09:00"))) < 1)
        #expect(abs(head(at: 11).timeIntervalSince(jst("2026-10-19T15:00"))) < 1)
        // 最後の1時間に入るところで速さが急に変わらない（0.1秒で約6分）
        #expect(abs(head(at: 11.1).timeIntervalSince(head(at: 11)) - 360) < 10)
        // 最後の2秒はだんだん遅く
        let tail = stride(from: 11.0, through: 13.0, by: 0.25).map { head(at: $0) }
        let steps = zip(tail.dropFirst(), tail).map { $0.timeIntervalSince($1) }
        #expect(steps == steps.sorted(by: >))
    }

    /// 1時間たっていない日は全体がだんだん遅くなる部分
    @Test func replayBeforeFiveIsAllSlowingDown() {
        let layout = layout("2026-10-19T04:30")
        #expect(layout.replayFrame(0).head == jst("2026-10-19T04:00"))
        #expect(abs(layout.replayFrame(0.5).head.timeIntervalSince(jst("2026-10-19T04:22:30"))) < 1)
        #expect(layout.replayFrame(1).head == jst("2026-10-19T04:30"))
    }

    @Test func replayHeadNeverGoesBack() {
        let layout = layout("2026-10-20T03:59")
        let heads = stride(from: 0.0, through: 1.0, by: 0.02).map { layout.replayFrame($0).head }
        #expect(heads == heads.sorted())
    }

    // MARK: 慣性（2026-10-05、指を離しても勢いで滑ってだんだん止まる）

    /// はじいた速さ（pt/秒）で約0.5秒ぶん進む。幅300pt＝3時間なので、300pt/秒なら150pt＝1時間30分
    @Test func glideTravelsHalfASecondOfVelocity() {
        let layout = layout("2026-10-19T15:20")
        let start = jst("2026-10-19T13:20")
        #expect(layout.glided(from: start, velocity: 300, plotWidth: 300, elapsed: 0) == start)
        let end = layout.glided(from: start, velocity: 300, plotWidth: 300, elapsed: 10)
        #expect(abs(end.timeIntervalSince(jst("2026-10-19T11:50"))) < 1)
        // 左へはじくと先の時刻へ
        let ahead = layout.glided(from: start, velocity: -300, plotWidth: 300, elapsed: 10)
        #expect(abs(ahead.timeIntervalSince(jst("2026-10-19T14:50"))) < 1)
    }

    /// だんだん遅くなる：最初の0.25秒で、次の0.25秒より多く進む
    @Test func glideSlowsDown() {
        let layout = layout("2026-10-19T15:20")
        let start = jst("2026-10-19T13:20")
        let positions = [0, 0.25, 0.5].map { layout.glided(from: start, velocity: 300, plotWidth: 300, elapsed: $0) }
        let first = start.timeIntervalSince(positions[1])
        let second = positions[1].timeIntervalSince(positions[2])
        #expect(first > 0)
        #expect(first > second * 1.5)
    }

    /// 4:00〜翌4:00 の端で止まる（跳ね返らない）
    @Test func glideStopsAtTheDayEdges() {
        let layout = layout("2026-10-19T15:20")
        let start = jst("2026-10-19T13:20")
        #expect(layout.glided(from: start, velocity: 100_000, plotWidth: 300, elapsed: 10) == jst("2026-10-19T04:00"))
        #expect(layout.glided(from: start, velocity: -100_000, plotWidth: 300, elapsed: 10) == jst("2026-10-20T01:00"))
    }

    /// 残りが半ポイントを切ったら終わり。ゆっくり離したときは滑らない
    @Test func glideEndsWhenTheRestIsTiny() {
        #expect(!RaceChartLayout.glideIsOver(velocity: 300, elapsed: 0))
        #expect(!RaceChartLayout.glideIsOver(velocity: -300, elapsed: 1))
        #expect(RaceChartLayout.glideIsOver(velocity: 300, elapsed: 5))
        #expect(RaceChartLayout.glideIsOver(velocity: 0.5, elapsed: 0))
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
