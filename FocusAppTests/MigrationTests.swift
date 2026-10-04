import Foundation
import SwiftData
import Testing
@testable import FocusApp

/// 保存データの第1版を第2版で読める（NFR-02）。
@MainActor
struct MigrationTests {
    @Test func version1StoreOpensWithVersion2() throws {
        let url = temporaryStoreURL()
        defer { removeStoreFiles(url) }
        let now = jst("2026-10-19T09:00")
        let categoryId = UUID(), planId = UUID(), blockId = UUID(), sessionId = UUID()

        // 第1版で保存する
        do {
            let schema = Schema(versionedSchema: SchemaV1.self)
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url,
                                                                                               cloudKitDatabase: .none))
            let context = ModelContext(container)
            context.insert(SchemaV1.CategoryRecord(id: categoryId, name: "勉強", countsAsFocus: true, sortOrder: 0, at: now))
            let plan = SchemaV1.DailyPlanRecord(id: planId, dayKey: "2026-10-19", timeZoneId: "Asia/Tokyo",
                                                statusRaw: "confirmed", at: now)
            plan.snapshotJSON = PlanSnapshotBlock.encode([
                PlanSnapshotBlock(blockId: blockId, startAt: jst("2026-10-19T10:00"), endAt: jst("2026-10-19T11:00"),
                                  categoryId: categoryId, categoryName: "勉強", projectId: nil, projectName: nil),
            ])
            context.insert(plan)
            context.insert(SchemaV1.PlanBlockRecord(id: blockId, planId: planId, startAt: jst("2026-10-19T10:00"),
                                                    endAt: jst("2026-10-19T11:00"), categoryId: categoryId, projectId: nil, at: now))
            let session = SchemaV1.FocusSessionRecord(id: sessionId, dayKey: "2026-10-19", timeZoneId: "Asia/Tokyo",
                                                      planBlockId: blockId, categoryId: categoryId, countsAsFocus: true,
                                                      projectId: nil, startAt: jst("2026-10-19T10:00"),
                                                      plannedEndAt: jst("2026-10-19T11:00"), plannedDurationSec: nil, at: now)
            session.endAt = jst("2026-10-19T10:40")
            context.insert(session)
            try context.save()
        }

        // 第2版で開く
        let container = try AppStore.makeContainer(url: url)
        let store = SwiftDataStore(container: container, clock: FixedClock(date: now))
        #expect(try store.categories().map(\.name) == ["勉強"])
        let plan = try #require(try store.plan(dayKey: "2026-10-19"))
        #expect(plan.status == .confirmed)
        #expect(plan.draft.blocks.map(\.id) == [blockId])
        #expect(plan.draft.goalSeconds == nil)
        #expect(try store.snapshot(dayKey: "2026-10-19")?.count == 1)
        #expect(try store.sessions(dayKey: "2026-10-19").map(\.id) == [sessionId])
        #expect(try store.templates().isEmpty)
    }

    @Test func version1DraftAndSkippedPlansOpenWithVersion2() throws {
        let url = temporaryStoreURL()
        defer { removeStoreFiles(url) }
        let now = jst("2026-10-20T07:00")
        do {
            let schema = Schema(versionedSchema: SchemaV1.self)
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url,
                                                                                               cloudKitDatabase: .none))
            let context = ModelContext(container)
            context.insert(SchemaV1.CategoryRecord(name: "勉強", countsAsFocus: true, sortOrder: 0, at: now))
            context.insert(SchemaV1.DailyPlanRecord(dayKey: "2026-10-19", timeZoneId: "Asia/Tokyo", statusRaw: "skipped", at: now))
            context.insert(SchemaV1.DailyPlanRecord(dayKey: "2026-10-20", timeZoneId: "Asia/Tokyo", statusRaw: "draft", at: now))
            try context.save()
        }
        let store = SwiftDataStore(container: try AppStore.makeContainer(url: url), clock: FixedClock(date: now))
        #expect(try store.plan(dayKey: "2026-10-19")?.status == .skipped)
        #expect(try store.plan(dayKey: "2026-10-19")?.draft.goalSeconds == nil)
        #expect(try store.plan(dayKey: "2026-10-20")?.status == .draft)
        // 第2版になってから目標を足せる
        try store.setGoal(3600, dayKey: "2026-10-19")
        #expect(try store.plan(dayKey: "2026-10-19")?.draft.goalSeconds == 3600)
    }
}
