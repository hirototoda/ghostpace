import Foundation
import Testing
@testable import FocusApp

struct PlanDraftTests {
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    private func jst(_ text: String) -> Date { LaunchOptions.parseDate(text, timeZone: tokyo)! }
    private var dayStart: Date { jst("2026-10-19T04:00") }
    private let study = DefaultCategories.all[0]
    private let exercise = DefaultCategories.all[5]

    private func block(_ start: String, _ minutes: Int, _ category: CategoryOption? = nil) -> PlanBlockDraft {
        PlanBlockDraft(start: jst(start), minutes: minutes, category: category ?? study)
    }

    @Test func nextStartIsEndOfLastBlock() {
        let plan = PlanDraft(blocks: [block("2026-10-19T09:00", 90), block("2026-10-19T11:00", 120)])
        #expect(plan.nextStart(now: jst("2026-10-19T07:00")) == jst("2026-10-19T13:00"))
    }

    @Test func nextStartOfEmptyPlanIsNowRoundedUpToFiveMinutes() {
        #expect(PlanDraft().nextStart(now: jst("2026-10-19T07:02")) == jst("2026-10-19T07:05"))
        #expect(PlanDraft().nextStart(now: jst("2026-10-19T07:05")) == jst("2026-10-19T07:05"))
    }

    /// 開始時刻は5分刻みで選ぶ。前の1分刻みで入れた時刻は、編集を開いたとき近い5分に合わせる
    @Test func startIsRoundedToNearestFiveMinutes() {
        #expect(PlanDraft.roundedToStep(jst("2026-10-19T09:02")) == jst("2026-10-19T09:00"))
        #expect(PlanDraft.roundedToStep(jst("2026-10-19T09:03")) == jst("2026-10-19T09:05"))
        #expect(PlanDraft.roundedToStep(jst("2026-10-19T09:05")) == jst("2026-10-19T09:05"))
        #expect(PlanDraft.roundedToStep(jst("2026-10-19T09:58")) == jst("2026-10-19T10:00"))
        #expect(PlanDraft.roundedToStep(jst("2026-10-19T03:58")) == jst("2026-10-19T04:00"))
        #expect(PlanDraft.roundedToStep(jst("2026-10-19T09:02").addingTimeInterval(45)) == jst("2026-10-19T09:05"))
    }

    @Test func overlappingBlockCannotBeSaved() {
        let plan = PlanDraft(blocks: [block("2026-10-19T09:00", 90)])
        let problem = plan.problem(with: block("2026-10-19T10:00", 60), dayStart: dayStart)
        #expect(problem?.contains("重なっています") == true)
    }

    @Test func touchingBlocksDoNotOverlap() {
        let plan = PlanDraft(blocks: [block("2026-10-19T09:00", 90)])
        #expect(plan.problem(with: block("2026-10-19T10:30", 60), dayStart: dayStart) == nil)
    }

    @Test func editingABlockDoesNotConflictWithItself() {
        let existing = block("2026-10-19T09:00", 90)
        var moved = existing
        moved.minutes = 120
        #expect(PlanDraft(blocks: [existing]).problem(with: moved, dayStart: dayStart) == nil)
    }

    @Test func blockCannotCrossTheDayBoundary() {
        let problem = PlanDraft().problem(with: block("2026-10-20T03:00", 90), dayStart: dayStart)
        #expect(problem?.contains("4:00") == true)
    }

    @Test func upsertAndRemove() {
        var plan = PlanDraft()
        var b = block("2026-10-19T09:00", 60)
        plan.upsert(b)
        b.minutes = 30
        plan.upsert(b)
        #expect(plan.blocks.count == 1)
        #expect(plan.blocks[0].minutes == 30)
        plan.remove(id: b.id)
        #expect(plan.blocks.isEmpty)
    }

    @Test func totalsSplitFocusAndDetox() {
        let plan = PlanDraft(blocks: [block("2026-10-19T09:00", 90), block("2026-10-19T16:00", 60, exercise)])
        #expect(plan.focusSeconds == 90 * 60)
        #expect(plan.detoxSeconds == 60 * 60)
    }

    @Test func titleIsProjectNameOrCategoryName() {
        var b = block("2026-10-19T09:00", 60)
        #expect(b.title == "勉強")
        b.project = ProjectOption(id: UUID(), name: "ゼミ準備", category: study)
        #expect(b.title == "ゼミ準備")
    }
}
