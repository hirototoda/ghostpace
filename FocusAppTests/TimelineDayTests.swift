import Foundation
import Testing
@testable import FocusApp

struct TimelineDayTests {
    private let c = DefaultCategories.all

    private func block(_ start: String, _ minutes: Int, _ category: CategoryOption) -> PlanBlockSummary {
        PlanDraft(blocks: [PlanBlockDraft(start: jst(start), minutes: minutes, category: category)]).summaries[0]
    }

    private func day(blocks: [PlanBlockSummary] = [], sessions: [FocusSession], now: String = "2026-10-19T12:00") -> TimelineDay {
        TimelineDay(dayKey: "2026-10-19", dayStart: jst("2026-10-19T04:00"), now: jst(now), isToday: true, planBlocks: blocks,
                    isNoPlanDay: blocks.isEmpty, sessions: sessions, editableDayKeys: ["2026-10-19", "2026-10-18"])
    }

    @Test func sessionsAreGroupedByBlock() {
        let english = block("2026-10-19T09:00", 90, c[0])
        var fromBlock = session("2026-10-19T09:00", "2026-10-19T09:45")
        fromBlock.planBlockId = english.id
        var removedBlock = session("2026-10-19T10:00", "2026-10-19T10:30")
        removedBlock.planBlockId = UUID()  // 日中に消したブロックから始めた記録
        let unplanned = session("2026-10-19T11:00", "2026-10-19T11:30", category: c[4])

        let d = day(blocks: [english], sessions: [fromBlock, removedBlock, unplanned])
        #expect(d.sessions(of: english).map(\.id) == [fromBlock.id])
        #expect(d.unplannedSessions.map(\.id) == [removedBlock.id, unplanned.id])
    }

    @Test func achievementIsActiveTimeOverPlannedLength() {
        let english = block("2026-10-19T09:00", 60, c[0])
        var a = session("2026-10-19T09:00", "2026-10-19T09:30", pauses: [("2026-10-19T09:10", "2026-10-19T09:15")])
        a.planBlockId = english.id
        var b = session("2026-10-19T09:40", "2026-10-19T10:30")  // ブロックの外まで続いた
        b.planBlockId = english.id
        let d = day(blocks: [english], sessions: [a, b])
        // (25分 + 50分) ÷ 60分
        #expect(d.achievementPercent(of: english) == 125)
        #expect(d.actualSeconds(of: english) == 75 * 60)
    }

    @Test func achievementOfFutureBlockWithoutRecordsIsNil() {
        let later = block("2026-10-19T14:00", 60, c[0])
        let started = block("2026-10-19T11:00", 120, c[0])
        let d = day(blocks: [later, started], sessions: [])
        #expect(d.achievementPercent(of: later) == nil)
        #expect(d.achievementPercent(of: started) == 0)
    }

    @Test func achievementCountsRunningSessionUntilNow() {
        let block = block("2026-10-19T11:00", 120, c[0])
        var running = session("2026-10-19T11:30", nil)
        running.planBlockId = block.id
        #expect(day(blocks: [block], sessions: [running]).achievementPercent(of: block) == 25)
    }

    @Test func totalsExcludePausesAndSplitDetox() {
        let d = day(sessions: [
            session("2026-10-19T09:00", "2026-10-19T10:00", pauses: [("2026-10-19T09:10", "2026-10-19T09:20")]),
            session("2026-10-19T10:00", "2026-10-19T10:30", category: c[4]),
            session("2026-10-19T11:30", nil),  // 実行中は今（12:00）まで
        ])
        #expect(d.focusSeconds == (50 + 30) * 60)
        #expect(d.detoxSeconds == 30 * 60)
    }

    @Test func onlyEndedSessionsOfTodayAndYesterdayCanBeEdited() {
        let d = day(sessions: [])
        #expect(d.canEdit(session("2026-10-19T09:00", "2026-10-19T10:00")))
        #expect(d.canEdit(session("2026-10-18T09:00", "2026-10-18T10:00")))
        #expect(!d.canEdit(session("2026-10-17T09:00", "2026-10-17T10:00")))
        #expect(!d.canEdit(session("2026-10-19T09:00", nil)))
        // 開始から2分未満は選べる時刻がないので直せない
        #expect(!d.canEdit(session("2026-10-19T09:00", "2026-10-19T09:01:59")))
        #expect(d.canEdit(session("2026-10-19T09:00", "2026-10-19T09:02")))
        // 10/19 3:59 開始は 10/18 の記録
        #expect(d.canEdit(session("2026-10-19T03:59", "2026-10-19T04:30")))
    }

}
