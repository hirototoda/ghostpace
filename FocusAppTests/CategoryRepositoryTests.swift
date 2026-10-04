import Foundation
import SwiftData
import Testing
@testable import FocusApp

@MainActor
struct CategoryRepositoryTests {
    @Test func seedsSixDefaultsOnce() throws {
        let t = try TestStore()
        try t.store.seedDefaultsIfNeeded()
        try t.store.seedDefaultsIfNeeded()

        let categories = try t.store.categories()
        // 2026-10-03 から掃除・料理・瞑想はブロック名（CAT-01）
        #expect(categories.map(\.name) == ["勉強", "仕事", "読書", "家事", "休み", "運動"])
        #expect(categories.map(\.countsAsFocus) == [true, true, true, false, false, false])
        #expect(try t.store.projects().count == 5)
    }

    @Test func doesNotReseedWhenAllArchived() throws {
        let t = try TestStore()
        try t.seeded()
        for record in try t.context.fetch(FetchDescriptor<CategoryRecord>()) { record.isArchived = true }
        try t.context.save()

        try t.store.seedDefaultsIfNeeded()
        #expect(try t.context.fetchCount(FetchDescriptor<CategoryRecord>()) == 6)
    }

    @Test func categoriesExcludeArchived() throws {
        let t = try TestStore()
        try t.seeded()
        let record = try #require(try t.context.fetch(FetchDescriptor<CategoryRecord>()).first { $0.name == "運動" })
        record.isArchived = true
        try t.context.save()

        #expect(try !t.store.categories().contains { $0.name == "運動" })
        #expect(try t.store.allCategories().contains { $0.name == "運動" })
    }

    @Test func createProjectTrimsAndDedupes() throws {
        let t = try TestStore()
        try t.seeded()
        let study = try t.category("勉強")
        let work = try t.category("仕事")

        let first = try #require(try t.store.createProject(name: " ゼミ準備 ", category: study))
        #expect(first.name == "ゼミ準備")
        #expect(first.category == study)
        #expect(try t.store.createProject(name: "ゼミ準備", category: study)?.id == first.id)
        #expect(try t.store.createProject(name: "ゼミ準備", category: work)?.id != first.id)

        // アーカイブ済みの同名があれば新しく作る
        let record = try #require(try t.context.fetch(FetchDescriptor<ProjectRecord>()).first { $0.id == first.id })
        record.isArchived = true
        try t.context.save()
        #expect(try t.store.createProject(name: "ゼミ準備", category: study)?.id != first.id)
        #expect(try t.store.projects().filter { $0.name == "ゼミ準備" }.count == 2)
        // デフォルトのブロック名5つ（家事・休み）＋ゼミ準備3つ
        #expect(try t.store.allProjects().count == 5 + 3)
    }

    @Test func createProjectRejectsBlank() throws {
        let t = try TestStore()
        try t.seeded()
        let before = try t.store.projects()
        #expect(try t.store.createProject(name: "  ", category: t.category("勉強")) == nil)
        #expect(try t.store.projects() == before)
    }
}

struct PlanSnapshotTests {
    @Test func snapshotRoundTrip() {
        let blocks = [
            PlanSnapshotBlock(blockId: UUID(), startAt: jst("2026-10-19T09:00"), endAt: jst("2026-10-19T10:00"),
                              categoryId: UUID(), categoryName: "勉強", projectId: UUID(), projectName: "ゼミ準備"),
            PlanSnapshotBlock(blockId: UUID(), startAt: jst("2026-10-19T10:00"), endAt: jst("2026-10-19T11:00"),
                              categoryId: UUID(), categoryName: "運動", projectId: nil, projectName: nil),
        ]
        #expect(PlanSnapshotBlock.decode(PlanSnapshotBlock.encode(blocks)) == blocks)
    }

    @Test func unreadableSnapshotIsNil() {
        #expect(PlanSnapshotBlock.decode(Data("{".utf8)) == nil)
    }
}

