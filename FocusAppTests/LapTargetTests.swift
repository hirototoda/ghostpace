import Foundation
import Testing
@testable import FocusApp

/// ラップ表の相手（ANA-06：ベストの日・平均・区間ベスト）、区間ベストと理論ベスト・★（ANA-11）
struct LapTargetTests {
    private let hour: TimeInterval = 3600

    /// 過ぎた1日。時刻は "HH:mm"（4:00 より前は翌日）。`other` は集中以外の点（その時刻に付く）
    private func day(_ date: String, focus: [(String, String)] = [], opened: [(String, String)] = [],
                     declared: [(String, String)] = [], other: [(String, Double)] = []) -> RecordDay {
        let start = jst("\(date)T04:00")
        func at(_ time: String) -> Date {
            let t = jst("\(date)T\(time)")
            return t < start ? t.addingTimeInterval(24 * hour) : t
        }
        let segments = focus.map { TimeSegment(start: at($0.0), end: at($0.1), countsAsFocus: true) }
            + declared.map { TimeSegment(start: at($0.0), end: at($0.1), countsAsFocus: true, isDeclared: true) }
        let openedIntervals = opened.map { DateInterval(start: at($0.0), end: at($0.1)) }
        let others = other.map { (at($0.0), $0.1) }
        return RecordDay(dayStart: start,
                         pieces: FocusPoints.pieces(segments, until: start.addingTimeInterval(24 * hour), opened: openedIntervals),
                         otherPoints: { date in others.filter { $0.0 <= date }.reduce(0) { $0 + $1.1 } })
    }

    // MARK: 集中の一切れ（数え直しの材料）

    /// 一切れから数え直すと、ふだんのポイントと同じ（1回の長さ・1日の合計・開けた時間・申告の0.8倍）
    @Test func piecesGiveTheSamePoints() {
        let start = jst("2026-10-13T04:00")
        let segments = [
            TimeSegment(start: jst("2026-10-13T06:00"), end: jst("2026-10-13T10:00"), countsAsFocus: true),
            TimeSegment(start: jst("2026-10-13T10:03"), end: jst("2026-10-13T13:00"), countsAsFocus: true),
            TimeSegment(start: jst("2026-10-13T14:00"), end: jst("2026-10-13T20:00"), countsAsFocus: true),
            TimeSegment(start: jst("2026-10-13T21:00"), end: jst("2026-10-13T22:00"), countsAsFocus: true, isDeclared: true),
            TimeSegment(start: jst("2026-10-13T22:00"), end: jst("2026-10-13T23:00"), countsAsFocus: false),
        ]
        let opened = [DateInterval(start: jst("2026-10-13T07:00"), end: jst("2026-10-13T07:20")),
                      DateInterval(start: jst("2026-10-13T15:10"), end: jst("2026-10-13T15:40"))]
        let pieces = FocusPoints.pieces(segments, until: start.addingTimeInterval(24 * hour), opened: opened)
        for minutes in stride(from: 0, through: 24 * 60, by: 10) {
            let t = start.addingTimeInterval(Double(minutes) * 60)
            #expect(FocusPoints.points(pieces, until: t).isApprox(FocusPoints.points(segments, until: t, opened: opened)))
        }
    }

    /// 一切れは1回の長さの倍率が変わる所と、開けた時間の出入りで分かれる
    @Test func piecesSplitAtRunLimitsAndOpenedTime() {
        let segments = [TimeSegment(start: jst("2026-10-13T06:00"), end: jst("2026-10-13T10:00"), countsAsFocus: true)]
        let opened = [DateInterval(start: jst("2026-10-13T06:30"), end: jst("2026-10-13T06:40"))]
        let pieces = FocusPoints.pieces(segments, until: jst("2026-10-14T04:00"), opened: opened)
        #expect(pieces.map(\.start) == ["06:00", "06:30", "06:40", "07:30", "09:00"].map { jst("2026-10-13T\($0)") })
        #expect(pieces.map(\.runFactor) == [1, 1, 1, 0.75, 0.5])
        #expect(pieces.map(\.opened) == [false, true, false, false, false])
    }

