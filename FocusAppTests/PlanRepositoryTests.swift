import Foundation
import SwiftData
import Testing
@testable import FocusApp

@MainActor
struct PlanRepositoryTests {
    private let day = "2026-10-19"

    private func block(_ start: String, _ minutes: Int, _ category: CategoryOption, project: ProjectOption? = nil, id: UUID = UUID()) -> PlanBlockDraft {
        PlanBlockDraft(id: id, start: jst(start), minutes: minutes, category: category, project: project)
    }

    @Test func noPlanReturnsNil() throws {
        let t = try TestStore()
        #expect(try t.store.plan(dayKey: day) == nil)
        #expect(try t.store.snapshot(dayKey: day) == nil)
    }

    enum Start: CaseIterable { case none, draft, confirmed, skipped }
    enum Operation: CaseIterable { case saveDraft, confirm, skip, saveChanges }

    /// 状態 × 操作の16通り（docs/plan/recording-spec.md の表）。nil はエラー
    private func expected(_ start: Start, _ operation: Operation) -> (status: PlanStatus?, blocks: Int)? {
        switch (start, operation) {
        case (.none, .saveDraft): (.draft, 2)
        case (.none, .confirm): (.confirmed, 2)
        case (.none, .skip): (.skipped, 0)
        case (.none, .saveChanges): nil
        case (.draft, .saveDraft): (.draft, 2)
        case (.draft, .confirm): (.confirmed, 2)
        case (.draft, .skip): (.skipped, 0)
        case (.draft, .saveChanges): nil
        case (.confirmed, .saveDraft), (.confirmed, .confirm): (.confirmed, 1)
        case (.confirmed, .skip): nil
        case (.confirmed, .saveChanges): (.confirmed, 2)
        case (.skipped, .saveDraft), (.skipped, .skip): (.skipped, 0)
        case (.skipped, .confirm): (.confirmed, 2)
        case (.skipped, .saveChanges): nil
        }
    }

    @Test(arguments: Start.allCases, Operation.allCases)
    func planTransitionTable(start: Start, operation: Operation) throws {
        let t = try TestStore()
        let study = try t.seeded()[0]
        let first = block("2026-10-19T09:00", 60, study)
        let one = PlanDraft(blocks: [first])
        let two = PlanDraft(blocks: [first, block("2026-10-19T10:00", 60, study)])

        switch start {
        case .none: break
        case .draft: try t.store.saveDraft(one, dayKey: day, timeZone: tokyo)
        case .confirmed: try t.store.confirm(one, dayKey: day, timeZone: tokyo)
        case .skipped: try t.store.skip(dayKey: day, timeZone: tokyo)
        }
        let before = try t.store.plan(dayKey: day)
        let snapshotBefore = try t.store.snapshot(dayKey: day)

        func run() throws {
            switch operation {
            case .saveDraft: try t.store.saveDraft(two, dayKey: day, timeZone: tokyo)
            case .confirm: try t.store.confirm(two, dayKey: day, timeZone: tokyo)
            case .skip: try t.store.skip(dayKey: day, timeZone: tokyo)
            case .saveChanges: try t.store.saveChanges(two, dayKey: day)
            }
        }

        if let (status, blocks) = expected(start, operation) {
            try run()
            let after = try #require(try t.store.plan(dayKey: day))
            #expect(after.status == status)
            #expect(after.draft.blocks.count == blocks)
        } else {
            #expect(throws: RecordError.self) { try run() }
            #expect(try t.store.plan(dayKey: day) == before)
            #expect(try t.store.snapshot(dayKey: day) == snapshotBefore)
        }
    }

    @Test func saveDraftCreatesAndUpdates() throws {
        let t = try TestStore()
        let study = try t.seeded()[0]
        let a = block("2026-10-19T09:00", 60, study)
        let b = block("2026-10-19T10:00", 30, study)
        try t.store.saveDraft(PlanDraft(blocks: [a]), dayKey: day, timeZone: tokyo)
        try t.store.saveDraft(PlanDraft(blocks: [a, b]), dayKey: day, timeZone: tokyo)
        #expect(try t.store.plan(dayKey: day)?.draft.sortedBlocks == [a, b])

        try t.store.saveDraft(PlanDraft(blocks: [b]), dayKey: day, timeZone: tokyo)
        #expect(try t.store.plan(dayKey: day)?.draft.blocks == [b])
        // 下書きで消したブロックは行ごと消える
        #expect(try t.context.fetchCount(FetchDescriptor<PlanBlockRecord>()) == 1)
    }

