import Foundation
import SwiftData
import Testing
@testable import FocusApp

/// 手動の記録（TMR-13、docs/product/features/focus-timer.md「手動の記録」）：記録できるかの判定
struct ManualRecordTests {
    private let study = CategoryOption(id: UUID(), name: "勉強", countsAsFocus: true)
    private let housework = CategoryOption(id: UUID(), name: "家事", countsAsFocus: false)
    private let zone = "Asia/Tokyo"

    private func at(_ time: String, day: String = "2026-10-19") -> Date { jst("\(day)T\(time)") }

    private func record(_ from: String, _ to: String?, day: String = "2026-10-19", blockId: UUID? = nil) -> FocusSession {
        FocusSession(id: UUID(), dayKey: DayBoundary.dayKey(containing: at(from, day: day), calendar: tokyoCalendar),
                     category: study, planBlockId: blockId, startAt: at(from, day: day), endAt: to.map { at($0, day: day) })
    }

    private func event(_ kind: BlockEvent.Kind, _ time: String, day: String = "2026-10-19") -> BlockEvent {
        BlockEvent(occurredAt: at(time, day: day), timeZoneId: zone, kind: kind)
    }

    /// 今は 2026-10-19 12:00。ブロックは 10-01 から始めている。睡眠は 0:00〜7:00（昨日と今日）
    private func context(now: String = "12:00", events: [BlockEvent]? = nil, games: [DateInterval] = [],
                         sessions: [FocusSession] = [], sleep: [DateInterval]? = nil) -> ManualRecord.Context {
        ManualRecord.Context(
            now: at(now), dayKeys: ["2026-10-18", "2026-10-19"], calendar: tokyoCalendar,
            events: events ?? [event(.started, "04:00", day: "2026-10-01")], gameWindows: games, sessions: sessions,
            sleep: sleep ?? [DateInterval(start: at("00:00"), end: at("07:00")),
                             DateInterval(start: at("00:00", day: "2026-10-18"), end: at("07:00", day: "2026-10-18"))])
    }

    private func check(_ from: String, _ to: String, day: String = "2026-10-19", toDay: String? = nil,
                       excluding id: UUID? = nil, _ context: ManualRecord.Context? = nil) -> ManualRecord.Problem? {
        ManualRecord.problem(start: at(from, day: day), end: at(to, day: toDay ?? day), excluding: id, context: context ?? self.context())
    }

    @Test func anyCategoryCanBeRecordedWhenTheAppWasNotUsed() {
        #expect(check("09:00", "10:00") == nil)
        // 1分ちょうどまで
        #expect(check("09:00", "09:01") == nil)
        // 昨日の分も
        #expect(check("20:00", "21:30", day: "2026-10-18") == nil)
    }

    @Test func lengthAndRange() {
        // 1分未満・終わりが開始より前は保存できない
        #expect(check("09:00", "09:00:59") == .tooShort)
        #expect(check("09:00", "08:30") == .tooShort)
        // 今より後に終わるものは記録できない（今ちょうどまでならよい）
        #expect(check("11:30", "12:01") == .notEnded)
        #expect(check("11:30", "12:00") == nil)
        // 始めた日が今日か昨日（朝4:00区切り）。昨日の 4:00 からよく、3:59 からは一昨日
        #expect(check("04:00", "05:00", day: "2026-10-18", context(sleep: [])) == nil)
        #expect(check("03:59", "05:00", day: "2026-10-18", context(sleep: [])) == .outOfRange)
        #expect(check("20:00", "21:00", day: "2026-10-17") == .outOfRange)
    }

    /// 4:00 をまたいでもよい（始めた日の記録）
    @Test func recordsMayCrossFourAm() {
        #expect(check("03:30", "04:30", context(sleep: [])) == nil)
        #expect(check("23:30", "00:30", day: "2026-10-18", toDay: "2026-10-19", context(sleep: [])) == nil)
    }

    /// ブロックが効いていない：始める前・選択が読めなくなっていた・許可が外れていた（DTX-03 の表の一番上の行）
    @Test func blockMustBeWorking() {
        #expect(check("09:00", "10:00", context(events: [])) == .notBlocking)
        let startedLate = context(events: [event(.started, "09:30")])
        #expect(check("09:00", "10:00", startedLate) == .notBlocking)
        #expect(check("09:30", "10:00", startedLate) == nil)
        let lost = context(events: [event(.started, "04:00", day: "2026-10-01"), event(.selectionLost, "09:30")])
        #expect(check("09:00", "10:00", lost) == .notBlocking)
        #expect(check("09:00", "09:30", lost) == nil)
        let unauthorized = context(events: [event(.started, "04:00", day: "2026-10-01"), event(.authorizationLost, "09:20"),
                                            event(.authorizationRestored, "09:40")])
        #expect(check("09:00", "10:00", unauthorized) == .notBlocking)
        #expect(check("09:40", "10:00", unauthorized) == nil)
        #expect(ManualRecord.Problem.notBlocking.message == "この時間はブロックが効いていなかったので記録できません")
    }