    // MARK: 平均

    /// 期間の記録のある日の、その時刻までのポイントの平均。最後は1日の平均
    @Test func averageOfTheDays() throws {
        let a = day("2026-10-13", focus: [("06:00", "07:00")])  // 6pt
        let b = day("2026-10-14", focus: [("06:00", "07:00"), ("10:00", "11:00")])  // 12pt
        let average = try #require(LapTargets.average([a, b]))
        #expect(average(3 * hour).isApprox(6))  // 7:00
        #expect(average(2.5 * hour).isApprox(3))  // 6:30
        #expect(average(24 * hour).isApprox(9))
        // 1日ならその日の値
        let one = try #require(LapTargets.average([b]))
        #expect(one(24 * hour).isApprox(12))
        // 日がなければ出さない
        #expect(LapTargets.average([]) == nil)
    }

    // MARK: 区間ベスト

    /// 区間ごとに一番ポイントが増えた日。同じなら新しい日。どの日も0の区間は新しい日の0
    @Test func sectionRecordsPickTheHighestNewerOnTie() {
        let older = day("2026-10-12", focus: [("08:00", "09:00")])  // 8:00–10:00 に 6pt
        let a = day("2026-10-13", focus: [("06:00", "07:00")])  // 6:00–8:00 に 6pt
        let b = day("2026-10-14", focus: [("06:00", "07:00"), ("08:00", "08:30")])  // 6pt と 3pt
        let records = LapTargets.sectionRecords([older, a, b])
        #expect(records.count == Laps.count)
        #expect(records[1].dayStart == b.dayStart)
        #expect(records[1].value.isApprox(6))
        #expect(records[2].dayStart == older.dayStart)
        #expect(records[2].value.isApprox(6))
        #expect(records[0].dayStart == b.dayStart)
        #expect(records[0].value.isApprox(0))
        #expect(LapTargets.sectionRecords([]).isEmpty)
    }

    /// 区間の値は累計の引き算なので、浮動小数の小さな誤差は同点とみなして新しい日にする
    /// （(63.9 + 0.3) − 63.9 は (31.9 + 0.3) − 31.9 よりわずかに大きい）
    @Test func sectionRecordsTreatTinyDifferencesAsTies() {
        let older = day("2026-10-13", other: [("05:00", 63.9), ("09:00", 0.3)])
        let newer = day("2026-10-14", other: [("05:00", 31.9), ("09:00", 0.3)])
        #expect(older.points(at: 6 * hour) - older.points(at: 4 * hour) > newer.points(at: 6 * hour) - newer.points(at: 4 * hour))
        let records = LapTargets.sectionRecords([older, newer])
        #expect(records[2].dayStart == newer.dayStart)
        // はっきり多ければ古い日
        let more = day("2026-10-13", other: [("09:00", 0.31)])
        #expect(LapTargets.sectionRecords([more, newer])[2].dayStart == more.dayStart)
    }

    /// ポイントの多い順（ベスト10・ベストの日）。同点（小さな誤差を含む）なら新しい日が上
    @Test func rankedDaysPutNewerFirstOnTies() {
        func points(_ date: String, _ value: Double) -> DayPoints {
            DayPoints(dayStart: jst("\(date)T04:00"), points: value, lastWeek: nil, isToday: false)
        }
        let ranked = LapTargets.ranked([
            points("2026-10-11", (63.9 + 0.3) - 63.9),
            points("2026-10-12", (31.9 + 0.3) - 31.9),
            points("2026-10-13", 0.5),
            points("2026-10-14", 0.1),
            DayPoints(dayStart: jst("2026-10-15T04:00"), points: nil, lastWeek: nil, isToday: false),
        ])
        #expect(ranked.map(\.dayStart) == ["2026-10-13", "2026-10-12", "2026-10-11", "2026-10-14"].map { jst("\($0)T04:00") })
    }

