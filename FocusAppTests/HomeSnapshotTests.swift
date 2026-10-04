import Foundation
import Testing
@testable import FocusApp

struct HomeSnapshotTests {
    private let calendar = tokyoCalendar
    private let c = DefaultCategories.all

    /// 10/19（月）の記録。7:30–8:15 と 9:00–9:45 が集中、8:15–8:45 はデトックス（休み）など
    private func today(until now: Date) -> [FocusSession] {
        [
            session("2026-10-19T07:30", "2026-10-19T08:15", category: c[2]),
            session("2026-10-19T08:15", "2026-10-19T08:45", category: c[4]),
            session("2026-10-19T09:00", "2026-10-19T09:45"),
            session("2026-10-19T14:00", "2026-10-19T15:40", category: c[1]),
            session("2026-10-19T16:00", "2026-10-19T16:50", category: c[5]),
            session("2026-10-19T19:10", "2026-10-19T20:00", category: c[2]),
        ].filter { $0.startAt < now }
    }

    /// 先週（10/12）の記録
    private let lastWeek = [
        session("2026-10-12T08:00", "2026-10-12T08:40"),
        session("2026-10-12T09:30", "2026-10-12T09:55"),
        session("2026-10-12T12:00", "2026-10-12T12:30", category: DefaultCategories.all[4]),
        session("2026-10-12T13:00", "2026-10-12T15:00"),
    ]

    private func plan() -> PlanDraft {
        let seminar = ProjectOption(id: UUID(), name: "ゼミ準備", category: c[0])
        let thesis = ProjectOption(id: UUID(), name: "卒論", category: c[1])
        func block(_ start: String, _ minutes: Int, _ category: CategoryOption, _ project: ProjectOption? = nil) -> PlanBlockDraft {
            PlanBlockDraft(start: jst(start), minutes: minutes, category: category, project: project)
        }
        return PlanDraft(blocks: [
            block("2026-10-19T07:30", 60, c[2]),
            block("2026-10-19T09:00", 90, c[0]),
            block("2026-10-19T11:00", 120, c[0], seminar),
            block("2026-10-19T14:00", 120, c[1], thesis),
            block("2026-10-19T16:00", 60, c[5]),
            block("2026-10-19T19:00", 60, c[2]),
        ])
    }

    private func snapshot(_ now: String, sessions: [FocusSession]? = nil, plan: PlanDraft?? = nil,
                          lastWeek: [FocusSession]? = nil) -> HomeSnapshot {
        let date = jst(now)
        return HomeSnapshot.make(now: date, calendar: calendar,
                                 todaySessions: sessions ?? today(until: date),
                                 plan: plan ?? self.plan(),
                                 lastWeekSessions: lastWeek ?? self.lastWeek)
    }

    @Test func focusExcludesDetoxAndCountsOnlyUntilNow() {
        let s = snapshot("2026-10-19T11:20")
        #expect(s.focusSeconds == 90 * 60)
        // 開けた時間はブロックの記録から（DTX-05）。ブロックの記録がなければ出さない（休みのタイマーは関係ない）
        #expect(s.opened == nil)
    }

    @Test func sessionInProgressCountsUpToNow() {
        let running = session("2026-10-19T09:00", nil, pauses: [("2026-10-19T09:05", "2026-10-19T09:08")])
        let s = snapshot("2026-10-19T09:15", sessions: [running])
        #expect(s.focusSeconds == 12 * 60)
    }

    @Test func ghostDiffComparesSameTimeOfDay() {
        // 先週は 11:20 時点で 8:00–8:40 と 9:30–9:55 の 65分
        let s = snapshot("2026-10-19T11:20")
        #expect(s.ghostFocusSeconds == 65 * 60)
        #expect(s.ghostDiffSeconds == 25 * 60)
        // 1周＝先週の1日分の集中
        #expect(s.ghost?.wholeDayFocusSeconds == (40 + 25 + 120) * 60)
    }

    @Test func ghostNilWhenNoSessionsLastWeek() {
        let s = snapshot("2026-10-19T11:20", lastWeek: [])
        #expect(s.ghost == nil)
        #expect(s.ghostDiffSeconds == nil)
    }

    @Test func ghostExcludesPauses() {
        let paused = session("2026-10-12T08:00", "2026-10-12T09:00", pauses: [("2026-10-12T08:10", "2026-10-12T08:40")])
        let s = snapshot("2026-10-19T11:20", lastWeek: [paused])
        #expect(s.ghostFocusSeconds == 30 * 60)
    }

    @Test func ghostClipsAt24Hours() {
        // 先週 4:30 開始、翌 5:00 終了（24時間半）→ 翌 4:00 で切る
        let long = session("2026-10-12T04:30", "2026-10-13T05:00")
        let s = snapshot("2026-10-19T11:20", lastWeek: [long])
        #expect(s.ghost?.wholeDayFocusSeconds == (23 * 60 + 30) * 60)
    }

    @Test func currentAndNextBlock() {
        let s = snapshot("2026-10-19T11:20")
        #expect(s.currentBlock?.title == "ゼミ準備")
        #expect(s.nextBlock?.title == "卒論")

        let between = snapshot("2026-10-19T10:40")
        #expect(between.currentBlock == nil)
        #expect(between.nextBlock?.title == "ゼミ準備")
    }

    @Test func plannedFocusExcludesDetoxBlocks() {
        // 読書1h + 勉強1.5h + ゼミ準備2h + 卒論2h + 読書1h（運動は除く）
        #expect(snapshot("2026-10-19T11:20").plannedFocusSeconds == Int(7.5 * 3600))
    }

    @Test func reviewEntryAppearsFrom22() {
        #expect(!snapshot("2026-10-19T21:59").showsReviewEntry)
        #expect(snapshot("2026-10-19T22:00").showsReviewEntry)
        // 日付が変わっても 4:00 までは同じ日の夜
        #expect(snapshot("2026-10-20T01:00", sessions: [], lastWeek: []).showsReviewEntry)
    }

    @Test func skippedPlanIsNoPlanDay() {
        let s = snapshot("2026-10-19T11:20", plan: .some(nil))
        #expect(s.isNoPlanDay)
        #expect(s.currentBlock == nil)
    }

    @Test func dayStartIsFourAM() {
        #expect(snapshot("2026-10-20T01:00", sessions: [], lastWeek: []).dayStart == jst("2026-10-19T04:00"))
    }
}