/// 設定のカテゴリ・ブロック名（CAT-02〜04、settings.md）。
@MainActor
struct CategorySettingsTests {
    @Test func createCategoryTrimsDedupesAndAppends() throws {
        let t = try TestStore()
        try t.seeded()
        let piano = try #require(try t.store.createCategory(name: " ピアノ ", countsAsFocus: true, detoxGroup: nil))
        #expect(piano.name == "ピアノ")
        #expect(try t.store.categories().last == piano)
        #expect(try t.store.createCategory(name: "ピアノ", countsAsFocus: false, detoxGroup: nil)?.id == piano.id)
        #expect(try t.store.createCategory(name: "勉強", countsAsFocus: false, detoxGroup: nil)?.id == t.category("勉強").id)
        #expect(try t.store.createCategory(name: "  ", countsAsFocus: true, detoxGroup: nil) == nil)
    }

    @Test func updateCategoryChangesFutureSessionsOnly() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        try t.seeded()
        let reading = try t.category("読書")
        let started = try t.store.start(StartRequest(category: reading, timeZone: tokyo))
        try t.store.updateCategory(id: reading.id, name: "本", countsAsFocus: false, detoxGroup: nil)

        let updated = try t.category("本")
        #expect(updated.countsAsFocus == false)
        // 開始したときの値のまま（2026-09-30 決定）
        let session = try #require(try t.store.sessions(dayKey: "2026-10-19").first { $0.id == started.id })
        #expect(session.category.countsAsFocus == true)
        #expect(session.category.name == "本")
    }

    @Test func updateCategoryRejectsEmptyAndDuplicateNames() throws {
        let t = try TestStore()
        try t.seeded()
        let study = try t.category("勉強")
        #expect(throws: RecordError.emptyName) { try t.store.updateCategory(id: study.id, name: " ", countsAsFocus: true, detoxGroup: nil) }
        #expect(throws: RecordError.duplicateName) { try t.store.updateCategory(id: study.id, name: "仕事", countsAsFocus: true, detoxGroup: nil) }
        // 自分と同じ名前のままは可
        try t.store.updateCategory(id: study.id, name: "勉強", countsAsFocus: true, detoxGroup: nil)
    }

    @Test func archiveAndRestoreCategory() throws {
        let t = try TestStore()
        try t.seeded()
        let exercise = try t.category("運動")
        try t.store.setCategoryArchived(id: exercise.id, true)
        #expect(try !t.store.categories().contains(exercise))
        #expect(try t.store.archivedCategories() == [exercise])
        try t.store.setCategoryArchived(id: exercise.id, false)
        #expect(try t.store.categories().contains(exercise))
        #expect(try t.store.archivedCategories().isEmpty)
    }

    @Test func lastCategoryCannotBeArchived() throws {
        let t = try TestStore()
        let all = try t.seeded()
        for category in all.dropLast() { try t.store.setCategoryArchived(id: category.id, true) }
        #expect(throws: RecordError.lastCategory) { try t.store.setCategoryArchived(id: all.last!.id, true) }
    }

    @Test func restoringIntoADuplicateNameIsRejected() throws {
        let t = try TestStore()
        try t.seeded()
        let exercise = try t.category("運動")
        try t.store.setCategoryArchived(id: exercise.id, true)
        _ = try t.store.createCategory(name: "運動", countsAsFocus: false, detoxGroup: nil)
        #expect(throws: RecordError.duplicateName) { try t.store.setCategoryArchived(id: exercise.id, false) }
    }

    @Test func renameAndArchiveProject() throws {
        let t = try TestStore()
        try t.seeded()
        let study = try t.category("勉強")
        let seminar = try #require(try t.store.createProject(name: "ゼミ準備", category: study))
        let english = try #require(try t.store.createProject(name: "英語", category: study))
        try t.store.renameProject(id: seminar.id, name: "ゼミ")
        #expect(try t.store.projects().first { $0.id == seminar.id }?.name == "ゼミ")
        #expect(throws: RecordError.duplicateName) { try t.store.renameProject(id: seminar.id, name: "英語") }
        #expect(throws: RecordError.emptyName) { try t.store.renameProject(id: seminar.id, name: "") }

        try t.store.setProjectArchived(id: english.id, true)
        #expect(try !t.store.projects().contains(english))
        #expect(try t.store.archivedProjects().map(\.id) == [english.id])
        try t.store.setProjectArchived(id: english.id, false)
        #expect(try t.store.projects().contains(english))
    }
}