    /// 区間全体の値で比べる。区間の途中で多くても、区間の終わりで少なければ選ばない。マイナスの区間は一番大きい（0に近い）日
    @Test func sectionRecordsUseTheWholeSection() {
        // 9:00 の時点では late が多いが、区間の終わり（10:00）では early が多い
        let early = day("2026-10-13", focus: [("09:00", "10:00")], other: [("05:00", -2)])
        let late = day("2026-10-14", focus: [("08:00", "08:50")], other: [("05:00", -1)])
        let records = LapTargets.sectionRecords([early, late])
        #expect(records[2].dayStart == early.dayStart)
        #expect(records[0].dayStart == late.dayStart)
        #expect(records[0].value.isApprox(-1))
    }

    /// 睡眠の区間：設定の睡眠と半分以上（ちょうど半分も）重なる区間
    @Test func sleepSectionsOverlapHalfOrMore() {
        let today = jst("2026-10-22T04:00")
        let tomorrow = jst("2026-10-23T04:00")
        func sections(_ start: Int, _ end: Int) -> Set<Int> {
            LapTargets.sleepSections(startMinutes: start, endMinutes: end, dayStart: today, calendar: tokyoCalendar)
        }
        // 当てはめた睡眠の区間から数えても同じ
        let sleep = [today, tomorrow].map {
            SleepLine.fromSetting(startMinutes: 0, endMinutes: 7 * 60, dayStart: $0, calendar: tokyoCalendar).interval
        }
        #expect(LapTargets.sleepSections(sleep, dayStart: today) == sections(0, 7 * 60))
        // 0:00–7:00：4:00–6:00、6:00–8:00（ちょうど半分）、翌0:00–2:00、翌2:00–4:00
        #expect(sections(0, 7 * 60) == [0, 1, 10, 11])
        // 23:00–7:00：22:00–24:00 もちょうど半分
        #expect(sections(23 * 60, 7 * 60) == [0, 1, 9, 10, 11])
        // 22:30–6:30：22:00–24:00 は1時間半、6:00–8:00 は30分
        #expect(sections(22 * 60 + 30, 6 * 60 + 30) == [0, 9, 10, 11])
        // 23:01–6:59：どちらも半分に届かない
        #expect(sections(23 * 60 + 1, 6 * 60 + 59) == [0, 10, 11])
    }

    // MARK: 区間ベストをつないだ1日（理論ベスト）

    /// 1日の合計の倍率（8時間で×0.75、10時間で×0.5）は、つないだ1日で時刻の順に数え直す
    @Test func dayLimitsAreRecountedInTimeOrder() {
        // それぞれ6時間（90分×4、間を空けて1回の長さの倍率はかからない）
        let a = day("2026-10-13", focus: [("06:00", "07:30"), ("08:00", "09:30"), ("10:00", "11:30"), ("12:00", "13:30")])
        let b = day("2026-10-14", focus: [("14:00", "15:30"), ("16:00", "17:30"), ("18:00", "19:30"), ("20:00", "21:30")])
        let records = LapTargets.sectionRecords([a, b])
        #expect(records.reduce(0) { $0 + $1.value }.isApprox(72))
        let curve = LapTargets.sectionBestDay([a, b], records: records, sleepSections: [])
        // 12時間：8時間まで 48 ＋ 8〜10時間 ×0.75 で 9 ＋ 10〜12時間 ×0.5 で 6
        #expect(curve(24 * hour).isApprox(63))
        // 18:00 まで（9時間）：48 ＋ 1時間 ×0.75 で 4.5
        #expect(curve(14 * hour).isApprox(52.5))
        // 8時間ちょうどなら下がらない
        let short = day("2026-10-14", focus: [("14:00", "15:30"), ("16:00", "16:30")])
        let exact = LapTargets.sectionBestDay([a, short], records: LapTargets.sectionRecords([a, short]), sleepSections: [])
        #expect(exact(24 * hour).isApprox(48))
    }

