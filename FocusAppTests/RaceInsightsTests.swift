import Foundation
import Testing
@testable import FocusApp

/// ラップ（GHO-06）・予想ゴール・追いつく・自己ベスト（GHO-15）・時間帯の地図（ANA-07）・アイコン
struct RaceInsightsTests {
    private let dayStart = jst("2026-10-19T04:00")

    private func seg(_ from: String, _ to: String, focus: Bool = true, day: String = "2026-10-19") -> TimeSegment {
        TimeSegment(start: jst("\(day)T\(from)"), end: jst("\(day)T\(to)"), countsAsFocus: focus)
    }

    /// 相手：9:00〜10:00 と 11:00〜11:30 に集中
    private var opponent: [TimeSegment] { [seg("09:00", "10:00"), seg("11:00", "11:30")] }

    // MARK: ラップ

    @Test func twelveTwoHourSections() {
        let sections = Laps.sections(dayStart: dayStart)
        #expect(sections.count == 12)
        #expect(sections.first?.start == jst("2026-10-19T04:00"))
        #expect(sections.last?.end == jst("2026-10-20T04:00"))
    }

    @Test func lapsCompareEachSectionUpToNow() {
        let mine = [seg("08:30", "09:30"), seg("10:00", "11:15")]
        let laps = Laps.make(mine: mine, opponent: { opponent.focusSeconds(until: $0) }, dayStart: dayStart,
                             now: jst("2026-10-19T11:15"))
        // 4:00–6:00, 6:00–8:00, 8:00–10:00, 10:00–12:00（途中）
        #expect(laps.count == 4)
        #expect(laps[2].mine == 3600 && laps[2].opponent == 3600 && laps[2].diff == 0)
        // 10:00–12:00 は 11:15 まで：自分75分、相手15分
        #expect(laps[3].mine == 75 * 60)
        #expect(laps[3].opponent == 15 * 60)
        #expect(laps[3].isCurrent)
        #expect(laps[0].isEmpty)
    }

    @Test func halfwayIsWhenMyFocusReachesHalfOfTheirDay() {
        let mine = [seg("08:00", "08:30"), seg("09:00", "10:00")]
        // 相手の1日分 90分 → 半分の45分に届くのは 9:15
        #expect(Laps.reachTime(45 * 60, mine: mine, now: jst("2026-10-19T12:00")) == jst("2026-10-19T09:15"))
        #expect(Laps.reachTime(45 * 60, mine: mine, now: jst("2026-10-19T09:10")) == nil)
        #expect(Laps.reachTime(0, mine: mine, now: jst("2026-10-19T12:00")) == nil)
    }

    @Test func lapsAroundFourAm() {
        // 3:59 は前の日の最後の区間（翌2:00–翌4:00）の途中、4:00 は新しい日の最初の区間
        let late = Laps.make(mine: [seg("02:30", "03:30", day: "2026-10-20")], opponent: { _ in 0 }, dayStart: dayStart,
                             now: jst("2026-10-20T03:59"))
        #expect(late.count == 12)
        #expect(late.last?.isCurrent == true)
        #expect(late.last?.mine == 3600)
        let next = Laps.make(mine: [], opponent: { _ in 0 }, dayStart: jst("2026-10-20T04:00"), now: jst("2026-10-20T04:00"))
        #expect(next.isEmpty)
        let justAfter = Laps.make(mine: [], opponent: { _ in 0 }, dayStart: jst("2026-10-20T04:00"), now: jst("2026-10-20T04:01"))
        #expect(justAfter.count == 1)
    }

    // MARK: 予想ゴール・追いつく

    private func block(_ from: String, _ to: String, focus: Bool = true) -> PlanBlockSummary {
        let category = CategoryOption(name: focus ? "勉強" : "運動", countsAsFocus: focus)
        return PlanBlockSummary(id: UUID(), category: category, title: category.name, categoryName: category.name,
                                start: jst("2026-10-19T\(from)"), end: jst("2026-10-19T\(to)"), countsAsFocus: focus)
    }

