import Foundation
import Testing
@testable import FocusApp

/// 計画のテンプレート（PLN-07）。
struct PlanTemplateTests {
    private let calendar = tokyoCalendar
    private let c = DefaultCategories.all

    @Test func appliesHourAndMinuteToTheDay() {
        let template = PlanTemplate(name: "t", blocks: [.init(hour: 9, minute: 30, minutes: 60, category: c[0])])
        let draft = template.draft(dayStart: jst("2026-10-19T04:00"), calendar: calendar)
        #expect(draft.blocks.first?.start == jst("2026-10-19T09:30"))
        #expect(draft.blocks.first?.end == jst("2026-10-19T10:30"))
    }

    @Test func afterMidnightGoesToTheNextCalendarDay() {
        // 1:00 は朝4:00区切りなので、その日の終わり（翌日の暦の1:00）
        let template = PlanTemplate(name: "t", blocks: [.init(hour: 1, minute: 0, minutes: 30, category: c[2])])
        let draft = template.draft(dayStart: jst("2026-10-19T04:00"), calendar: calendar)
        #expect(draft.blocks.first?.start == jst("2026-10-20T01:00"))
    }

    @Test func roundTripsFromAPlan() {
        let plan = PlanDraft(blocks: [PlanBlockDraft(start: jst("2026-10-19T13:30"), minutes: 45, category: c[3]),
                                      PlanBlockDraft(start: jst("2026-10-19T07:00"), minutes: 15, category: c[4])])
        let template = PlanTemplate(name: "休日", plan: plan, calendar: calendar)
        #expect(template.blocks.map(\.hour) == [7, 13])
        let draft = template.draft(dayStart: jst("2026-10-26T04:00"), calendar: calendar)
        #expect(draft.sortedBlocks.map(\.start) == [jst("2026-10-26T07:00"), jst("2026-10-26T13:30")])
        #expect(draft.focusSeconds == 0)
        #expect(draft.detoxSeconds == 60 * 60)
    }

    @Test func idealHolidayHasFiveBlocks() {
        let template = PlanTemplate.idealHoliday(categories: c)
        #expect(template.blocks.count == 5)
        #expect(template.focusSeconds == 4 * 3600)  // 勉強3時間＋読書1時間
        #expect(template.detoxSeconds == (15 + 60 + 30) * 60)
    }

    @Test func blocksAfterMidnightSortLast() {
        let template = PlanTemplate(name: "夜更かし", blocks: [
            .init(hour: 1, minute: 0, minutes: 30, category: c[2]),
            .init(hour: 23, minute: 0, minutes: 60, category: c[0]),
            .init(hour: 4, minute: 0, minutes: 30, category: c[4]),
        ])
        #expect(template.sortedBlocks.map(\.hour) == [4, 23, 1])
    }
}

/// 日中にテンプレートで進める（今から先だけ置き換える）
struct ReplaceFutureTests {
    private let c = DefaultCategories.all

    private func block(_ start: String, _ minutes: Int, _ category: CategoryOption) -> PlanBlockDraft {
        PlanBlockDraft(start: jst("2026-10-19T" + start), minutes: minutes, category: category)
    }

    private var today: PlanDraft {
        var plan = PlanDraft(blocks: [block("07:30", 60, c[2]), block("09:00", 90, c[0]), block("11:00", 120, c[0]),
                                      block("14:00", 120, c[1]), block("19:00", 60, c[2])])
        plan.goalSeconds = 8 * 3600
        return plan
    }

    /// 理想の休日を今日に当てはめたもの
    private var holiday: PlanDraft {
        PlanDraft(blocks: [block("07:00", 15, c[4]), block("07:30", 60, c[5]), block("09:00", 180, c[0]),
                           block("13:30", 30, c[3]), block("20:00", 60, c[2])])
    }

    @Test func keepsStartedBlocksAndAddsFutureOnes() {
        let result = today.replacingFuture(with: holiday, now: jst("2026-10-19T11:20"))
        let times = result.sortedBlocks.map { timeRange($0.start, $0.end) }
        // 7:30 読書・9:00 英語・11:00 ゼミ準備は残る。14:00・19:00 は外れ、13:30 掃除と 20:00 読書が入る
        #expect(times == ["07:30–08:30", "09:00–10:30", "11:00–13:00", "13:30–14:00", "20:00–21:00"])
        #expect(result.goalSeconds == 8 * 3600)
    }

    @Test func templateBlocksOverlappingTheCurrentBlockAreSkipped() {
        // 12:00 に始まるテンプレートのブロックは、今の 11:00–13:00 と重なるので入れない
        let template = PlanDraft(blocks: [block("12:00", 60, c[0]), block("15:00", 60, c[0])])
        let result = today.replacingFuture(with: template, now: jst("2026-10-19T11:20"))
        #expect(result.sortedBlocks.map(\.start).last == jst("2026-10-19T15:00"))
        #expect(!result.blocks.contains { $0.start == jst("2026-10-19T12:00") })
    }

    @Test func blockStartingExactlyNowIsKept() {
        let result = today.replacingFuture(with: holiday, now: jst("2026-10-19T14:00"))
        #expect(result.blocks.contains { $0.start == jst("2026-10-19T14:00") })
        #expect(!result.blocks.contains { $0.start == jst("2026-10-19T19:00") })
    }
}
