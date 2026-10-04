import Foundation
import SwiftData
import Testing
@testable import FocusApp

/// デトックスのグループの保存とカテゴリの組み替え（2026-10-03、settings.md「カテゴリの組み替え」、DTX-03・CAT-01・CAT-04）。
@MainActor
struct DetoxGroupsTests {
    // MARK: 第4版

    @Test func version3StoreOpensWithVersion4() throws {
        let url = temporaryStoreURL()
        defer { removeStoreFiles(url) }
        let now = jst("2026-10-19T09:00")
        do {
            let schema = Schema(versionedSchema: SchemaV3.self)
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url,
                                                                                               cloudKitDatabase: .none))
            let context = ModelContext(container)
            context.insert(SchemaV3.CategoryRecord(name: "掃除", countsAsFocus: false, sortOrder: 0, at: now))
            context.insert(SchemaV3.SleepRecord(dayKey: "2026-10-19", timeZoneId: "Asia/Tokyo", startAt: jst("2026-10-19T00:00"),
                                                endAt: jst("2026-10-19T07:00"), sourceRaw: "manual", at: now))
            try context.save()
        }
        let store = SwiftDataStore(container: try AppStore.makeContainer(url: url), clock: FixedClock(date: now))
        let category = try #require(try store.categories().first)
        #expect(category.name == "掃除")
        #expect(category.detoxGroup == nil)
        let sleep = try #require(try store.sleep(dayKey: "2026-10-19"))
        #expect(sleep.source == .manual)
        #expect(sleep.original == nil)
    }

    // MARK: グループの保存（CAT-04）

    @Test func createCategoryKeepsGroupOnlyForDetox() throws {
        let t = try TestStore()
        _ = try t.seeded()
        let garden = try #require(try t.store.createCategory(name: "ガーデニング", countsAsFocus: false, detoxGroup: .housework))
        #expect(garden.detoxGroup == .housework)
        let piano = try #require(try t.store.createCategory(name: "ピアノ", countsAsFocus: true, detoxGroup: .rest))
        #expect(piano.detoxGroup == nil)
        #expect(try t.category("ガーデニング").detoxGroup == .housework)
        #expect(DetoxGroup.of(try t.category("ガーデニング")) == .housework)
    }

    @Test func updateCategoryChangesGroupAndFocusClearsIt() throws {
        let t = try TestStore()
        _ = try t.seeded()
        let walk = try #require(try t.store.createCategory(name: "散歩", countsAsFocus: false, detoxGroup: nil))
        try t.store.updateCategory(id: walk.id, name: "散歩", countsAsFocus: false, detoxGroup: .exercise)
        #expect(try t.category("散歩").detoxGroup == .exercise)
        try t.store.updateCategory(id: walk.id, name: "散歩", countsAsFocus: true, detoxGroup: .exercise)
        #expect(try t.category("散歩").detoxGroup == nil)
    }

    // MARK: 新しいデフォルト（CAT-01）

    @Test func newDefaultsHaveGroupsAndBlocks() throws {
        let t = try TestStore()
        let categories = try t.seeded()
        #expect(categories.map(\.name) == ["勉強", "仕事", "読書", "家事", "休み", "運動"])
        #expect(categories.map(\.detoxGroup) == [nil, nil, nil, .housework, .rest, .exercise])
        let projects = try t.store.projects()
        #expect(Set(projects.filter { $0.category.name == "家事" }.map(\.name)) == ["掃除", "料理", "洗濯"])
        #expect(Set(projects.filter { $0.category.name == "休み" }.map(\.name)) == ["瞑想", "休憩"])
    }

    // MARK: 組み替え

    /// 2026-10-03 より前のデフォルト（掃除・休み・料理・運動・瞑想）の端末
    private func oldDevice() throws -> TestStore {
        let t = try TestStore()
        for (name, focus) in [("勉強", true), ("仕事", true), ("読書", true), ("掃除", false), ("休み", false), ("料理", false),
                              ("運動", false), ("瞑想", false)] {
            _ = try t.store.createCategory(name: name, countsAsFocus: focus, detoxGroup: nil)
        }
        return t
    }

    private func sessionRecord(_ t: TestStore, category: CategoryOption, project: ProjectOption? = nil, start: String,
                               end: String?) throws -> UUID {
        let record = FocusSessionRecord(dayKey: "2026-10-19", timeZoneId: "Asia/Tokyo", planBlockId: nil, categoryId: category.id,
                                        countsAsFocus: category.countsAsFocus, projectId: project?.id, startAt: jst(start),
                                        plannedEndAt: nil, plannedDurationSec: nil, at: jst(start))
        record.endAt = end.map(jst)
        t.context.insert(record)
        try t.context.save()
        return record.id
    }

    private func session(_ t: TestStore, _ id: UUID) throws -> FocusSessionRecord {
        try #require(try t.context.fetch(FetchDescriptor<FocusSessionRecord>()).first { $0.id == id })
    }

    @Test func regroupsOldDefaults() throws {
        let t = try oldDevice()
        #expect(try t.store.regroupDetoxCategories())
        #expect(try t.store.categories().map(\.name) == ["勉強", "仕事", "読書", "家事", "休み", "運動"])
        #expect(try t.store.categories().map(\.detoxGroup) == [nil, nil, nil, .housework, .rest, .exercise])
        #expect(try t.store.archivedCategories().map(\.name).sorted() == ["料理", "瞑想"].sorted())
        let projects = try t.store.projects()
        #expect(Set(projects.filter { $0.category.name == "家事" }.map(\.name)) == ["掃除", "料理", "洗濯"])
        #expect(Set(projects.filter { $0.category.name == "休み" }.map(\.name)) == ["瞑想", "休憩"])
    }

    @Test func regroupMovesRecordsWithBlockNames() throws {
        let t = try oldDevice()
        let cooking = try t.category("料理"), cleaning = try t.category("掃除"), meditation = try t.category("瞑想")
        let menu = try #require(try t.store.createProject(name: "献立", category: cooking))
        let a = try sessionRecord(t, category: cleaning, start: "2026-10-19T08:00", end: "2026-10-19T08:30")
        let b = try sessionRecord(t, category: cooking, start: "2026-10-19T09:00", end: "2026-10-19T09:30")
        let c = try sessionRecord(t, category: cooking, project: menu, start: "2026-10-19T10:00", end: "2026-10-19T10:30")
        let d = try sessionRecord(t, category: meditation, start: "2026-10-19T11:00", end: nil)  // 実行中
        #expect(try t.store.regroupDetoxCategories())
        let housework = try t.category("家事"), rest = try t.category("休み")
        let projects = try t.store.allProjects()
        func project(_ name: String, in category: CategoryOption) -> UUID? {
            projects.first { $0.name == name && $0.category == category }?.id
        }
        #expect(try session(t, a).categoryId == housework.id)
        #expect(try session(t, a).projectId == project("掃除", in: housework))
        #expect(try session(t, b).categoryId == housework.id)
        #expect(try session(t, b).projectId == project("料理", in: housework))
        // もとからブロック名があった記録は、そのブロック名を家事に移す
        #expect(try session(t, c).categoryId == housework.id)
        #expect(try session(t, c).projectId == menu.id)
        #expect(project("献立", in: housework) == menu.id)
        // 実行中のタイマーも付け替える。開始時刻は変えない
        #expect(try session(t, d).categoryId == rest.id)
        #expect(try session(t, d).projectId == project("瞑想", in: rest))
        #expect(try session(t, d).startAt == jst("2026-10-19T11:00"))
        #expect(try session(t, d).countsAsFocus == false)
    }

    @Test func regroupMovesPlanBlocksAndTemplatesButNotSnapshots() throws {
        let t = try oldDevice()
        let cleaning = try t.category("掃除"), study = try t.category("勉強")
        let draft = PlanDraft(blocks: [PlanBlockDraft(start: jst("2026-10-19T13:00"), minutes: 30, category: cleaning),
                                       PlanBlockDraft(start: jst("2026-10-19T14:00"), minutes: 60, category: study)])
        try t.store.confirm(draft, dayKey: "2026-10-19", timeZone: tokyo)
        try t.store.saveDraft(draft, dayKey: "2026-10-20", timeZone: tokyo)
        try t.store.saveTemplate(PlanTemplate(id: UUID(), name: "平日",
                                              blocks: [.init(hour: 13, minute: 0, minutes: 30, category: cleaning, project: nil)]))
        let snapshotBefore = try t.context.fetch(FetchDescriptor<DailyPlanRecord>()).first { $0.dayKey == "2026-10-19" }?.snapshotJSON
        #expect(try t.store.regroupDetoxCategories())
        let housework = try t.category("家事")
        let cleaningBlock = try #require(try t.store.projects().first { $0.name == "掃除" && $0.category == housework })
        for key in ["2026-10-19", "2026-10-20"] {
            let blocks = try #require(try t.store.plan(dayKey: key)).draft.sortedBlocks
            #expect(blocks.first?.category == housework)
            #expect(blocks.first?.project == cleaningBlock)
            #expect(blocks.last?.category == study)
        }
        let template = try #require(try t.store.templates().first)
        #expect(template.blocks.first?.category == housework)
        #expect(template.blocks.first?.project == cleaningBlock)
        // 朝の計画の写しは変えない（PLN-03）
        let snapshotAfter = try t.context.fetch(FetchDescriptor<DailyPlanRecord>()).first { $0.dayKey == "2026-10-19" }?.snapshotJSON
        #expect(snapshotAfter == snapshotBefore)
        #expect(try t.store.snapshot(dayKey: "2026-10-19")?.first?.categoryName == "掃除")
    }

    @Test func regroupTwiceChangesNothing() throws {
        let t = try oldDevice()
        _ = try t.store.regroupDetoxCategories()
        let categories = try t.store.allCategories(), projects = try t.store.allProjects()
        _ = try t.store.regroupDetoxCategories()
        #expect(try t.store.allCategories().map(\.id) == categories.map(\.id))
        #expect(try t.store.allProjects().map(\.id) == projects.map(\.id))
    }

    @Test func regroupUsesExistingHouseworkAndArchivesCleaning() throws {
        let t = try oldDevice()
        _ = try t.store.createCategory(name: "家事", countsAsFocus: false, detoxGroup: nil)
        let cleaning = try t.category("掃除")
        let a = try sessionRecord(t, category: cleaning, start: "2026-10-19T08:00", end: "2026-10-19T08:30")
        _ = try t.store.regroupDetoxCategories()
        #expect(try t.store.categories().filter { $0.name == "家事" }.count == 1)
        #expect(try t.store.archivedCategories().contains { $0.name == "掃除" })
        #expect(try session(t, a).categoryId == (try t.category("家事")).id)
        #expect(try t.category("家事").detoxGroup == .housework)
    }

    @Test func regroupCreatesHouseworkWhenCleaningIsArchived() throws {
        let t = try oldDevice()
        let cleaning = try t.category("掃除")
        let a = try sessionRecord(t, category: cleaning, start: "2026-10-19T08:00", end: "2026-10-19T08:30")
        try t.store.setCategoryArchived(id: cleaning.id, true)
        _ = try t.store.regroupDetoxCategories()
        let housework = try t.category("家事")
        #expect(try t.store.categories().contains(housework))
        #expect(try session(t, a).categoryId == housework.id)
    }

    @Test func regroupSkipsCategoriesSwitchedToFocusAndRenamedOnes() throws {
        let t = try oldDevice()
        let cooking = try t.category("料理"), cleaning = try t.category("掃除")
        try t.store.updateCategory(id: cooking.id, name: "料理", countsAsFocus: true, detoxGroup: nil)
        try t.store.updateCategory(id: cleaning.id, name: "片付け", countsAsFocus: false, detoxGroup: nil)
        let a = try sessionRecord(t, category: try t.category("料理"), start: "2026-10-19T08:00", end: "2026-10-19T08:30")
        _ = try t.store.regroupDetoxCategories()
        // 集中に切り替えていた料理は組み替えない
        #expect(try session(t, a).categoryId == cooking.id)
        #expect(try t.store.categories().contains { $0.name == "料理" })
        // 名前を変えていた掃除はそのまま（グループなし）。移すものがないので家事は作らない
        #expect(try t.category("片付け").detoxGroup == nil)
        #expect(try !t.store.allCategories().contains { $0.name == "家事" })
    }

    @Test func regroupGivesFocusNamedHouseworkOnlyGroups() throws {
        let t = try oldDevice()
        _ = try t.store.createCategory(name: "家事", countsAsFocus: true, detoxGroup: nil)
        _ = try t.store.regroupDetoxCategories()
        #expect(try t.category("家事").countsAsFocus)
        #expect(try t.category("掃除").detoxGroup == .housework)
        #expect(try t.category("料理").detoxGroup == .housework)
        #expect(try t.store.categories().contains { $0.name == "掃除" })
    }

    @Test func regroupKeepsNameBasedGroupsForLaundryAndBreak() throws {
        let t = try oldDevice()
        _ = try t.store.createCategory(name: "洗濯", countsAsFocus: false, detoxGroup: nil)
        _ = try t.store.createCategory(name: "休憩", countsAsFocus: false, detoxGroup: nil)
        _ = try t.store.createCategory(name: "散歩", countsAsFocus: false, detoxGroup: nil)
        _ = try t.store.regroupDetoxCategories()
        #expect(try t.category("洗濯").detoxGroup == .housework)
        #expect(try t.category("休憩").detoxGroup == .rest)
        #expect(try t.category("散歩").detoxGroup == nil)
    }

    @Test func regroupOnNewDefaultsChangesNothing() throws {
        let t = try TestStore()
        let before = try t.seeded()
        let projects = try t.store.allProjects()
        _ = try t.store.regroupDetoxCategories()
        #expect(try t.store.allCategories().map(\.id) == before.map(\.id))
        #expect(try t.store.allProjects().map(\.id) == projects.map(\.id))
    }

    // MARK: 手で直した睡眠（DTX-02・03）

    @Test func manualEditKeepsTheFirstOriginal() throws {
        let t = try TestStore()
        try t.store.saveSleep(SleepLine(start: jst("2026-10-19T00:00"), end: jst("2026-10-19T07:00"), source: .setting),
                              dayKey: "2026-10-19", timeZone: tokyo)
        try t.store.saveSleep(SleepLine(start: jst("2026-10-18T23:00"), end: jst("2026-10-19T08:00"), source: .manual),
                              dayKey: "2026-10-19", timeZone: tokyo)
        let original = DateInterval(start: jst("2026-10-19T00:00"), end: jst("2026-10-19T07:00"))
        #expect(try t.store.sleep(dayKey: "2026-10-19")?.original == original)
        // もう一度直しても、直す前の値は最初のまま
        try t.store.saveSleep(SleepLine(start: jst("2026-10-18T22:00"), end: jst("2026-10-19T08:00"), source: .manual),
                              dayKey: "2026-10-19", timeZone: tokyo)
        #expect(try t.store.sleep(dayKey: "2026-10-19")?.original == original)
    }

    @Test func extendedPartIsBeyondTheOriginalLength() {
        let original = DateInterval(start: jst("2026-10-19T00:00"), end: jst("2026-10-19T07:00"))
        // 23:00〜8:00 に長く直した → 23:00 から7時間の 6:00 より後
        let longer = SleepLine(start: jst("2026-10-18T23:00"), end: jst("2026-10-19T08:00"), source: .manual, original: original)
        #expect(longer.extendedPart == DateInterval(start: jst("2026-10-19T06:00"), end: jst("2026-10-19T08:00")))
        // 同じ長さでずらした・短くした → なし
        #expect(SleepLine(start: jst("2026-10-19T01:00"), end: jst("2026-10-19T08:00"), source: .manual, original: original)
            .extendedPart == nil)
        #expect(SleepLine(start: jst("2026-10-19T01:00"), end: jst("2026-10-19T06:00"), source: .manual, original: original)
            .extendedPart == nil)
        // 第4版より前に直した日（直す前がない）は比べない
        #expect(SleepLine(start: jst("2026-10-18T23:00"), end: jst("2026-10-19T08:00"), source: .manual).extendedPart == nil)
    }

    @Test func extendedSleepCountsAtTheLowerRate() {
        // 直す前は5時間（0:00〜5:00）、23:00〜8:00 に直した → 4:00〜8:00（寝てから5〜9時間目）は長くした所
        let sleep = DateInterval(start: jst("2026-10-18T23:00"), end: jst("2026-10-19T08:00"))
        let caps = [DateInterval(start: jst("2026-10-19T04:00"), end: jst("2026-10-19T08:00"))]
        let day = DetoxDay.make(.init(dayStart: jst("2026-10-19T04:00"), dayEnd: jst("2026-10-20T04:00"), until: jst("2026-10-19T08:00"),
                                      events: [BlockEvent(occurredAt: jst("2026-10-01T09:00"), timeZoneId: "Asia/Tokyo", kind: .started)],
                                      focus: [], detoxTimers: [], sleep: [sleep], gameWindows: [], sleepCaps: caps))
        // 5〜7時間目 0.5pt×2時間 6.0 ＋ 7〜8時間目 3.0 ＋ 8〜9時間目 0 ＝ 9.0（直さなければ 9.0＋3.0＝12.0）
        #expect(abs(day.points(until: jst("2026-10-19T08:00")) - 9.0) < 0.0001)
        // docs の例：直す前 0:00〜7:00 を 23:00〜8:00 に直した夜の合計は 34.5（ヘルスケアに9時間と入った人と同じ）
        let night = DetoxDay.sleepPoints(from: 0, to: 7 * 3600) + DetoxDay.sleepPoints(from: 7 * 3600, to: 9 * 3600, capped: true)
        #expect(abs(night - 34.5) < 0.0001)
        #expect(abs(night - DetoxDay.sleepPoints(from: 0, to: 9 * 3600)) < 0.0001)
    }

    // MARK: 組み替えの分かれ道（レビューで足した）

    @Test func regroupMergesSameNamedBlocks() throws {
        let t = try oldDevice()
        let cooking = try t.category("料理"), cleaning = try t.category("掃除")
        let cookingBlock = try #require(try t.store.createProject(name: "料理", category: cooking))
        let cleaningBlock = try #require(try t.store.createProject(name: "掃除", category: cleaning))
        let s1 = try sessionRecord(t, category: cooking, project: cookingBlock, start: "2026-10-19T08:00", end: "2026-10-19T08:30")
        let s2 = try sessionRecord(t, category: cleaning, project: cleaningBlock, start: "2026-10-19T09:00", end: "2026-10-19T09:30")
        let s3 = try sessionRecord(t, category: cooking, start: "2026-10-19T10:00", end: "2026-10-19T10:30")
        _ = try t.store.regroupDetoxCategories()
        let housework = try t.category("家事")
        let inHousework = try t.store.allProjects().filter { $0.category == housework }
        #expect(inHousework.filter { $0.name == "料理" }.count == 1)
        #expect(inHousework.filter { $0.name == "掃除" }.count == 1)
        let cookingInHousework = try #require(try t.store.projects().first { $0.category == housework && $0.name == "料理" })
        // 掃除はカテゴリごと家事になったので、ブロック名「掃除」はそのまま使う
        #expect(try session(t, s2).projectId == cleaningBlock.id)
        #expect(try session(t, s1).projectId == cookingInHousework.id)
        #expect(try session(t, s3).projectId == cookingInHousework.id)
        #expect(try [s1, s2, s3].allSatisfy { try session(t, $0).categoryId == housework.id })
        // もう一度通しても変わらない
        let ids = try t.store.allProjects().map(\.id)
        _ = try t.store.regroupDetoxCategories()
        #expect(try t.store.allProjects().map(\.id) == ids)
    }

    @Test func regroupMovesArchivedMeditationAndItsBlocks() throws {
        let t = try oldDevice()
        let meditation = try t.category("瞑想")
        let breathing = try #require(try t.store.createProject(name: "呼吸法", category: meditation))
        let a = try sessionRecord(t, category: meditation, start: "2026-10-19T07:00", end: "2026-10-19T07:15")
        let b = try sessionRecord(t, category: meditation, project: breathing, start: "2026-10-19T21:00", end: "2026-10-19T21:10")
        try t.store.setCategoryArchived(id: meditation.id, true)
        _ = try t.store.regroupDetoxCategories()
        let rest = try t.category("休み")
        #expect(try session(t, a).categoryId == rest.id)
        #expect(try session(t, a).projectId == (try t.store.projects().first { $0.category == rest && $0.name == "瞑想" })?.id)
        #expect(try session(t, b).categoryId == rest.id)
        #expect(try session(t, b).projectId == breathing.id)
        #expect(try t.store.projects().contains { $0.id == breathing.id && $0.category == rest })
        #expect(try !t.store.categories().contains { $0.name == "瞑想" })
    }

    @Test func focusNamedHouseworkKeepsRecordsWhereTheyAre() throws {
        let t = try oldDevice()
        _ = try t.store.createCategory(name: "家事", countsAsFocus: true, detoxGroup: nil)
        let cooking = try t.category("料理")
        let a = try sessionRecord(t, category: cooking, start: "2026-10-19T08:00", end: "2026-10-19T08:30")
        _ = try t.store.regroupDetoxCategories()
        // 集中の「家事」には移さない（デトックスの記録を集中にしない）
        #expect(try session(t, a).categoryId == cooking.id)
        #expect(try session(t, a).countsAsFocus == false)
        #expect(try t.store.categories().contains { $0.name == "料理" })
    }

    @Test func focusNamedRestGivesMeditationOnlyTheGroup() throws {
        let t = try oldDevice()
        try t.store.updateCategory(id: try t.category("休み").id, name: "休み", countsAsFocus: true, detoxGroup: nil)
        let meditation = try t.category("瞑想")
        let a = try sessionRecord(t, category: meditation, start: "2026-10-19T07:00", end: "2026-10-19T07:15")
        _ = try t.store.regroupDetoxCategories()
        #expect(try session(t, a).categoryId == meditation.id)
        #expect(try t.category("瞑想").detoxGroup == .rest)
        #expect(try t.category("休み").detoxGroup == nil)
    }

    @Test func regroupKeepsBlockNamesInPlansAndTemplates() throws {
        let t = try oldDevice()
        let cooking = try t.category("料理")
        let menu = try #require(try t.store.createProject(name: "献立", category: cooking))
        let draft = PlanDraft(blocks: [PlanBlockDraft(start: jst("2026-10-19T18:00"), minutes: 30, category: cooking, project: menu)])
        try t.store.saveDraft(draft, dayKey: "2026-10-19", timeZone: tokyo)
        try t.store.saveTemplate(PlanTemplate(id: UUID(), name: "夕食",
                                              blocks: [.init(hour: 18, minute: 0, minutes: 30, category: cooking, project: menu)]))
        _ = try t.store.regroupDetoxCategories()
        let housework = try t.category("家事")
        let block = try #require(try t.store.plan(dayKey: "2026-10-19")?.draft.blocks.first)
        #expect(block.category == housework)
        #expect(block.project?.id == menu.id)
        let templateBlock = try #require(try t.store.templates().first?.blocks.first)
        #expect(templateBlock.category == housework)
        #expect(templateBlock.project?.id == menu.id)
    }

    // MARK: 直す前の時刻の残し方

    @Test func originalComesFromHealthOrNothing() throws {
        let t = try TestStore()
        // ヘルスケア → 手で直す：ヘルスケアの値が直す前
        try t.store.saveSleep(SleepLine(start: jst("2026-10-19T00:10"), end: jst("2026-10-19T07:05"), source: .health),
                              dayKey: "2026-10-19", timeZone: tokyo)
        try t.store.saveSleep(SleepLine(start: jst("2026-10-18T23:00"), end: jst("2026-10-19T08:00"), source: .manual),
                              dayKey: "2026-10-19", timeZone: tokyo)
        #expect(try t.store.sleep(dayKey: "2026-10-19")?.original
                == DateInterval(start: jst("2026-10-19T00:10"), end: jst("2026-10-19T07:05")))
        // 記録がない日にいきなり手で直した：直す前はない
        try t.store.saveSleep(SleepLine(start: jst("2026-10-19T23:00"), end: jst("2026-10-20T08:00"), source: .manual),
                              dayKey: "2026-10-20", timeZone: tokyo)
        #expect(try t.store.sleep(dayKey: "2026-10-20")?.original == nil)
    }

    @Test func manualFromBeforeVersion4StaysUncompared() throws {
        let t = try TestStore()
        let record = SleepRecord(dayKey: "2026-10-19", timeZoneId: "Asia/Tokyo", startAt: jst("2026-10-19T00:00"),
                                 endAt: jst("2026-10-19T07:00"), sourceRaw: "manual", at: jst("2026-10-19T08:00"))
        t.context.insert(record)
        try t.context.save()
        try t.store.saveSleep(SleepLine(start: jst("2026-10-18T22:00"), end: jst("2026-10-19T08:00"), source: .manual),
                              dayKey: "2026-10-19", timeZone: tokyo)
        let line = try #require(try t.store.sleep(dayKey: "2026-10-19"))
        #expect(line.original == nil)
        #expect(line.extendedPart == nil)
    }

    // MARK: 目標のゴーストも手で長くした所を同じに数える

    @Test func goalGhostUsesTheSameSleepCaps() throws {
        let c = DefaultCategories.all
        let plan = PlanDraft(blocks: [PlanBlockDraft(start: jst("2026-10-19T09:00"), minutes: 60, category: c[0])])
        let sleep = [DateInterval(start: jst("2026-10-18T23:00"), end: jst("2026-10-19T08:00"))]
        let caps = [DateInterval(start: jst("2026-10-19T04:00"), end: jst("2026-10-19T08:00"))]
        func goalAt8(_ caps: [DateInterval]) throws -> Double {
            let s = HomeSnapshot.make(now: jst("2026-10-19T08:00"), calendar: tokyoCalendar, todaySessions: [], plan: plan,
                                      lastWeekSessions: [], sleep: sleep, sleepCaps: caps)
            return try #require(s.opponentPoints(.goal, at: jst("2026-10-19T08:00")))
        }
        // 4:00〜8:00 の睡眠：直さなければ 9.0＋3.0、長くした所なら 6.0＋3.0（12.0 と 9.0 の差 3.0）
        #expect(abs(try goalAt8([]) - goalAt8(caps) - 3.0) < 0.0001)
    }
}