    /// 長押しで開けていた・ゲーム・SNS の時間を過ぎても開いていた（DTX-05 の開けた時間）
    @Test func openedTimeIsRefused() {
        let opened = context(events: [event(.started, "04:00", day: "2026-10-01"), event(.unlocked, "09:30"), event(.reblocked, "09:40")])
        #expect(check("09:00", "10:00", opened) == .opened)
        // 端が触れるだけならよい
        #expect(check("09:00", "09:30", opened) == nil)
        #expect(check("09:40", "10:00", opened) == nil)
        // ゲーム・SNS の時間を過ぎても開いていた
        let game = DateInterval(start: at("20:00", day: "2026-10-18"), end: at("20:30", day: "2026-10-18"))
        let overran = context(events: [event(.started, "04:00", day: "2026-10-01"), event(.unblockStarted, "20:00", day: "2026-10-18"),
                                       event(.unblockEnded, "20:50", day: "2026-10-18")], games: [game])
        #expect(check("20:30", "21:00", day: "2026-10-18", overran) == .opened)
        #expect(check("20:50", "21:00", day: "2026-10-18", overran) == nil)
        #expect(ManualRecord.Problem.opened.message == "この時間に開けていたので記録できません")
    }

    /// ゲーム・SNS の時間（予定の中）は、外していなくても記録できない
    @Test func gameTimeIsRefused() {
        let game = DateInterval(start: at("20:00", day: "2026-10-18"), end: at("20:30", day: "2026-10-18"))
        #expect(check("20:10", "20:40", day: "2026-10-18", context(games: [game])) == .gameTime)
        #expect(check("19:30", "20:00", day: "2026-10-18", context(games: [game])) == nil)
        #expect(check("20:30", "21:00", day: "2026-10-18", context(games: [game])) == nil)
        #expect(ManualRecord.Problem.gameTime.message == "ゲーム・SNS の時間は記録できません")
    }

    @Test func otherRecordsIncludingARunningTimerAreRefused() {
        let earlier = record("10:00", "10:20")
        let running = record("11:00", nil)
        let c = context(sessions: [earlier, running])
        #expect(check("09:50", "10:10", c) == .overlapsRecord)
        #expect(check("11:30", "11:40", c) == .overlapsRecord)
        // 端が触れるだけならよい
        #expect(check("09:40", "10:00", c) == nil)
        #expect(check("10:20", "11:00", c) == nil)
        // 直している記録そのものとは比べない
        #expect(check("09:50", "10:10", excluding: earlier.id, c) == nil)
        #expect(ManualRecord.Problem.overlapsRecord.message == "ほかの記録と重なっています")
    }

    @Test func sleepIsRefused() {
        #expect(check("06:30", "07:30") == .overlapsSleep)
        #expect(check("07:00", "08:00") == nil)
        #expect(ManualRecord.Problem.overlapsSleep.message == "寝ていた時間と重なっています（睡眠の時刻を直すと記録できます）")
    }

    // MARK: 計画のタブ：記録のない一番長い部分