    @Test func confirmSavesSnapshot() throws {
        let t = try TestStore(now: jst("2026-10-19T07:00"))
        let study = try t.seeded()[0]
        let seminar = try #require(try t.store.createProject(name: "ゼミ準備", category: study))
        let a = block("2026-10-19T09:00", 60, study, project: seminar)
        try t.store.confirm(PlanDraft(blocks: [a]), dayKey: day, timeZone: tokyo)

        let snapshot = try #require(try t.store.snapshot(dayKey: day))
        #expect(snapshot == [PlanSnapshotBlock(blockId: a.id, startAt: a.start, endAt: a.end, categoryId: study.id,
                                                categoryName: "勉強", projectId: seminar.id, projectName: "ゼミ準備")])
        let record = try #require(try t.context.fetch(FetchDescriptor<DailyPlanRecord>()).first)
        #expect(record.confirmedAt == jst("2026-10-19T07:00"))
        #expect(record.timeZoneId == "Asia/Tokyo")
        #expect(try t.store.plan(dayKey: day)?.draft.blocks == [a])
    }

    @Test func confirmTwiceKeepsFirstSnapshot() throws {
        let t = try TestStore()
        let study = try t.seeded()[0]
        try t.store.confirm(PlanDraft(blocks: [block("2026-10-19T09:00", 60, study)]), dayKey: day, timeZone: tokyo)
        let first = try t.store.snapshot(dayKey: day)
        try t.store.confirm(PlanDraft(blocks: [block("2026-10-19T12:00", 60, study)]), dayKey: day, timeZone: tokyo)
        #expect(try t.store.snapshot(dayKey: day) == first)
    }

    @Test func saveChangesKeepsSnapshotAndMarksRemoved() throws {
        let t = try TestStore()
        let categories = try t.seeded()
        let a = block("2026-10-19T09:00", 60, categories[0])
        let b = block("2026-10-19T10:00", 60, categories[0])
        try t.store.confirm(PlanDraft(blocks: [a, b]), dayKey: day, timeZone: tokyo)
        let morning = try t.store.snapshot(dayKey: day)

        var moved = a
        moved.start = jst("2026-10-19T09:30")
        moved.category = categories[2]
        try t.store.saveChanges(PlanDraft(blocks: [moved]), dayKey: day)

        #expect(try t.store.snapshot(dayKey: day) == morning)
        #expect(try t.store.plan(dayKey: day)?.draft.blocks == [moved])
        let removed = try #require(try t.context.fetch(FetchDescriptor<PlanBlockRecord>()).first { $0.id == b.id })
        #expect(removed.isRemoved)
    }

    @Test func skipFromDraftDeletesBlocks() throws {
        let t = try TestStore()
        let study = try t.seeded()[0]
        try t.store.saveDraft(PlanDraft(blocks: [block("2026-10-19T09:00", 60, study)]), dayKey: day, timeZone: tokyo)
        try t.store.skip(dayKey: day, timeZone: tokyo)
        #expect(try t.store.plan(dayKey: day)?.status == .skipped)
        #expect(try t.context.fetchCount(FetchDescriptor<PlanBlockRecord>()) == 0)
    }

    @Test func unknownStatusIsReadOnly() throws {
        let t = try TestStore()
        let study = try t.seeded()[0]
        try t.store.confirm(PlanDraft(blocks: [block("2026-10-19T09:00", 60, study)]), dayKey: day, timeZone: tokyo)
        let record = try #require(try t.context.fetch(FetchDescriptor<DailyPlanRecord>()).first)
        record.statusRaw = "future"
        try t.context.save()

        let two = PlanDraft(blocks: [block("2026-10-19T12:00", 60, study)])
        try t.store.saveDraft(two, dayKey: day, timeZone: tokyo)
        try t.store.confirm(two, dayKey: day, timeZone: tokyo)
        try t.store.skip(dayKey: day, timeZone: tokyo)
        #expect(throws: RecordError.self) { try t.store.saveChanges(two, dayKey: day) }

        let plan = try #require(try t.store.plan(dayKey: day))
        #expect(plan.status == .unknown)
        #expect(plan.draft.blocks.count == 1)
        #expect(record.statusRaw == "future")
    }

    @Test func duplicatePlansPickNewest() throws {
        let t = try TestStore()
        t.context.insert(DailyPlanRecord(dayKey: day, timeZoneId: "Asia/Tokyo", statusRaw: "skipped", at: jst("2026-10-19T05:00")))
        t.context.insert(DailyPlanRecord(dayKey: day, timeZoneId: "Asia/Tokyo", statusRaw: "draft", at: jst("2026-10-19T06:00")))
        try t.context.save()
        #expect(try t.store.plan(dayKey: day)?.status == .draft)
    }

    @Test func snapshotSurvivesCategoryRename() throws {
        let t = try TestStore()
        let study = try t.seeded()[0]
        try t.store.confirm(PlanDraft(blocks: [block("2026-10-19T09:00", 60, study)]), dayKey: day, timeZone: tokyo)
        let record = try #require(try t.context.fetch(FetchDescriptor<CategoryRecord>()).first { $0.id == study.id })
        record.name = "学習"
        try t.context.save()

        #expect(try t.store.snapshot(dayKey: day)?.first?.categoryName == "勉強")
        #expect(try t.store.plan(dayKey: day)?.draft.blocks.first?.category.name == "学習")
    }

    @Test func saveFailureRollsBack() throws {
        let t = try TestStore()
        let study = try t.seeded()[0]
        try t.store.saveDraft(PlanDraft(blocks: [block("2026-10-19T09:00", 60, study)]), dayKey: day, timeZone: tokyo)

        t.store.saveHook = { throw TestFailure() }
        #expect(throws: TestFailure.self) {
            try t.store.confirm(PlanDraft(blocks: [block("2026-10-19T09:00", 60, study)]), dayKey: day, timeZone: tokyo)
        }
        t.store.saveHook = nil
        #expect(try t.store.plan(dayKey: day)?.status == .draft)
        #expect(try t.store.snapshot(dayKey: day) == nil)
    }
}

struct TestFailure: Error {}