    /// 10時間ちょうどまでは ×0.75 のまま。10時間を超えた分から ×0.5
    @Test func tenHoursExactlyStaysAtThreeQuarters() {
        let a = day("2026-10-13", focus: [("06:00", "07:30"), ("08:00", "09:30"), ("10:00", "11:30"), ("12:00", "13:30")])
        // b は4時間（つなぐと10時間ちょうど）
        let b = day("2026-10-14", focus: [("14:00", "15:30"), ("16:00", "17:30"), ("18:00", "19:00")])
        let exact = LapTargets.sectionBestDay([a, b], records: LapTargets.sectionRecords([a, b]), sleepSections: [])
        // 8時間まで 48 ＋ 8〜10時間 ×0.75 で 9
        #expect(exact(24 * hour).isApprox(57))
        // 6分超えると、その6分は ×0.5（0.3）
        let over = day("2026-10-14", focus: [("14:00", "15:30"), ("16:00", "17:30"), ("18:00", "19:06")])
        let longer = LapTargets.sectionBestDay([a, over], records: LapTargets.sectionRecords([a, over]), sleepSections: [])
        #expect(longer(24 * hour).isApprox(57.3))
    }

    /// 期間の材料：記録・理論ベスト・ベスト10は1回で作り、相手ごとの1日はそこから出す
    @Test func periodRecordsHoldEverything() throws {
        let a = day("2026-10-13", focus: [("06:00", "07:00")])  // 6
        let b = day("2026-10-14", focus: [("08:00", "09:00"), ("10:00", "10:30")])  // 9
        func points(_ day: RecordDay) -> DayPoints {
            DayPoints(dayStart: day.dayStart, points: day.points(at: 24 * hour), lastWeek: nil, isToday: false)
        }
        let period = PeriodRecords(days: [(points(a), a), (points(b), b)], sleepSections: [])
        #expect(period.records.count == Laps.count)
        #expect(period.topDays.map(\.dayStart) == [b.dayStart, a.dayStart])
        #expect(try #require(period.theoreticalBest).isApprox(15))
        let bestDay = try #require(period.curve(.bestDay))
        let average = try #require(period.curve(.average))
        let sectionBest = try #require(period.curve(.sectionBest))
        #expect(bestDay(24 * hour).isApprox(9))
        #expect(average(24 * hour).isApprox(7.5))
        #expect(sectionBest(24 * hour).isApprox(15))
        let empty = PeriodRecords(days: [], sleepSections: [])
        #expect(empty.theoreticalBest == nil && empty.topDays.isEmpty && empty.curve(.average) == nil)
    }

    /// 区間をまたぐ集中は境目で切る。1回の長さの倍率はもとの日のまま
    @Test func sessionsAreCutAtSectionsKeepingTheRunFactor() {
        // 6:00–9:00 の3時間：6:00–8:00 は 9 ＋ 30分×0.75 ＝ 11.25、8:00–9:00 は 60分×0.75 ＝ 4.5
        let a = day("2026-10-13", focus: [("06:00", "09:00")])
        let b = day("2026-10-14", focus: [("08:00", "09:00")])  // 8:00–10:00 に 6
        let records = LapTargets.sectionRecords([a, b])
        #expect(records[1].dayStart == a.dayStart)
        #expect(records[1].value.isApprox(11.25))
        #expect(records[2].dayStart == b.dayStart)
        let curve = LapTargets.sectionBestDay([a, b], records: records, sleepSections: [])
        #expect(curve(24 * hour).isApprox(17.25))
        // 区間の途中は選んだ日の同じ時刻まで（7:00 なら a の 6:00–7:00）
        #expect(curve(3 * hour).isApprox(6))
        #expect(curve(4.5 * hour).isApprox(14.25))
    }