    @Test func longestUnrecordedPartOfABlock() {
        let block = DateInterval(start: at("09:00"), end: at("10:30"))
        let now = at("12:00")
        // 記録がなければブロックの時刻そのまま
        #expect(ManualRecord.longestGap(in: block, sessions: [], now: now) == block)
        // 9:10:30〜9:40 に記録 → 9:40〜10:30 が一番長い。秒は内側へ1分に丸める
        let gap = ManualRecord.longestGap(in: block, sessions: [record("09:10:30", "09:40")], now: now)
        #expect(gap == DateInterval(start: at("09:40"), end: at("10:30")))
        let front = ManualRecord.longestGap(in: block, sessions: [record("09:20", "10:30:30")], now: now)
        #expect(front == DateInterval(start: at("09:00"), end: at("09:20")))
        let rounded = ManualRecord.longestGap(in: block, sessions: [record("08:00", "09:10:30"), record("09:50", "11:00")], now: now)
        #expect(rounded == DateInterval(start: at("09:11"), end: at("09:50")))
        // ほかのブロック・計画外の記録も「記録のある部分」。全部埋まっていれば出さない
        #expect(ManualRecord.longestGap(in: block, sessions: [record("08:59", "10:31")], now: now) == nil)
        // 1分に満たない隙間は出さない
        #expect(ManualRecord.longestGap(in: block, sessions: [record("09:00", "10:29:30")], now: now) == nil)
        // 実行中の記録は今まで
        #expect(ManualRecord.longestGap(in: DateInterval(start: at("11:00"), end: at("12:00")),
                                        sessions: [record("11:30", nil)], now: at("12:00"))
                == DateInterval(start: at("11:00"), end: at("11:30")))
    }

    // MARK: タイマーの画面：前の分を足す

    @Test func previousPartOfTheBlock() {
        let blockStart = at("11:00"), blockEnd = at("13:00")
        func part(_ timerStart: String, _ c: ManualRecord.Context? = nil, isGameTime: Bool = false) -> DateInterval? {
            ManualRecord.previousPart(blockStart: blockStart, blockEnd: blockEnd, isGameTime: isGameTime,
                                      timerStart: at(timerStart), context: c ?? context(now: "11:30"))
        }
        #expect(part("11:20") == DateInterval(start: blockStart, end: at("11:20")))
        // ブロックの開始から5分以上たって始めたときだけ
        #expect(part("11:04:59") == nil)
        #expect(part("11:05") == DateInterval(start: blockStart, end: at("11:05")))
        // 前倒しで始めた・終わってから始めた（「さっき」の行）・ゲーム・SNS の時間には出さない
        #expect(part("10:50") == nil)
        #expect(part("13:00") == nil)
        #expect(part("11:20", isGameTime: true) == nil)
        // 条件を満たさない（開けていた・同じブロックを一度止めてまた始めた）ときは出さない
        let opened = context(now: "11:30", events: [event(.started, "04:00", day: "2026-10-01"), event(.unlocked, "11:05"),
                                                    event(.reblocked, "11:08")])
        #expect(part("11:20", opened) == nil)
        #expect(part("11:20", context(now: "11:30", sessions: [record("11:00", "11:10")])) == nil)
    }

    // MARK: 点（0.8倍）

    @Test func manualFocusEarnsEightyPercent() {
        let timer = TimeSegment(start: jst("2026-10-19T09:00"), end: jst("2026-10-19T10:00"), countsAsFocus: true)
        var manual = timer
        manual.isDeclared = true
        let until = jst("2026-10-19T12:00")
        #expect(abs(FocusPoints.points([timer], until: until) - 6) < 0.0001)
        #expect(abs(FocusPoints.points([manual], until: until) - 4.8) < 0.0001)
    }

    /// タイマーの記録と5分未満の間でつながれば、続けて1回として1回の長さの倍率が進む
    @Test func manualJoinsATimerWithinFiveMinutes() {
        let timer = TimeSegment(start: jst("2026-10-19T09:00"), end: jst("2026-10-19T10:00"), countsAsFocus: true)
        func manual(_ from: String) -> TimeSegment {
            TimeSegment(start: jst("2026-10-19T\(from)"), end: jst("2026-10-19T11:00"), countsAsFocus: true, isDeclared: true)
        }
        let until = jst("2026-10-19T12:00")
        // 10:03〜11:00（57分）：90分までの30分は 3.0×0.8、残り27分は 2.7×0.75×0.8
        #expect(abs(FocusPoints.points([timer, manual("10:03")], until: until) - (6 + 2.4 + 1.62)) < 0.0001)
        // 10:05 からなら数え直し：55分 × 0.8
        #expect(abs(FocusPoints.points([timer, manual("10:05")], until: until) - (6 + 4.4)) < 0.0001)
    }

    private func detoxPoints(manual: Bool, until: String, interval: DateInterval) -> Double {
        let dayStart = jst("2026-10-19T04:00")
        return DetoxDay.make(.init(dayStart: dayStart, dayEnd: dayStart.addingTimeInterval(86400), until: jst("2026-10-19T\(until)"),
                                   events: [BlockEvent(occurredAt: dayStart.addingTimeInterval(-60), timeZoneId: zone, kind: .started)],
                                   focus: [], detoxTimers: [DetoxTimer(interval: interval, group: .housework, isDeclared: manual)],
                                   sleep: [], gameWindows: []))
            .points(until: jst("2026-10-19T\(until)"))
    }

    @Test func manualDetoxTimerEarnsZeroPointSixPerTenMinutes() {
        let interval = DateInterval(start: jst("2026-10-19T09:00"), end: jst("2026-10-19T09:30"))
        // 30分の家事：タイマーなら 2.25pt、手動なら 1.8pt（4:00〜9:00 のブロック中の点は同じ）
        #expect(abs(detoxPoints(manual: false, until: "09:30", interval: interval)
                    - detoxPoints(manual: true, until: "09:30", interval: interval) - 0.45) < 0.0001)
    }

    @Test func manualDetoxTimerUsesTheSameDailyCap() {
        let interval = DateInterval(start: jst("2026-10-19T09:00"), end: jst("2026-10-19T10:30"))
        // 家事の上限1時間：タイマーは 4.5＋1.5、手動は 3.6＋1.5（上限を超えた30分はどちらもブロック中の0.5pt）
        #expect(abs(detoxPoints(manual: false, until: "10:30", interval: interval)
                    - detoxPoints(manual: true, until: "10:30", interval: interval) - 0.9) < 0.0001)
    }

    /// あとから睡眠が重なっても（ヘルスケアで置き換わった・手で直した）、重なった時間は記録の点で数える
    @Test func sleepThatOverlapsLaterKeepsTheRecordPoints() throws {
        let dayStart = jst("2026-10-19T04:00")
        let interval = DateInterval(start: jst("2026-10-19T07:00"), end: jst("2026-10-19T08:00"))
        let sleep = [DateInterval(start: jst("2026-10-19T00:00"), end: jst("2026-10-19T07:30"))]
        let day = DetoxDay.make(.init(dayStart: dayStart, dayEnd: dayStart.addingTimeInterval(86400), until: jst("2026-10-19T09:00"),
                                      events: [BlockEvent(occurredAt: dayStart.addingTimeInterval(-60), timeZoneId: zone, kind: .started)],
                                      focus: [], detoxTimers: [DetoxTimer(interval: interval, group: .housework, isDeclared: true)],
                                      sleep: sleep, gameWindows: []))
        let overlap = try #require(day.pieces.first { $0.start == jst("2026-10-19T07:00") })
        #expect(overlap.kind == .detoxTimer)
        #expect(overlap.isDeclared)
        let focusDay = DetoxDay.make(.init(dayStart: dayStart, dayEnd: dayStart.addingTimeInterval(86400), until: jst("2026-10-19T09:00"),
                                           events: [BlockEvent(occurredAt: dayStart.addingTimeInterval(-60), timeZoneId: zone, kind: .started)],
                                           focus: [interval], detoxTimers: [], sleep: sleep, gameWindows: []))
        #expect(focusDay.pieces.first { $0.start == jst("2026-10-19T07:00") }?.kind == .focus)
    }

    /// 先週の自分のゴーストも、手動の分は0.8倍（今日の自分と同じに数える）
    @Test func lastWeekGhostKeepsTheManualMark() throws {
        var manual = FocusSession(id: UUID(), dayKey: "2026-10-12", category: study, planBlockId: nil,
                                  startAt: jst("2026-10-12T09:00"), endAt: jst("2026-10-12T10:00"))
        manual.isDeclared = true
        let ghost = try #require(GhostSummary(lastWeek: [manual], lastWeekStart: jst("2026-10-12T04:00"),
                                              todayStart: jst("2026-10-19T04:00")))
        #expect(ghost.segments.allSatisfy { $0.isDeclared })
        #expect(abs(FocusPoints.points(ghost.segments, until: jst("2026-10-19T12:00")) - 4.8) < 0.0001)
        // 集中した時間はそのまま
        #expect(ghost.focusSeconds(at: jst("2026-10-19T12:00")) == 3600)
    }

    /// タイムラインの行には「手動」と出す（2026-10-20 までに申告した記録も、同じ印なので「手動」）
    @Test func timelineSaysManual() {
        var manual = record("09:00", "10:00")
        manual.isDeclared = true
        let caption = sessionCaption(manual, now: at("12:00"))
        #expect(caption.contains("手動"))
        #expect(!caption.contains("申告"))
        #expect(!sessionCaption(record("09:00", "10:00"), now: at("12:00")).contains("手動"))
    }

    /// 手動の記録は今日と昨日なら、1分の記録でも直せる。タイマーの記録は今までどおり2分以上だけ
    @Test func manualRecordsCanBeEditedOnTodayAndYesterday() {
        let keys: Set<String> = ["2026-10-18", "2026-10-19"]
        var short = record("09:00", "09:01")
        #expect(!TimelineDay.canEdit(short, editableDayKeys: keys))
        short.isDeclared = true
        #expect(TimelineDay.canEdit(short, editableDayKeys: keys))
        var old = record("09:00", "10:00", day: "2026-10-17")
        old.isDeclared = true
        #expect(!TimelineDay.canEdit(old, editableDayKeys: keys))
    }
}

