import Foundation
import Testing
@testable import FocusApp

/// 2026-10-11 の自己ベストの手直し：先週・先月に代える（ANA-06）、今日を相手にしたその日のグラフ（ANA-05）、
/// 自分の線の色（GHO-13）、流している間の上の行（GHO-13）、ホームの帯はタイマーのタブだけ（GHO-06・16）
@MainActor
struct BestPolishTests {
    private func model(_ t: TestStore, settings: MemorySettings = MemorySettings()) -> AppModel {
        settings.didShowBlockingIntro = true
        return AppModel(store: t.store, clock: t.clock, timeZone: { tokyo }, settings: settings,
                        blocking: FakeBlocking(), blockStore: MemoryBlockStore(), blockLog: MemoryBlockEventLog())
    }

    /// タイマーを `from`〜`to` で記録する（カテゴリは `category`、既定は勉強）
    private func session(_ t: TestStore, _ category: CategoryOption, from: String, to: String) throws {
        let now = t.clock.now()
        t.clock.set(jst(from))
        _ = try t.store.start(StartRequest(category: category, timeZone: tokyo))
        t.clock.set(jst(to))
        let running = try #require(try t.store.runningSession())
        _ = try t.store.end(id: running.id, reportedEnd: nil)
        t.clock.set(now)
    }

    private func focus(_ c: [CategoryOption]) throws -> CategoryOption { try #require(c.first { $0.countsAsFocus }) }
    private func detox(_ c: [CategoryOption]) throws -> CategoryOption { try #require(c.first { !$0.countsAsFocus && !$0.isUnblock }) }

    // MARK: 先週・先月に代える（ANA-06）

    /// 月曜（4:00 から）は今週に記録のある日がないので先週。先週も空なら今週のまま。2週前まではさかのぼらない
    @Test func weekFallsBackToLastWeekOnMonday() {
        let monday = jst("2026-10-19T04:00")
        let range = BestPeriods.range(.week, today: monday, calendar: tokyoCalendar, recordDays: [jst("2026-10-18T04:00")])
        #expect(range == BestRange(start: jst("2026-10-12T04:00"), end: monday, isFallback: true))
        // 先週の最初の日（月曜）だけでも先週
        #expect(BestPeriods.range(.week, today: monday, calendar: tokyoCalendar,
                                  recordDays: [jst("2026-10-12T04:00")]).isFallback)
        // 2週前だけ → 今週のまま（まだ記録なし）
        let none = BestPeriods.range(.week, today: monday, calendar: tokyoCalendar, recordDays: [jst("2026-10-11T04:00")])
        #expect(none == BestRange(start: monday, end: monday))
        #expect(!none.contains(jst("2026-10-11T04:00")))
    }

    /// 火曜：月曜が記録のある日なら今週に戻る。月曜に記録がなければ火曜も先週
    @Test func weekReturnsOnceThisWeekHasARecord() {
        let tuesday = jst("2026-10-20T04:00")
        let back = BestPeriods.range(.week, today: tuesday, calendar: tokyoCalendar,
                                     recordDays: [jst("2026-10-18T04:00"), jst("2026-10-19T04:00")])
        #expect(back == BestRange(start: jst("2026-10-19T04:00"), end: tuesday))
        let still = BestPeriods.range(.week, today: tuesday, calendar: tokyoCalendar, recordDays: [jst("2026-10-18T04:00")])
        #expect(still == BestRange(start: jst("2026-10-12T04:00"), end: jst("2026-10-19T04:00"), isFallback: true))
    }