    /// 開けていた時間はもとの日のまま0点で、1日の合計には進む
    @Test func openedTimeStaysZeroButCountsTowardTheDay() {
        // 90分×5 ＝ 7時間30分（うち30分は開けていた）
        let a = day("2026-10-13", focus: [("04:00", "05:30"), ("06:00", "07:30"), ("08:00", "09:30"), ("10:00", "11:30"),
                                          ("12:00", "13:30")],
                    opened: [("12:00", "12:30")])
        let b = day("2026-10-14", focus: [("14:00", "15:30")])
        let curve = LapTargets.sectionBestDay([a, b], records: LapTargets.sectionRecords([a, b]), sleepSections: [])
        // a は 45 − 3 ＝ 42。b は 7時間30分から：30分 3 ＋ 60分×0.75 で 4.5
        #expect(curve(24 * hour).isApprox(49.5))
    }

    /// 申告の0.8倍も、もとの日のまま
    @Test func declaredWeightIsKept() {
        let a = day("2026-10-13", declared: [("06:00", "07:00")])
        let curve = LapTargets.sectionBestDay([a], records: LapTargets.sectionRecords([a]), sleepSections: [])
        #expect(curve(24 * hour).isApprox(4.8))
    }

    /// 集中以外の点は選んだ日のその区間の値のまま。睡眠の区間は平均。★の記録は睡眠の区間でも区間ベスト
    @Test func otherPointsAndSleepSections() {
        let a = day("2026-10-13", focus: [("10:00", "11:00")], other: [("05:00", 4), ("10:30", 1)])
        let b = day("2026-10-14", other: [("05:00", 2), ("13:00", 0.5)])
        let records = LapTargets.sectionRecords([a, b])
        #expect(records[0].dayStart == a.dayStart)
        #expect(records[0].value.isApprox(4))
        #expect(records[3].value.isApprox(7))
        #expect(records[4].dayStart == b.dayStart)
        let curve = LapTargets.sectionBestDay([a, b], records: records, sleepSections: [0])
        // 4:00–6:00 は平均の 3、10:00–12:00 は a の 7、12:00–14:00 は b の 0.5
        #expect(curve(2 * hour).isApprox(3))
        #expect(curve(1.5 * hour).isApprox(3))
        #expect(curve(24 * hour).isApprox(10.5))
        // 睡眠の区間がなければ区間ベストの 4
        #expect(LapTargets.sectionBestDay([a, b], records: records, sleepSections: [])(24 * hour).isApprox(11.5))
    }

    /// 睡眠の区間の平均に入っている集中は、1日の合計（8時間・10時間）に入れない。起きている区間でつないだ集中だけで数える
    /// （2026-10-07 オーナー決定）
    @Test func sleepSectionFocusDoesNotCountTowardTheDay() {
        // 4:00–5:30 に集中した日（4:00–6:00 は睡眠の区間）と、起きている区間でちょうど8時間集中した日
        let night = day("2026-10-13", focus: [("04:00", "05:30")])
        let long = day("2026-10-14", focus: [("06:00", "07:30"), ("08:00", "09:30"), ("10:00", "11:30"), ("12:00", "13:30"),
                                             ("14:00", "15:30"), ("16:00", "16:30")])
        let curve = LapTargets.sectionBestDay([night, long], records: LapTargets.sectionRecords([night, long]), sleepSections: [0])
        // 睡眠の区間は平均 4.5、起きている区間は8時間ちょうどで 48（×0.75 はかからない）
        #expect(curve(2 * hour).isApprox(4.5))
        #expect(curve(24 * hour).isApprox(52.5))
    }