/// 本体（AppModel）とストアでの手動の記録
@MainActor
struct ManualRecordModelTests {
    /// ブロックを 10-01 から始めている本体。今日の計画（9:00〜10:30、11:00〜13:00 の勉強）を確定する
    private func confirmedPlan(_ t: TestStore, _ c: [CategoryOption], extra: [PlanBlockDraft] = []) throws -> AppModel {
        let m = try raceModelWithBlocking(t)
        m.confirmPlan(PlanDraft(blocks: [PlanBlockDraft(start: jst("2026-10-19T09:00"), minutes: 90, category: c[0]),
                                         PlanBlockDraft(start: jst("2026-10-19T11:00"), minutes: 120, category: c[0])] + extra))
        return m
    }

    private func sessions(_ t: TestStore, _ dayKey: String = "2026-10-19") throws -> [FocusSession] {
        try t.store.sessions(dayKey: dayKey).sorted { $0.startAt < $1.startAt }
    }

    // MARK: タイムラインから（計画外）

    @Test func timelineRecordIsUnplannedAndCountsAsFocus() throws {
        let t = try TestStore(now: jst("2026-10-19T07:00"))
        let c = try t.seeded()
        let m = try confirmedPlan(t, c)
        t.clock.set(jst("2026-10-19T12:00"))
        m.reload()
        let english = try #require(m.createProject(name: "英語", category: c[0]))
        #expect(m.addManual(category: english.category, project: english, start: jst("2026-10-19T07:00"),
                            end: jst("2026-10-19T08:00")) == .saved)
        let saved = try #require(try sessions(t).first)
        #expect(saved.isDeclared)
        #expect(saved.planBlockId == nil)
        #expect(saved.project == english)
        #expect(saved.dayKey == "2026-10-19")
        // 集中した時間（円・タイムライン）に入り、点は0.8倍
        #expect(m.snapshot.focusSeconds == 3600)
        #expect(m.timelineDay(daysAgo: 0)?.focusSeconds == 3600)
        #expect(abs(FocusPoints.points(try sessions(t).flatMap { $0.activeSegments(now: t.clock.now()) },
                                       until: t.clock.now()) - 4.8) < 0.0001)
    }

    @Test func detoxCategoriesCanBeRecordedToo() throws {
        let t = try TestStore(now: jst("2026-10-19T07:00"))
        let c = try t.seeded()
        let m = try confirmedPlan(t, c)
        t.clock.set(jst("2026-10-19T12:00"))
        m.reload()
        let housework = try t.category("家事")
        #expect(m.addManual(category: housework, project: nil, start: jst("2026-10-19T10:30"), end: jst("2026-10-19T11:00")) == .saved)
        #expect(m.snapshot.focusSeconds == 0)
        #expect(m.timelineDay(daysAgo: 0)?.detoxSeconds == 30 * 60)
    }

    /// 昨日の分も記録でき、昨日のポイントも変わる。一昨日の分は記録できない
    @Test func yesterdayCanBeRecordedAndChangesYesterday() throws {
        let t = try TestStore(now: jst("2026-10-19T12:00"))
        let c = try t.seeded()
        let m = try raceModelWithBlocking(t)
        let before = try #require(m.daySnapshot(daysAgo: 1))
        #expect(m.addManual(category: c[0], project: nil, start: jst("2026-10-18T20:00"), end: jst("2026-10-18T21:00")) == .saved)
        #expect(try sessions(t, "2026-10-18").count == 1)
        let after = try #require(m.daySnapshot(daysAgo: 1))
        #expect(after.focusSeconds - before.focusSeconds == 3600)
        #expect(after.points > before.points)
        #expect(m.addManual(category: c[0], project: nil, start: jst("2026-10-17T20:00"), end: jst("2026-10-17T21:00"))
                == .refused(.outOfRange))
        #expect(m.errorMessage == ManualRecord.Problem.outOfRange.message)
        #expect(try sessions(t, "2026-10-17").isEmpty)
    }

    @Test func initialTimesOnTheTimeline() throws {
        let t = try TestStore(now: jst("2026-10-19T12:00:40"))
        let c = try t.seeded()
        let m = try raceModelWithBlocking(t)
        // 今日：今の30分前〜今（分に切り捨て）
        #expect(m.manualInitial(daysAgo: 0) == DateInterval(start: jst("2026-10-19T11:30"), end: jst("2026-10-19T12:00")))
        // 昨日：記録がなければ起きた時刻（設定の 7:00）から30分
        #expect(m.manualInitial(daysAgo: 1) == DateInterval(start: jst("2026-10-18T07:00"), end: jst("2026-10-18T07:30")))
        // 昨日の最後の記録の終わりから30分（秒は切り上げ）
        #expect(m.addManual(category: c[0], project: nil, start: jst("2026-10-18T20:00"), end: jst("2026-10-18T21:10")) == .saved)
        #expect(m.manualInitial(daysAgo: 1) == DateInterval(start: jst("2026-10-18T21:10"), end: jst("2026-10-18T21:40")))
        // 選べるのは昨日の 4:00〜今
        #expect(m.manualRange() == jst("2026-10-18T04:00")...jst("2026-10-19T12:00"))
    }

    // MARK: 計画のタブ（ブロックの記録）

    @Test func planTabRecordsTheBlock() throws {
        let t = try TestStore(now: jst("2026-10-19T07:00"))
        let c = try t.seeded()
        let m = try confirmedPlan(t, c)
        t.clock.set(jst("2026-10-19T09:00"))
        m.reload()
        // 9:00〜9:40 はタイマーで記録した
        let first = try #require(m.snapshot.currentBlock)
        m.startPlanned(block: first)
        t.clock.set(jst("2026-10-19T09:40"))
        m.end(reportedEnd: nil)
        t.clock.set(jst("2026-10-19T10:40"))
        m.reload()
        let morning = try #require(m.plan?.sortedBlocks.first)
        // 記録のある部分を除いた一番長い部分（9:40〜10:30）
        #expect(m.manualStart(for: morning) == DateInterval(start: jst("2026-10-19T09:40"), end: jst("2026-10-19T10:30")))
        #expect(m.addManual(for: morning, start: jst("2026-10-19T09:40"), end: jst("2026-10-19T10:30")) == .saved)
        let saved = try #require(try sessions(t).last)
        #expect(saved.isDeclared)
        #expect(saved.planBlockId == morning.id)
        #expect(saved.category == morning.category)
        // 全部記録したら出さない
        #expect(m.manualStart(for: morning) == nil)
        // 終わっていないブロックには出さない
        let current = try #require(m.plan?.sortedBlocks.last)
        #expect(m.manualStart(for: current) == nil)
        // 手動の記録は計画どおりの点（80%）に数えない
        #expect(m.snapshot.planAwards.isEmpty)
    }

    /// 朝の計画にないブロック・ブロックの外へ出した時刻でも記録できる。ゲーム・SNS の時間には出さない
    @Test func blocksAddedLaterAndTimesOutsideTheBlock() throws {
        let t = try TestStore(now: jst("2026-10-19T07:00"))
        let c = try t.seeded()
        let m = try confirmedPlan(t, c)
        var plan = try #require(m.plan)
        let added = PlanBlockDraft(start: jst("2026-10-19T07:30"), minutes: 30, category: c[2])
        let game = PlanBlockDraft.unblock(start: jst("2026-10-19T08:00"))
        plan.upsert(added)
        plan.upsert(game)
        m.savePlanChanges(plan)
        t.clock.set(jst("2026-10-19T10:40"))
        m.reload()
        #expect(m.manualStart(for: added) == DateInterval(start: added.start, end: added.end))
        #expect(m.manualStart(for: game) == nil)
        #expect(m.addManual(for: added, start: jst("2026-10-19T07:20"), end: jst("2026-10-19T08:00")) == .saved)
        #expect(try sessions(t).first?.planBlockId == added.id)
        // ゲーム・SNS の時間にかかる時刻は保存できない
        let morning = try #require(m.plan?.sortedBlocks.first { $0.start == jst("2026-10-19T09:00") })
        #expect(m.addManual(for: morning, start: jst("2026-10-19T08:10"), end: jst("2026-10-19T09:30")) == .refused(.gameTime))
    }

    /// 日をまたぐブロック（23:30〜翌1:00）は 3:59 まで今日の計画のタブから記録でき、記録は始めた日の分
    @Test func blockAcrossMidnightCanBeRecordedUntilFourAm() throws {
        let t = try TestStore(now: jst("2026-10-19T07:00"))
        let c = try t.seeded()
        let m = try raceModelWithBlocking(t)
        m.setSleepSetting(startMinutes: 2 * 60, endMinutes: 7 * 60)
        m.confirmPlan(PlanDraft(blocks: [PlanBlockDraft(start: jst("2026-10-19T23:30"), minutes: 90, category: c[0])]))
        t.clock.set(jst("2026-10-20T01:59"))
        m.reload()
        let late = try #require(m.plan?.sortedBlocks.first)
        #expect(m.manualStart(for: late) == DateInterval(start: late.start, end: late.end))
        #expect(m.addManual(for: late, start: late.start, end: late.end) == .saved)
        #expect(try sessions(t).first?.isDeclared == true)
    }

    @Test func overARunningTimerIsRefused() throws {
        let t = try TestStore(now: jst("2026-10-19T07:00"))
        let c = try t.seeded()
        let m = try confirmedPlan(t, c)
        t.clock.set(jst("2026-10-19T09:30"))
        m.reload()
        m.startUnplanned(category: c[2], minutes: nil)
        t.clock.set(jst("2026-10-19T10:40"))
        m.reload()
        #expect(m.manualProblem(start: jst("2026-10-19T09:00"), end: jst("2026-10-19T10:30")) == .overlapsRecord)
        // 計画外のタイマーより前で終わるならよい
        #expect(m.manualProblem(start: jst("2026-10-19T09:00"), end: jst("2026-10-19T09:30")) == nil)
    }

    /// 保存するときにもう一度確かめる（画面を開いたまま 4:00 を過ぎた・その間に開けた）
    @Test func savingChecksAgain() throws {
        let t = try TestStore(now: jst("2026-10-19T12:00"))
        let c = try t.seeded()
        let m = try raceModelWithBlocking(t)
        // 開いたときは昨日の分として記録できた
        #expect(m.manualProblem(start: jst("2026-10-18T20:00"), end: jst("2026-10-18T21:00")) == nil)
        // 開いたまま4:00を過ぎると一昨日の分になる
        t.clock.set(jst("2026-10-20T04:01"))
        #expect(m.addManual(category: c[0], project: nil, start: jst("2026-10-18T20:00"), end: jst("2026-10-18T21:00"))
                == .refused(.outOfRange))
        #expect(try sessions(t, "2026-10-18").isEmpty)
    }

    @Test func openingWhileTheSheetIsOpenIsCheckedOnSave() throws {
        let t = try TestStore(now: jst("2026-10-19T12:00"))
        let c = try t.seeded()
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
        #expect(m.manualProblem(start: jst("2026-10-19T10:00"), end: jst("2026-10-19T11:00")) == nil)
        // 画面を開いている間に、その時間に開けていた記録が届いた（ブロックの画面の拡張が書く）
        try log.append(BlockEvent(occurredAt: jst("2026-10-19T10:20"), timeZoneId: "Asia/Tokyo", kind: .unlocked))
        try log.append(BlockEvent(occurredAt: jst("2026-10-19T10:30"), timeZoneId: "Asia/Tokyo", kind: .reblocked))
        #expect(m.addManual(category: c[0], project: nil, start: jst("2026-10-19T10:00"), end: jst("2026-10-19T11:00"))
                == .refused(.opened))
        #expect(m.errorMessage == ManualRecord.Problem.opened.message)
        #expect(try sessions(t).isEmpty)
    }

    @Test func saveFailureLeavesNothing() throws {
        let t = try TestStore(now: jst("2026-10-19T12:00"))
        let c = try t.seeded()
        let m = try raceModelWithBlocking(t)
        t.store.saveHook = { throw RecordError.notFound }
        #expect(m.addManual(category: c[0], project: nil, start: jst("2026-10-19T09:00"), end: jst("2026-10-19T10:00")) == .failed)
        #expect(m.errorMessage == AppModel.saveErrorMessage)
        t.store.saveHook = nil
        #expect(try sessions(t).isEmpty)
    }

    // MARK: タイマーの画面：前の分を足す

    @Test func addingThePreviousPartMovesTheTimerEnd() throws {
        let t = try TestStore(now: jst("2026-10-19T07:00"))
        let c = try t.seeded()
        let m = try confirmedPlan(t, c)
        t.clock.set(jst("2026-10-19T11:20"))
        m.reload()
        let block = try #require(m.snapshot.currentBlock)
        // ホームの開始は聞かずに今から（終わりは計画の長さぶんずれる、TMR-15）
        m.startPlanned(block: block)
        #expect(try sessions(t).count == 1)
        #expect(m.running?.session.plannedEndAt == jst("2026-10-19T13:20"))
        #expect(m.previousPart == DateInterval(start: jst("2026-10-19T11:00"), end: jst("2026-10-19T11:20")))
        // 一時停止中も出す
        t.clock.set(jst("2026-10-19T11:25"))
        m.pause()
        #expect(m.previousPart != nil)
        #expect(m.addPreviousPart(from: jst("2026-10-19T11:00")) == .saved)
        let all = try sessions(t)
        #expect(all.count == 2)
        #expect(all[0].isDeclared && all[0].startAt == jst("2026-10-19T11:00") && all[0].endAt == jst("2026-10-19T11:20"))
        #expect(all[0].planBlockId == block.id)
        #expect(!all[1].isDeclared && all[1].isRunning)
        // 終わりは「足した開始＋始めた時点のブロックの長さ」
        #expect(m.running?.session.plannedEndAt == jst("2026-10-19T13:00"))
        // 足したら行は消える
        #expect(m.previousPart == nil)
    }

    /// 開始を遅くすると、その分だけ終わりも遅い。開始より前・終わりの1分前より後は選べない
    @Test func previousPartWithALaterStart() throws {
        let t = try TestStore(now: jst("2026-10-19T07:00"))
        let c = try t.seeded()
        let m = try confirmedPlan(t, c)
        t.clock.set(jst("2026-10-19T11:20"))
        m.reload()
        m.startPlanned(block: try #require(m.snapshot.currentBlock))
        #expect(m.addPreviousPart(from: jst("2026-10-19T10:50")) == .refused(.outOfRange))
        #expect(m.addPreviousPart(from: jst("2026-10-19T11:19:30")) == .refused(.tooShort))
        #expect(m.addPreviousPart(from: jst("2026-10-19T11:10")) == .saved)
        #expect(m.running?.session.plannedEndAt == jst("2026-10-19T13:10"))
        #expect(try sessions(t).first?.startAt == jst("2026-10-19T11:10"))
    }

    @Test func previousPartIsNotOfferedForUnplannedOrLateOrEarlyTimers() throws {
        let t = try TestStore(now: jst("2026-10-19T07:00"))
        let c = try t.seeded()
        let m = try confirmedPlan(t, c)
        // 計画外のタイマー
        t.clock.set(jst("2026-10-19T11:20"))
        m.reload()
        m.startUnplanned(category: c[0], minutes: 30)
        #expect(m.previousPart == nil)
        #expect(m.addPreviousPart(from: jst("2026-10-19T11:00")) != .saved)
        t.clock.set(jst("2026-10-19T11:25"))
        m.end(reportedEnd: nil)
        // 計画外の記録のあとで同じブロックを始めても、前の分には記録があるので出さない
        m.startPlanned(block: try #require(m.snapshot.currentBlock))
        #expect(m.previousPart == nil)
    }

    @Test func previousPartIsNotOfferedWithinFiveMinutes() throws {
        let t = try TestStore(now: jst("2026-10-19T07:00"))
        let c = try t.seeded()
        let m = try confirmedPlan(t, c)
        t.clock.set(jst("2026-10-19T11:04"))
        m.reload()
        m.startPlanned(block: try #require(m.snapshot.currentBlock))
        #expect(m.previousPart == nil)
    }

    // MARK: 直す・消す（タイムライン）

    @Test func manualRecordsCanBeMovedAndDeleted() throws {
        let t = try TestStore(now: jst("2026-10-19T12:00"))
        let c = try t.seeded()
        let m = try raceModelWithBlocking(t)
        #expect(m.addManual(category: c[0], project: nil, start: jst("2026-10-19T09:00"), end: jst("2026-10-19T10:00")) == .saved)
        #expect(m.addManual(category: c[0], project: nil, start: jst("2026-10-19T10:30"), end: jst("2026-10-19T11:00")) == .saved)
        let first = try #require(try sessions(t).first)
        // 開始・終わりをどちらにも変えられる
        #expect(m.updateManual(first, start: jst("2026-10-19T08:30"), end: jst("2026-10-19T10:15")) == .saved)
        var moved = try #require(try sessions(t).first)
        #expect(moved.startAt == jst("2026-10-19T08:30") && moved.endAt == jst("2026-10-19T10:15"))
        #expect(moved.isDeclared && moved.id == first.id)
        #expect(m.snapshot.focusSeconds == 105 * 60 + 30 * 60)
        // ほかの記録と重なるときは理由を出して変えない
        #expect(m.updateManual(moved, start: jst("2026-10-19T08:30"), end: jst("2026-10-19T10:45")) == .refused(.overlapsRecord))
        moved = try #require(try sessions(t).first)
        #expect(moved.endAt == jst("2026-10-19T10:15"))
        // 消すと実際に削除し、集中した時間から外れる
        #expect(m.deleteManual(moved))
        #expect(try sessions(t).count == 1)
        #expect(m.snapshot.focusSeconds == 30 * 60)
    }

    /// 昨日の手動の記録を直すと、開始で日を決め直す。タイマーの記録は消せない・手動として直せない
    @Test func timerRecordsAreNotManual() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        let c = try t.seeded()
        let m = try raceModelWithBlocking(t)
        m.startUnplanned(category: c[0], minutes: nil)
        t.clock.set(jst("2026-10-19T09:30"))
        m.end(reportedEnd: nil)
        let timer = try #require(try sessions(t).first)
        #expect(!m.deleteManual(timer))
        #expect(m.updateManual(timer, start: jst("2026-10-19T08:00"), end: jst("2026-10-19T09:30")) == .failed)
        #expect(try sessions(t).count == 1)
        #expect(try sessions(t).first?.startAt == jst("2026-10-19T09:00"))
    }

    @Test func editingMovesTheDayAndOnlyTodayAndYesterday() throws {
        let t = try TestStore(now: jst("2026-10-19T12:00"))
        let c = try t.seeded()
        let m = try raceModelWithBlocking(t)
        // 今朝の睡眠を 5:00〜7:00 に直す（3:00〜4:30 は起きていた）
        #expect(m.setSleepManually(start: jst("2026-10-19T05:00"), end: jst("2026-10-19T07:00")))
        #expect(m.addManual(category: c[0], project: nil, start: jst("2026-10-19T03:00"), end: jst("2026-10-19T03:50")) == .saved)
        let record = try #require(try sessions(t, "2026-10-18").first)
        // 開始を 4:00 より後に動かすと今日の記録になる
        #expect(m.updateManual(record, start: jst("2026-10-19T03:50"), end: jst("2026-10-19T04:30")) == .saved)
        #expect(try sessions(t, "2026-10-18").first?.startAt == jst("2026-10-19T03:50"))
        let moved = try #require(try sessions(t, "2026-10-18").first)
        #expect(m.updateManual(moved, start: jst("2026-10-19T04:10"), end: jst("2026-10-19T04:30")) == .saved)
        #expect(try sessions(t, "2026-10-18").isEmpty)
        #expect(try sessions(t, "2026-10-19").count == 1)
        // 一昨日より前になった記録は直せない・消せない
        let today = try #require(try sessions(t, "2026-10-19").first)
        t.clock.set(jst("2026-10-21T04:00"))
        #expect(m.updateManual(today, start: jst("2026-10-19T04:10"), end: jst("2026-10-19T04:20")) == .refused(.outOfRange))
        #expect(m.errorMessage == AppModel.cannotEditMessage)
        #expect(!m.deleteManual(today))
        #expect(try sessions(t, "2026-10-19").count == 1)
    }

    /// 第4版の記録が第5版で読め、手動の印は空（タイマーの記録）
    @Test func version4StoreOpensWithVersion5() throws {
        let url = temporaryStoreURL()
        defer { removeStoreFiles(url) }
        let now = jst("2026-10-19T09:00")
        let sessionId = UUID(), categoryId = UUID()
        do {
            let schema = Schema(versionedSchema: SchemaV4.self)
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url,
                                                                                               cloudKitDatabase: .none))
            let context = ModelContext(container)
            context.insert(SchemaV4.CategoryRecord(id: categoryId, name: "勉強", countsAsFocus: true, sortOrder: 0, at: now))
            let session = SchemaV4.FocusSessionRecord(id: sessionId, dayKey: "2026-10-19", timeZoneId: "Asia/Tokyo",
                                                      planBlockId: nil, categoryId: categoryId, countsAsFocus: true,
                                                      projectId: nil, startAt: jst("2026-10-19T08:00"),
                                                      plannedEndAt: nil, plannedDurationSec: nil, at: now)
            session.endAt = jst("2026-10-19T08:40")
            context.insert(session)
            try context.save()
        }
        let container = try AppStore.makeContainer(url: url)
        let store = SwiftDataStore(container: container, clock: FixedClock(date: now))
        let sessions = try store.sessions(dayKey: "2026-10-19")
        #expect(sessions.map(\.id) == [sessionId])
        #expect(sessions.first?.isDeclared == false)
    }
}
