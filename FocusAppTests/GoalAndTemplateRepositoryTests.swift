import Foundation
import SwiftData
import Testing
@testable import FocusApp

/// 目標（GHO-10）とテンプレート（PLN-07）の保存。
@MainActor
struct GoalAndTemplateRepositoryTests {
    private func block(_ start: String, _ minutes: Int, _ category: CategoryOption) -> PlanBlockDraft {
        PlanBlockDraft(start: jst(start), minutes: minutes, category: category)
    }

    // MARK: 目標

    @Test func goalIsSavedWithDraftConfirmAndChanges() throws {
        let t = try TestStore()
        let c = try t.seeded()
        var draft = PlanDraft(blocks: [block("2026-10-19T09:00", 60, c[0])])
        draft.goalSeconds = 3 * 3600
        try t.store.saveDraft(draft, dayKey: "2026-10-19", timeZone: tokyo)
        #expect(try t.store.plan(dayKey: "2026-10-19")?.draft.goalSeconds == 3 * 3600)

        draft.goalSeconds = 4 * 3600
        try t.store.confirm(draft, dayKey: "2026-10-19", timeZone: tokyo)
        #expect(try t.store.plan(dayKey: "2026-10-19")?.draft.goalSeconds == 4 * 3600)

        draft.goalSeconds = nil  // 計画に合わせて動く状態に戻す
        try t.store.saveChanges(draft, dayKey: "2026-10-19")
        #expect(try t.store.plan(dayKey: "2026-10-19")?.draft.goalSeconds == nil)
    }

    @Test func goalOnNoPlanDay() throws {
        let t = try TestStore()
        try t.seeded()
        try t.store.skip(dayKey: "2026-10-19", timeZone: tokyo)
        try t.store.setGoal(6 * 3600, dayKey: "2026-10-19")
        let stored = try #require(try t.store.plan(dayKey: "2026-10-19"))
        #expect(stored.status == .skipped)
        #expect(stored.draft.goalSeconds == 6 * 3600)
        #expect(throws: RecordError.notFound) { try t.store.setGoal(60, dayKey: "2026-10-20") }
    }

    // MARK: テンプレート

    @Test func idealHolidaySeededOnce() throws {
        let t = try TestStore()
        let c = try t.seeded()
        #expect(try t.store.seedTemplatesIfNeeded())
        #expect(try !t.store.seedTemplatesIfNeeded())
        let templates = try t.store.templates()
        #expect(templates.map(\.name) == ["理想の休日"])
        #expect(templates.first?.blocks.count == 5)
        // 2026-10-03 から瞑想は休みのブロック名
        #expect(templates.first?.blocks.first?.category == c.first { $0.name == "休み" })
        #expect(templates.first?.blocks.first?.project?.name == "瞑想")
    }

    @Test func saveRenameEditAndDeleteTemplate() throws {
        let t = try TestStore()
        let c = try t.seeded()
        let project = try #require(try t.store.createProject(name: "英語", category: c[0]))
        var template = PlanTemplate(name: "平日", blocks: [
            .init(hour: 9, minute: 0, minutes: 90, category: c[0], project: project),
            .init(hour: 7, minute: 30, minutes: 60, category: c[2]),
        ])
        try t.store.saveTemplate(template)
        #expect(try t.store.templates().first?.blocks.map(\.hour) == [7, 9])  // 時刻順
        #expect(try t.store.templates().first?.blocks.last?.project == project)

        template.name = " 平日（授業） "
        template.blocks.removeLast()
        try t.store.saveTemplate(template)
        let saved = try #require(try t.store.templates().first)
        #expect(saved.name == "平日（授業）")
        #expect(saved.blocks.count == 1)

        try t.store.deleteTemplate(id: template.id)
        #expect(try t.store.templates().isEmpty)
    }

    @Test func atMostSevenTemplates() throws {
        let t = try TestStore()
        let c = try t.seeded()
        for i in 1...7 {
            try t.store.saveTemplate(PlanTemplate(name: "t\(i)", blocks: [.init(hour: 9, minute: 0, minutes: 60, category: c[0])]))
        }
        #expect(throws: RecordError.tooManyTemplates) {
            try t.store.saveTemplate(PlanTemplate(name: "t8", blocks: [.init(hour: 9, minute: 0, minutes: 60, category: c[0])]))
        }
        #expect(try t.store.templates().map(\.name) == (1...7).map { "t\($0)" })  // 作った順
    }

    @Test func templateNameMustNotBeEmpty() throws {
        let t = try TestStore()
        try t.seeded()
        #expect(throws: RecordError.emptyName) { try t.store.saveTemplate(PlanTemplate(name: "  ", blocks: [])) }
    }

    @Test func archivedCategoryStillReadsInTemplate() throws {
        let t = try TestStore()
        let c = try t.seeded()
        try t.store.saveTemplate(PlanTemplate(name: "料理の日", blocks: [.init(hour: 18, minute: 0, minutes: 60, category: c[3])]))
        try t.store.setCategoryArchived(id: c[3].id, true)
        #expect(try t.store.templates().first?.blocks.first?.category.name == "家事")
    }
}