    @Test func plannedFinishAddsTheRestOfThePlan() {
        let blocks = [block("09:00", "10:00"), block("11:00", "13:00"), block("16:00", "17:00", focus: false), block("19:00", "20:00")]
        // 11:30：今までの集中 1時間＋今のブロックの残り1時間30分＋19:00 の1時間（運動は入れない）
        #expect(RacePace.plannedFinish(focusNow: 3600, blocks: blocks, now: jst("2026-10-19T11:30")) == 3600 + 5400 + 3600)
    }

    @Test func paceFinishOnNoPlanDays() {
        // 7:00 起床、寝るのは 23:00。12:00 までに2時間 → 16時間で 6時間24分
        #expect(RacePace.paceFinish(focusNow: 7200, wake: jst("2026-10-19T07:00"), bed: jst("2026-10-19T23:00"),
                                    now: jst("2026-10-19T12:00")) == 7200 * 16 / 5)
        // 起きて30分未満は出さない
        #expect(RacePace.paceFinish(focusNow: 0, wake: jst("2026-10-19T07:00"), bed: jst("2026-10-19T23:00"),
                                    now: jst("2026-10-19T07:20")) == nil)
    }

    @Test func catchUpCountsTheMinutesOfFocusFromNow() {
        // 10:00 で自分0分・相手60分。休まず集中すると、相手が止まっている 11:00 に並ぶ（60分）
        let minutes = RacePace.catchUpMinutes(focusNow: 0, opponent: { opponent.focusSeconds(until: $0) },
                                              now: jst("2026-10-19T10:00"), dayEnd: jst("2026-10-20T04:00"))
        #expect(minutes == 60)
        // 10:30 で自分10分・相手60分：11:30 は自分70分・相手90分。相手が止まったあと 11:50 に90分で並ぶ（80分）
        #expect(RacePace.catchUpMinutes(focusNow: 600, opponent: { opponent.focusSeconds(until: $0) },
                                        now: jst("2026-10-19T10:30"), dayEnd: jst("2026-10-20T04:00")) == 80)
        // リードしていれば出さない
        #expect(RacePace.catchUpMinutes(focusNow: 7200, opponent: { opponent.focusSeconds(until: $0) },
                                        now: jst("2026-10-19T10:00"), dayEnd: jst("2026-10-20T04:00")) == nil)
        // その日のうちに追いつけなければ出さない
        #expect(RacePace.catchUpMinutes(focusNow: 0, opponent: { _ in 10 * 3600 },
                                        now: jst("2026-10-20T03:00"), dayEnd: jst("2026-10-20T04:00")) == nil)
    }

    // MARK: 自己ベスト

    @Test func focusIsSplitIntoDaysAtFourAm() {
        let byDay = DailyFocus.byDay([seg("22:00", "23:00", day: "2026-10-18"), seg("03:00", "05:00", day: "2026-10-19"),
                                      seg("09:00", "10:00", focus: false)], calendar: tokyoCalendar)
        #expect(byDay[jst("2026-10-18T04:00")] == 2 * 3600)
        #expect(byDay[jst("2026-10-19T04:00")] == 3600)
    }

    @Test func bestIgnoresTodayAndShowsNearOrBeaten() throws {
        let byDay = [jst("2026-10-17T04:00"): 5 * 3600, jst("2026-10-18T04:00"): 6 * 3600, jst("2026-10-19T04:00"): 9 * 3600]
        let best = try #require(DailyFocus.best(byDay, before: jst("2026-10-19T04:00")))
        #expect(best.focusSeconds == 6 * 3600)
        #expect(best.focusDay == jst("2026-10-18T04:00"))
        #expect(best.status(todayFocus: 5 * 3600 + 30 * 60) == .near(minutes: 30))
        #expect(best.status(todayFocus: 4 * 3600) == nil)
        #expect(best.status(todayFocus: 6 * 3600 + 1) == .beaten)
        #expect(DailyFocus.best([:], before: jst("2026-10-19T04:00")) == nil)
    }

    @Test func bestEdges() throws {
        let best = try #require(DailyFocus.best([jst("2026-10-18T04:00"): 3 * 3600], before: dayStart))
        // 同じなら更新ではない、60分ちょうどは近い
        #expect(best.status(todayFocus: 3 * 3600) == nil)
        #expect(best.status(todayFocus: 2 * 3600) == .near(minutes: 60))
        #expect(best.status(todayFocus: 2 * 3600 - 1) == nil)
        // 同じ長さの日が2つなら早い日
        let tie = try #require(DailyFocus.best([jst("2026-10-17T04:00"): 3600, jst("2026-10-18T04:00"): 3600], before: dayStart))
        #expect(tie.focusDay == jst("2026-10-17T04:00"))
    }

    @Test func focusSplitAtThreeFiftyNineAndFourAm() {
        let byDay = DailyFocus.byDay([seg("03:59", "04:01", day: "2026-10-19")], calendar: tokyoCalendar)
        #expect(byDay[jst("2026-10-18T04:00")] == 60)
        #expect(byDay[jst("2026-10-19T04:00")] == 60)
    }

    @Test func timeMapKeepsExactlyFourWeeks() {
        // 28日前（10-21 から見て 9-23）は入り、29日前は入らない
        let map = TimeMap.make([seg("10:00", "11:00", day: "2026-09-23"), seg("10:00", "12:00", day: "2026-09-22")],
                               today: jst("2026-10-21T04:00"), calendar: tokyoCalendar)
        // 9-23 は水曜（2）、9-22 は火曜（1）
        #expect(map.averages[2][3] == 3600)
        #expect(map.averages[1].allSatisfy { $0 == 0 })
    }

    // MARK: 時間帯の地図

    @Test func timeMapAveragesRecordedDaysOfTheLastFourWeeks() throws {
        // 月曜（10-12）と月曜（10-05）の 10:00–12:00 に 60分・30分、5週前の月曜は入れない、今日（10-19 月）も入れない
        let segments = [seg("10:00", "11:00", day: "2026-10-12"), seg("10:30", "11:00", day: "2026-10-05"),
                        seg("10:00", "12:00", day: "2026-09-14"), seg("10:00", "12:00", day: "2026-10-19")]
        let map = TimeMap.make(segments, today: dayStart, calendar: tokyoCalendar)
        #expect(map.averages[0][3] == 45 * 60)
        #expect(map.averages[1].allSatisfy { $0 == 0 })
        let peak = try #require(map.peak)
        #expect(peak.weekday == 0 && peak.section == 3)
    }

    @Test func iconsComeFromNamesAndGroups() {
        #expect(CategoryIcon.symbol(for: CategoryOption(name: "勉強", countsAsFocus: true)) == "pencil")
        #expect(CategoryIcon.symbol(for: CategoryOption(name: "運動", countsAsFocus: false)) == "figure.run")
        #expect(CategoryIcon.symbol(for: CategoryOption(name: "ピアノ", countsAsFocus: true)) == "star.fill")
        #expect(CategoryIcon.symbol(for: CategoryOption(name: "散歩", countsAsFocus: false)) == "leaf.fill")
        #expect(CategoryIcon.symbol(for: .gameSNS) == "gamecontroller.fill")
    }
}