    /// 1日だけなら、睡眠の区間がなければその日と同じ
    @Test func oneDayGivesTheSameDay() {
        let a = day("2026-10-13", focus: [("06:00", "10:00"), ("10:10", "20:00")], opened: [("15:00", "15:30")],
                    other: [("05:00", 3), ("21:00", -1)])
        let curve = LapTargets.sectionBestDay([a], records: LapTargets.sectionRecords([a]), sleepSections: [])
        for h in stride(from: 0.0, through: 24, by: 0.5) {
            #expect(curve(h * hour).isApprox(a.points(at: h * hour)))
        }
    }

    // MARK: ラップ表の行と ★

    /// 相手は 4:00 からの経過で渡す。区間ベストの記録を渡すと行に入る
    @Test func lapRowsCarryTheRecord() {
        let today = jst("2026-10-22T04:00")
        func mine(_ date: Date) -> Double { min(max(date.timeIntervalSince(today) / hour - 4, 0), 1) * 6.1 }
        func theirs(_ offset: TimeInterval) -> Double { min(max(offset / hour - 4, 0), 1) * 5 }
        var records = Array(repeating: 0.0, count: Laps.count)
        records[2] = 6
        let rows = BestLaps.make(today: mine, todayStart: today, now: jst("2026-10-22T11:00"), theirs: theirs, records: records)
        #expect(rows.map(\.section.start) == [jst("2026-10-22T08:00")])
        #expect(rows[0].record == 6)
        #expect(rows[0].theirs.isApprox(5))
        #expect(rows[0].theirsTotal.isApprox(5))
        #expect(rows[0].gold)
        // 記録がなければ ★ なし
        let plain = BestLaps.make(today: mine, todayStart: today, now: jst("2026-10-22T11:00"), theirs: theirs)
        #expect(plain[0].record == nil)
        #expect(!plain[0].gold)
    }

    /// ★：表示（0.1pt）で区間ベストを超えたときだけ。同じなら付けない。今日が 0.0 以下なら付けない
    @Test func goldUsesTheShownValues() {
        let section = DateInterval(start: jst("2026-10-22T08:00"), duration: Laps.length)
        func row(_ today: Double?, record: Double?, theirs: Double = 0) -> BestLapRow {
            BestLapRow(section: section, today: today, todayTotal: today, theirs: theirs, theirsTotal: theirs,
                       isCurrent: false, record: record)
        }
        #expect(row(6.1, record: 6.0).gold)
        #expect(!row(6.04, record: 6.0).gold)
        #expect(row(6.06, record: 6.0).gold)
        #expect(!row(5.9, record: 6.0).gold)
        // 区間ベストがマイナスでも、今日が 0.0 なら付けない
        #expect(!row(0, record: -1).gold)
        #expect(!row(0.04, record: -1).gold)
        #expect(row(0.1, record: -1).gold)
        // まだ来ていない区間
        #expect(!row(nil, record: -1).gold)
        // 赤（表の相手と比べる）と ★（区間ベストと比べる）は別
        let mixed = row(6.5, record: 7, theirs: 6)
        #expect(mixed.todayWins && !mixed.gold)
    }

    /// 今の区間は今までの値で区間ベスト（区間全体）と比べる
    @Test func goldInTheCurrentSection() {
        let today = jst("2026-10-22T04:00")
        // 今日は 10:00 から集中（今 11:00 で 6pt）
        func mine(_ date: Date) -> Double { min(max(date.timeIntervalSince(today) / hour - 6, 0), 2) * 6 }
        var records = Array(repeating: 0.0, count: Laps.count)
        records[3] = 5.9
        let rows = BestLaps.make(today: mine, todayStart: today, now: jst("2026-10-22T11:00"), theirs: { _ in 0 },
                                 records: records)
        #expect(rows.count == 1 && rows[0].isCurrent && rows[0].gold)
        records[3] = 9
        let notYet = BestLaps.make(today: mine, todayStart: today, now: jst("2026-10-22T11:00"), theirs: { _ in 0 },
                                   records: records)
        #expect(!notYet[0].gold)
    }
}