    /// 1日は先月。今週と今月は別々：月曜かつ1日なら両方、今週だけ空なら今週だけ代える。全期間は代えない
    @Test func monthAndWeekAreDecidedSeparately() {
        // 2027-02-01 は月曜かつ1日
        let first = jst("2027-02-01T04:00")
        let days = [jst("2027-01-31T04:00")]
        #expect(BestPeriods.range(.month, today: first, calendar: tokyoCalendar, recordDays: days)
                == BestRange(start: jst("2027-01-01T04:00"), end: first, isFallback: true))
        #expect(BestPeriods.range(.week, today: first, calendar: tokyoCalendar, recordDays: days)
                == BestRange(start: jst("2027-01-25T04:00"), end: first, isFallback: true))
        // 2026-11-02 は月曜（今月は 11/1 があるので今月のまま）
        let monday = jst("2026-11-02T04:00")
        let novFirst = [jst("2026-11-01T04:00")]
        #expect(!BestPeriods.range(.month, today: monday, calendar: tokyoCalendar, recordDays: novFirst).isFallback)
        #expect(BestPeriods.range(.week, today: monday, calendar: tokyoCalendar, recordDays: novFirst).isFallback)
        #expect(BestPeriods.range(.all, today: monday, calendar: tokyoCalendar, recordDays: []) == BestRange(start: nil, end: monday))
    }

    /// 月曜の自己ベスト：今週の代わりに先週の日でベスト・理論ベスト・今日と比べる・ラップ表・ベスト10を出す
    @Test func mondayUsesLastWeekForEverything() throws {
        let t = try TestStore(now: jst("2026-10-19T12:00"))
        let c = try t.seeded()
        try session(t, try focus(c), from: "2026-10-11T09:00", to: "2026-10-11T15:00")  // 2週前の日曜（入らない）
        try session(t, try focus(c), from: "2026-10-13T09:00", to: "2026-10-13T10:00")  // 先週の火曜
        try session(t, try focus(c), from: "2026-10-18T09:00", to: "2026-10-18T11:00")  // 先週の日曜（ベスト）
        try session(t, try focus(c), from: "2026-10-19T08:00", to: "2026-10-19T09:00")  // 今日（入らない）
        let m = model(t)
        let week = try #require(m.periodBests()[.week])
        #expect(week.isFallback)
        #expect(week.pointsDay == jst("2026-10-18T04:00"))
        #expect(week.focus?.focusDay == jst("2026-10-18T04:00"))
        #expect(week.focus?.focusSeconds == 2 * 3600)
        #expect(m.periodBests()[.month]?.isFallback == false)
        #expect(m.periodBests()[.all]?.isFallback == false)
        #expect(m.topDays(period: .week).map(\.dayStart) == [jst("2026-10-18T04:00"), jst("2026-10-13T04:00")])
        let average = try #require(m.lapComparison(target: .average, period: .week))
        #expect(average.days == 2)
        #expect(m.theoreticalBest(period: .week) != nil)
        let bestDay = try #require(m.lapComparison(target: .bestDay, period: .week))
        let sunday = try #require(m.daySnapshot(of: jst("2026-10-18T04:00")))
        #expect(bestDay.theirsAtSameTime.isApprox(sunday.myPoints(until: jst("2026-10-18T12:00"))))
    }

    /// 区切り 22:00：日曜 21:59 はまだ日曜（今日）。22:00 に月曜の日になると、さっきまでの今日（日曜）を含む先週に代わる。
    /// 月曜の区切り（22:00）を過ぎて月曜が記録のある日になると今週に戻る（開いたままでも数え直しで切り替わる。週は日の名前で分ける、2026-10-21）
    @Test func fallbackFollowsTheDayBoundary() throws {
        let t = try TestStore(now: jst("2026-10-18T21:59"))
        let c = try t.seeded()
        try t.store.setBoundary(endMinutes: 22 * 60, fromDayKey: "2026-10-01", timeZone: tokyo)
        try session(t, try focus(c), from: "2026-10-18T09:00", to: "2026-10-18T10:00")  // 日曜
        let m = model(t)
        // 21:59 は日曜が今日で、今週（10/12〜）にほかの記録はなく、その前の週も空
        #expect(m.periodBests()[.week] == nil)
        t.clock.set(jst("2026-10-18T22:00"))
        #expect(m.periodBests()[.week]?.isFallback == true)
        #expect(m.periodBests()[.week]?.pointsDay == jst("2026-10-17T22:00"))
        try session(t, try focus(c), from: "2026-10-19T09:00", to: "2026-10-19T09:30")  // 月曜
        t.clock.set(jst("2026-10-19T21:59"))
        #expect(m.periodBests()[.week]?.isFallback == true)
        t.clock.set(jst("2026-10-19T22:00"))
        #expect(m.periodBests()[.week]?.isFallback == false)
        #expect(m.periodBests()[.week]?.pointsDay == jst("2026-10-18T22:00"))
        #expect(m.topDays(period: .week).map(\.dayStart) == [jst("2026-10-18T22:00")])
    }

    /// 1日は先月。先月にも記録がなければ「まだ記録なし」（nil）で、比べる相手もベスト10も出さない
    @Test func firstOfMonthUsesLastMonthOrNothing() throws {
        let t = try TestStore(now: jst("2026-11-01T12:00"))
        let c = try t.seeded()
        try session(t, try focus(c), from: "2026-09-30T09:00", to: "2026-09-30T10:00")  // 2か月前（入らない）
        let m = model(t)
        #expect(m.periodBests()[.month] == nil)
        #expect(m.lapComparison(target: .bestDay, period: .month) == nil)
        #expect(m.topDays(period: .month).isEmpty)
        try session(t, try focus(c), from: "2026-10-05T09:00", to: "2026-10-05T10:00")
        #expect(m.periodBests()[.month]?.isFallback == true)
        #expect(m.periodBests()[.month]?.pointsDay == jst("2026-10-05T04:00"))
        #expect(m.topDays(period: .month).map(\.dayStart) == [jst("2026-10-05T04:00")])
    }

    /// 月曜かつ1日（2027-02-01）：今週も今月も記録がないので、先週と先月の両方に代わる（別々に決める）
    @Test func mondayThatIsTheFirstFallsBackTwice() throws {
        let t = try TestStore(now: jst("2027-02-01T12:00"))
        let c = try t.seeded()
        try session(t, try focus(c), from: "2027-01-10T09:00", to: "2027-01-10T14:00")  // 先月（先週ではない）
        try session(t, try focus(c), from: "2027-01-26T09:00", to: "2027-01-26T10:00")  // 先週の火曜
        let m = model(t)
        let week = try #require(m.periodBests()[.week])
        let month = try #require(m.periodBests()[.month])
        #expect(week.isFallback && month.isFallback)
        #expect(week.pointsDay == jst("2027-01-26T04:00"))
        #expect(month.pointsDay == jst("2027-01-10T04:00"))
        #expect(m.topDays(period: .week).map(\.dayStart) == [jst("2027-01-26T04:00")])
        #expect(m.topDays(period: .month).count == 2)
    }

    // MARK: 今日を相手にしたその日のグラフ（ANA-05）

    /// 自己ベストから開いた過ぎた日のグラフ：相手は今日。今日の線は今（4:00 からの経過で揃えた時刻）で止まる
    @Test func pastDayAgainstToday() throws {
        let t = try TestStore(now: jst("2026-10-22T15:20"))
        let c = try t.seeded()
        try session(t, try focus(c), from: "2026-10-13T09:00", to: "2026-10-13T13:00")
        try session(t, try focus(c), from: "2026-10-22T09:00", to: "2026-10-22T10:30")
        let m = model(t)
        let day = jst("2026-10-13T04:00")
        let past = try #require(m.daySnapshot(of: day, versusToday: true))
        let today = try #require(m.daySnapshot(of: jst("2026-10-22T04:00")))
        let rival = try #require(past.todayRival)
        #expect(rival.now == jst("2026-10-13T15:20"))
        // この日の 12:00 は今日の 12:00 と比べる
        #expect(past.rivalPoints(.today, at: jst("2026-10-13T12:00"))?.isApprox(today.myPoints(until: jst("2026-10-22T12:00"))) == true)
        // 今より先は今の値のまま
        #expect(past.rivalPoints(.today, at: jst("2026-10-13T20:00"))?.isApprox(today.points) == true)
        // 線：今日の線は今で止まり、先の薄い線はない
        let curve = try #require(past.raceCurves(rival: .today).first { $0.kind == .opponentPoints })
        #expect(curve.values.last?.date == jst("2026-10-13T15:20"))
        // 上の行：この日・今日の今の時刻の値、差＝今日−この日
        let header = past.raceHeader(.today, head: nil)
        #expect(header.mine.isApprox(past.myPoints(until: jst("2026-10-13T15:20"))))
        #expect(header.theirs?.isApprox(today.points) == true)
        #expect(header.gap?.isApprox(today.points - header.mine) == true)
        #expect(try #require(header.gap) < 0)
        // ふつうに開いたとき（ポイントの推移から）は今日を相手にしない
        #expect(m.daySnapshot(of: day)?.todayRival == nil)
        // 押した日が今日なら今までどおり
        #expect(m.daySnapshot(of: jst("2026-10-22T04:00"), versusToday: true)?.todayRival == nil)
    }

    /// 今日がまだ 4:00 ちょうど：今日の線は出さないが、上の行は出す
    @Test func todayAtFourHasNoLineButAHeader() throws {
        let t = try TestStore(now: jst("2026-10-22T04:00"))
        let c = try t.seeded()
        try session(t, try focus(c), from: "2026-10-13T09:00", to: "2026-10-13T10:00")
        let past = try #require(model(t).daySnapshot(of: jst("2026-10-13T04:00"), versusToday: true))
        #expect(past.todayRival?.now == jst("2026-10-13T04:00"))
        #expect(past.raceCurves(rival: .today).map(\.kind) == [.minePoints])
        let header = past.raceHeader(.today, head: nil)
        #expect(header.theirs != nil)
        #expect(header.gap != nil)
    }

    /// 旗とラップの一覧も今日と比べる：今日は今の区間まで、差＝今日−この日。中間地点は出さない（今日の1日分はまだないため）
    @Test func lapsAgainstToday() throws {
        let t = try TestStore(now: jst("2026-10-22T11:00"))
        let c = try t.seeded()
        try session(t, try focus(c), from: "2026-10-13T08:00", to: "2026-10-13T09:20")  // この日 8:00–10:00 に 80分
        try session(t, try focus(c), from: "2026-10-13T14:00", to: "2026-10-13T15:00")
        try session(t, try focus(c), from: "2026-10-22T08:00", to: "2026-10-22T09:08")  // 今日 68分
        let past = try #require(model(t).daySnapshot(of: jst("2026-10-13T04:00"), versusToday: true))
        let laps = past.rivalLaps(.today)
        #expect(laps.last?.interval.start == jst("2026-10-13T10:00"))
        #expect(laps.last?.isCurrent == true)
        let eight = try #require(laps.first { $0.interval.start == jst("2026-10-13T08:00") })
        #expect(eight.mine == 80 * 60)
        #expect(eight.opponent == 68 * 60)
        // 2026-10-12 からラップはポイント：この日 8.0pt・今日 6.8pt、差は今日−この日
        #expect(eight.minePoints.isApprox(8.0))
        #expect(eight.opponentPoints.isApprox(6.8))
        #expect(RaceRival.today.lapGap(eight).isApprox(-1.2))
        #expect(RaceRival.opponent(.lastWeek).lapGap(eight).isApprox(1.2))
        #expect(past.rivalHalfway(.today) == nil)
    }

    /// 今日のタイマーが動いている最中：時計が30分進めば、今日の値と差が増える（1分ごとの数え直しと同じ）
    @Test func todayRivalFollowsARunningTimer() throws {
        let t = try TestStore(now: jst("2026-10-22T14:00"))
        let c = try t.seeded()
        try session(t, try focus(c), from: "2026-10-13T09:00", to: "2026-10-13T12:00")
        _ = try t.store.start(StartRequest(category: try focus(c), timeZone: tokyo))  // 14:00 から動いたまま
        t.clock.set(jst("2026-10-22T14:30"))
        let m = model(t)
        let before = try #require(m.daySnapshot(of: jst("2026-10-13T04:00"), versusToday: true))
        let first = before.raceHeader(.today, head: nil)
        #expect(before.todayRival?.now == jst("2026-10-13T14:30"))
        t.clock.set(jst("2026-10-22T15:00"))
        let after = try #require(m.daySnapshot(of: jst("2026-10-13T04:00"), versusToday: true))
        let second = after.raceHeader(.today, head: nil)
        #expect(after.todayRival?.now == jst("2026-10-13T15:00"))
        // この日は 14:30〜15:00 に何もしていないので、差は今日の30分の集中のぶん（3pt）近く増える
        let gained = try #require(second.theirs) - (try #require(first.theirs))
        #expect(gained > 2.9)
        #expect(try #require(second.gap) - (try #require(first.gap)) > 2.5)
        let curve = try #require(after.raceCurves(rival: .today).first { $0.kind == .opponentPoints })
        #expect(curve.values.last?.date == jst("2026-10-13T15:00"))
    }

    /// 開いたまま 3:59 → 4:00 をまたいで取り直すと、新しい今日（4:00 から0）と比べる
    @Test func todayRivalStartsOverAtFour() throws {
        let t = try TestStore(now: jst("2026-10-23T03:59"))  // まだ 10/22
        let c = try t.seeded()
        try session(t, try focus(c), from: "2026-10-13T09:00", to: "2026-10-13T12:00")
        try session(t, try focus(c), from: "2026-10-22T09:00", to: "2026-10-22T13:00")
        let m = model(t)
        let late = try #require(m.daySnapshot(of: jst("2026-10-13T04:00"), versusToday: true))
        #expect(late.todayRival?.now == jst("2026-10-14T03:59"))
        #expect(try #require(late.raceHeader(.today, head: nil).theirs) > 15)
        t.clock.set(jst("2026-10-23T04:00"))
        let fresh = try #require(m.daySnapshot(of: jst("2026-10-13T04:00"), versusToday: true))
        #expect(fresh.todayRival?.now == jst("2026-10-13T04:00"))
        let header = fresh.raceHeader(.today, head: nil)
        #expect(header.theirs?.isApprox(0) == true)
        #expect(header.mine.isApprox(fresh.myPoints(until: jst("2026-10-13T04:00"))))
        #expect(fresh.raceCurves(rival: .today).map(\.kind) == [.minePoints])
    }

    // MARK: 流している間の上の行（GHO-13）

    /// ［▶］の線の先の時刻の値。先週の自分なら両方その時刻、止まったら（head が nil）今の値
    @Test func headerFollowsTheReplayHead() throws {
        let t = try TestStore(now: jst("2026-10-12T09:00"))
        let c = try t.seeded()
        try session(t, try focus(c), from: "2026-10-12T09:00", to: "2026-10-12T12:00")  // 先週は 9:00–12:00
        try session(t, try focus(c), from: "2026-10-19T08:00", to: "2026-10-19T09:00")  // 今日は 8:00–9:00
        t.clock.set(jst("2026-10-19T15:00"))
        // 先週の自分の点は、先週に丸1日分のブロックの記録があるときだけ出る
        let log = MemoryBlockEventLog()
        try log.append(BlockEvent(occurredAt: jst("2026-10-01T04:00"), timeZoneId: "Asia/Tokyo", kind: .started))
        let settings = MemorySettings()
        settings.didShowBlockingIntro = true
        settings.didLogBlockStart = true
        settings.lastBlockingAuthorized = true
        let blockStore = MemoryBlockStore()
        blockStore.state = BlockState(isEnabled: true)
        blockStore.selection = Data("sel".utf8)
        let m = AppModel(store: t.store, clock: t.clock, timeZone: { tokyo }, settings: settings,
                         blocking: FakeBlocking(), blockStore: blockStore, blockLog: log)
        let s = m.snapshot
        #expect(s.opponentPoints(.lastWeek, at: s.now) != nil)
        let rival = RaceRival.opponent(.lastWeek)
        let now = s.raceHeader(rival, head: nil)
        #expect(now.mine.isApprox(s.points))
        #expect(now.theirs?.isApprox(s.opponentPoints(.lastWeek, at: s.now) ?? -1) == true)
        // 9:00：今日は1時間集中し終え、先週はまだ0 → 前（色は前向き）
        let nine = s.raceHeader(rival, head: jst("2026-10-19T09:00"))
        #expect(nine.mine.isApprox(s.myPoints(until: jst("2026-10-19T09:00"))))
        #expect(nine.theirs?.isApprox(s.opponentPoints(.lastWeek, at: jst("2026-10-19T09:00")) ?? -1) == true)
        #expect(RaceChartLayout.isAhead(try #require(nine.gap)))
        // 12:00：先週が3時間で抜き返している → 後ろ（色が切り替わる）
        let noon = s.raceHeader(rival, head: jst("2026-10-19T12:00"))
        #expect(!RaceChartLayout.isAhead(try #require(noon.gap)))
        #expect(try #require(noon.gap).isApprox(noon.mine - (noon.theirs ?? 0)))
    }

    /// 今日を相手にした過ぎた日：線の先が今より後なら、今日は今の値のまま（この日は進む）
    @Test func replayAgainstTodayKeepsTodayAtNow() throws {
        let t = try TestStore(now: jst("2026-10-22T11:00"))
        let c = try t.seeded()
        try session(t, try focus(c), from: "2026-10-13T09:00", to: "2026-10-13T16:00")
        try session(t, try focus(c), from: "2026-10-22T09:00", to: "2026-10-22T10:00")
        let past = try #require(model(t).daySnapshot(of: jst("2026-10-13T04:00"), versusToday: true))
        let before = past.raceHeader(.today, head: jst("2026-10-13T10:00"))
        let later = past.raceHeader(.today, head: jst("2026-10-13T14:00"))
        let atNow = past.raceHeader(.today, head: nil)
        #expect(later.theirs?.isApprox(atNow.theirs ?? -1) == true)
        #expect(later.mine > before.mine)
        #expect(later.mine.isApprox(past.myPoints(until: jst("2026-10-13T14:00"))))
        #expect(before.theirs?.isApprox(past.rivalPoints(.today, at: jst("2026-10-13T10:00")) ?? -1) == true)
    }

    // MARK: 自分の線の色（GHO-13）

    private func snapshot(_ segments: [TimeSegment], now: String) -> HomeSnapshot {
        let dayStart = jst("2026-10-19T04:00")
        return HomeSnapshot(now: jst(now), dayStart: dayStart, dayEnd: jst("2026-10-20T04:00"), dayKey: "2026-10-19",
                            dayDate: jst("2026-10-19T00:00"), sessions: segments, planBlocks: [], isNoPlanDay: true, ghost: nil)
    }

    /// 集中のタイマー中＝集中、デトックスのカテゴリのタイマー中＝デトックス、それ以外（一時停止を含む）＝ほか。申告もタイマーと同じ
    @Test func lineActivityFollowsTheTimers() {
        let s = snapshot([
            TimeSegment(start: jst("2026-10-19T09:03"), end: jst("2026-10-19T10:00"), countsAsFocus: true),
            // 10:00–10:10 は一時停止
            TimeSegment(start: jst("2026-10-19T10:10"), end: jst("2026-10-19T10:30"), countsAsFocus: true),
            TimeSegment(start: jst("2026-10-19T11:02"), end: jst("2026-10-19T11:40"), countsAsFocus: false, detoxGroup: .exercise),
            TimeSegment(start: jst("2026-10-19T12:00"), end: jst("2026-10-19T12:30"), countsAsFocus: true, isDeclared: true),
        ], now: "2026-10-19T13:00")
        #expect(s.lineActivity(from: jst("2026-10-19T09:00"), to: jst("2026-10-19T09:03")) == .other)
        #expect(s.lineActivity(from: jst("2026-10-19T09:03"), to: jst("2026-10-19T09:05")) == .focus)
        #expect(s.lineActivity(from: jst("2026-10-19T10:00"), to: jst("2026-10-19T10:05")) == .other)
        #expect(s.lineActivity(from: jst("2026-10-19T11:02"), to: jst("2026-10-19T11:05")) == .detox)
        #expect(s.lineActivity(from: jst("2026-10-19T12:10"), to: jst("2026-10-19T12:15")) == .focus)
    }

    /// 境目は記録の時刻どおり（5分の点に丸めない）。色ごとの線は境目の点でつながる
    @Test func lineIsSplitAtTheExactBoundaries() throws {
        let s = snapshot([
            TimeSegment(start: jst("2026-10-19T09:03"), end: jst("2026-10-19T09:47"), countsAsFocus: true),
            TimeSegment(start: jst("2026-10-19T09:52"), end: jst("2026-10-19T10:21"), countsAsFocus: false, detoxGroup: .exercise),
        ], now: "2026-10-19T11:00")
        let mine = try #require(s.raceCurves(rival: nil).first { $0.kind == .minePoints })
        let dates = Set(mine.values.map(\.date))
        for boundary in ["09:03", "09:47", "09:52", "10:21"] {
            #expect(dates.contains(jst("2026-10-19T\(boundary)")))
        }
        let pieces = RaceCurve.split(mine.values.filter { $0.date >= jst("2026-10-19T08:50") }, activity: s.lineActivity(from:to:))
        #expect(pieces.map(\.activity) == [.other, .focus, .other, .detox, .other])
        #expect(pieces[1].values.first?.date == jst("2026-10-19T09:03"))
        #expect(pieces[1].values.last?.date == jst("2026-10-19T09:47"))
        #expect(pieces[2].values.first?.date == jst("2026-10-19T09:47"))
        #expect(pieces[3].values.first?.date == jst("2026-10-19T09:52"))
        #expect(pieces[3].values.last?.date == jst("2026-10-19T10:21"))
        // 動いている途中の線（線の先で切ったもの）も同じに分ける
        let cut = RaceChartLayout.cut(mine.values, at: jst("2026-10-19T09:30"))
        #expect(RaceCurve.split(cut, activity: s.lineActivity(from:to:)).last?.activity == .focus)
    }

    /// 動いている（終わりのない）タイマーの区間は今まで色が付き、集中→デトックスが同じ時刻で切り替わっても境目でつながる
    @Test func lineColorsForARunningTimerAndAnImmediateSwitch() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        let c = try t.seeded()
        try session(t, try focus(c), from: "2026-10-19T09:00", to: "2026-10-19T10:00")
        try session(t, try detox(c), from: "2026-10-19T10:00", to: "2026-10-19T10:30")
        t.clock.set(jst("2026-10-19T10:40"))
        _ = try t.store.start(StartRequest(category: try focus(c), timeZone: tokyo))  // 10:40 から動いたまま
        t.clock.set(jst("2026-10-19T11:07"))
        let s = model(t).snapshot
        #expect(s.lineActivity(from: jst("2026-10-19T11:00"), to: jst("2026-10-19T11:05")) == .focus)
        let mine = try #require(s.raceCurves(rival: nil).first { $0.kind == .minePoints })
        #expect(mine.values.last?.date == jst("2026-10-19T11:07"))
        let pieces = RaceCurve.split(mine.values.filter { $0.date >= jst("2026-10-19T08:50") }, activity: s.lineActivity(from:to:))
        #expect(pieces.map(\.activity) == [.other, .focus, .detox, .other, .focus])
        #expect(pieces[1].values.last?.date == jst("2026-10-19T10:00"))
        #expect(pieces[2].values.first?.date == jst("2026-10-19T10:00"))
        #expect(pieces[4].values.last?.date == jst("2026-10-19T11:07"))
    }

    /// 色が付くのはデトックスのカテゴリだけ。ゲーム・SNS（タイマーは始めないが、記録があっても）はほか
    @Test func gameTimeIsNotDetoxColored() {
        let s = snapshot([
            TimeSegment(start: jst("2026-10-19T20:00"), end: jst("2026-10-19T20:30"), countsAsFocus: false, isUnblock: true),
        ], now: "2026-10-19T21:00")
        #expect(s.lineActivity(from: jst("2026-10-19T20:10"), to: jst("2026-10-19T20:15")) == .other)
    }

    // MARK: ホームの帯はタイマーのタブだけ（GHO-06・16）

    /// 分析・計画のタブにいる間は出さず（出したことにもしない）、タイマーのタブに戻ったときに出す
    @Test func raceNoticeWaitsForTheTimerTab() throws {
        let t = try TestStore(now: jst("2026-10-12T09:00"))
        let c = try t.seeded()
        try session(t, try focus(c), from: "2026-10-12T09:00", to: "2026-10-12T09:30")
        try session(t, try focus(c), from: "2026-10-19T08:30", to: "2026-10-19T09:40")
        t.clock.set(jst("2026-10-19T10:05"))
        let settings = MemorySettings()
        let m = try raceModelWithBlocking(t, settings: settings)
        m.setTimerTabVisible(false)
        m.skipPlan()
        m.reload(quietly: true)
        #expect(m.notice == nil)
        #expect(m.raceNoticeCount == 0)
        #expect((settings.lastRaceNotice ?? "").isEmpty)
        m.setTimerTabVisible(true)
        #expect(m.notice?.hasPrefix("8:00–10:00 のラップ +") == true)
        #expect(m.notice?.hasSuffix("pt") == true)
        #expect(m.raceNoticeCount == 1)
    }

    /// 戻る前に朝4:00 を過ぎたら、前の日の分は出さない
    @Test func raceNoticeFromYesterdayIsDroppedAfterFour() throws {
        let t = try TestStore(now: jst("2026-10-12T09:00"))
        let c = try t.seeded()
        try session(t, try focus(c), from: "2026-10-12T09:00", to: "2026-10-12T09:30")
        try session(t, try focus(c), from: "2026-10-19T08:30", to: "2026-10-19T09:40")
        t.clock.set(jst("2026-10-19T10:05"))
        let settings = MemorySettings()
        let m = try raceModelWithBlocking(t, settings: settings)
        m.setTimerTabVisible(false)
        m.skipPlan()
        t.clock.set(jst("2026-10-20T04:10"))
        m.setTimerTabVisible(true)
        #expect(m.notice == nil)
        #expect(m.snapshot.dayStart == jst("2026-10-20T04:00"))
        m.skipPlan()
        #expect(m.notice == nil)
        #expect(m.raceNoticeCount == 0)
    }
}