/// 本体：ラップの帯・自己ベスト・休み明け
@MainActor
struct RaceInsightsModelTests {
    private func model(_ t: TestStore, settings: MemorySettings = MemorySettings()) -> AppModel {
        settings.didShowBlockingIntro = true
        return AppModel(store: t.store, clock: t.clock, timeZone: { tokyo }, settings: settings)
    }

    private func session(_ t: TestStore, _ c: [CategoryOption], from: String, to: String) throws {
        t.clock.set(jst(from))
        _ = try t.store.start(StartRequest(category: c[0], timeZone: tokyo))
        t.clock.set(jst(to))
        let running = try #require(try t.store.runningSession())
        _ = try t.store.end(id: running.id, reportedEnd: nil)
    }

    @Test func lapNoticeAppearsOncePerSection() throws {
        let t = try TestStore(now: jst("2026-10-12T09:00"))
        let c = try t.seeded()
        try session(t, c, from: "2026-10-12T09:00", to: "2026-10-12T09:30")
        try session(t, c, from: "2026-10-19T08:30", to: "2026-10-19T09:40")
        t.clock.set(jst("2026-10-19T10:05"))
        let settings = MemorySettings()
        let m = model(t, settings: settings)
        // 朝の計画を閉じると読み直して知らせる。8:00–10:00：自分70分・先週30分
        m.skipPlan()
        #expect(m.notice == "8:00–10:00 のラップ +40分")
        #expect(m.raceNoticeCount == 1)
        // 次は中間地点（先週の1日分30分の半分に 8:45 で届いた）
        m.notice = nil
        m.reload()
        #expect(m.notice == "中間地点を通過")
        // 同じものは二度出さない（開き直しても）
        m.notice = nil
        m.reload()
        #expect(m.notice == nil)
        let again = model(t, settings: settings)
        again.reload()
        #expect(again.notice == nil)
        #expect(again.raceNoticeCount == 0)
    }

    @Test func personalBestAndOlderHistoryComeFromPastDays() throws {
        let t = try TestStore(now: jst("2026-10-01T09:00"))
        let c = try t.seeded()
        try session(t, c, from: "2026-10-01T09:00", to: "2026-10-01T12:00")
        try session(t, c, from: "2026-10-03T09:00", to: "2026-10-03T10:00")
        t.clock.set(jst("2026-10-19T09:00"))
        let m = model(t)
        #expect(m.snapshot.personalBest?.focusSeconds == 3 * 3600)
        #expect(m.snapshot.personalBest?.focusDay == jst("2026-10-01T04:00"))
        // 先週（10-12）の記録はないが、それより前にある → 休み明け
        #expect(m.snapshot.ghost == nil)
        #expect(m.snapshot.hasOlderHistory)
    }

    @Test func noLapNoticeWhileATimerRuns() throws {
        let t = try TestStore(now: jst("2026-10-12T09:00"))
        let c = try t.seeded()
        try session(t, c, from: "2026-10-12T09:00", to: "2026-10-12T09:30")
        try session(t, c, from: "2026-10-19T08:30", to: "2026-10-19T09:40")
        t.clock.set(jst("2026-10-19T10:05"))
        let settings = MemorySettings()
        let m = model(t, settings: settings)
        m.skipPlan()
        m.notice = nil
        m.startUnplanned(category: c[0], minutes: nil)
        t.clock.set(jst("2026-10-19T12:05"))
        m.reload()
        // 10:00–12:00 が終わってもタイマー中は出さない
        #expect(m.notice == nil || m.notice == "中間地点を通過")
        #expect(!(settings.lastRaceNotice ?? "").contains("\(Int(jst("2026-10-19T10:00").timeIntervalSinceReferenceDate))"))
    }

    @Test func emptySectionsAreNeverAnnounced() throws {
        let t = try TestStore(now: jst("2026-10-12T09:00"))
        let c = try t.seeded()
        try session(t, c, from: "2026-10-12T09:00", to: "2026-10-12T09:30")
        t.clock.set(jst("2026-10-19T08:05"))
        let m = model(t)
        m.skipPlan()
        // 6:00–8:00 は自分も先週も0分なので出さない
        #expect(m.notice == nil)
        #expect(m.raceNoticeCount == 0)
    }
}
