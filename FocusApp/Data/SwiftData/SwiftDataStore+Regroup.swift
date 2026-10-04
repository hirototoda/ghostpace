import Foundation
import SwiftData

// MARK: カテゴリの組み替え（2026-10-03、settings.md「カテゴリの組み替え」、CAT-01・DTX-03）

extension SwiftDataStore {
    /// 掃除・料理を家事の、瞑想を休みのブロック名に組み替え、タイマーの記録・計画のブロック・テンプレートを付け替える。
    /// 朝の計画の写し（PLN-03）と、記録に写した集中かどうかは変えない。1回の保存でまとめて行う（失敗したら何も変えない）。
    /// もう一度通しても結果は同じ。終えたら true
    func regroupDetoxCategories() throws -> Bool {
        try write {
            var plan = RegroupPlan(categories: try context.fetch(FetchDescriptor<CategoryRecord>(sortBy: [SortDescriptor(\.sortOrder)])),
                                   projects: try context.fetch(FetchDescriptor<ProjectRecord>()), now: clock.now())
            plan.move(sources: ["掃除", "料理"], to: DefaultCategories.housework, group: .housework, renaming: "掃除", context: context)
            plan.move(sources: ["瞑想"], to: DefaultCategories.rest, group: .rest, renaming: nil, context: context)
            plan.assignGroups()
            try remapRecords(plan.categoryMap, projects: plan.projectMap, blockForCategory: plan.blockForCategory)
            return true
        }
    }

    /// 記録・計画のブロック・テンプレートのカテゴリとブロック名を付け替える
    private func remapRecords(_ categories: [UUID: UUID], projects: [UUID: UUID], blockForCategory: [UUID: UUID]) throws {
        guard !categories.isEmpty || !blockForCategory.isEmpty else { return }
        let now = clock.now()
        func remap(category: UUID, project: UUID?) -> (UUID, UUID?)? {
            let newCategory = categories[category] ?? category
            let newProject = project.map { projects[$0] ?? $0 } ?? blockForCategory[category]
            guard newCategory != category || newProject != project else { return nil }
            return (newCategory, newProject)
        }
        for record in try context.fetch(FetchDescriptor<FocusSessionRecord>()) {
            guard let (category, project) = remap(category: record.categoryId, project: record.projectId) else { continue }
            record.categoryId = category
            record.projectId = project
            record.updatedAt = now
        }
        for record in try context.fetch(FetchDescriptor<PlanBlockRecord>()) {
            guard let (category, project) = remap(category: record.categoryId, project: record.projectId) else { continue }
            record.categoryId = category
            record.projectId = project
            record.updatedAt = now
        }
        for record in try context.fetch(FetchDescriptor<PlanTemplateRecord>()) {
            var changed = false
            let values = TemplateBlockValue.decode(record.blocksJSON).map { value in
                guard let (category, project) = remap(category: value.categoryId, project: value.projectId) else { return value }
                changed = true
                var value = value
                value.categoryId = category
                value.projectId = project
                return value
            }
            if changed {
                record.blocksJSON = TemplateBlockValue.encode(values)
                record.updatedAt = now
            }
        }
    }
}

/// 組み替えの中身。カテゴリとブロック名の行を直し、記録の付け替え表を作る
private struct RegroupPlan {
    var categories: [CategoryRecord]
    var projects: [ProjectRecord]
    let now: Date
    /// もとのカテゴリ → 行き先のカテゴリ
    var categoryMap: [UUID: UUID] = [:]
    /// まとめたブロック名 → 残すブロック名
    var projectMap: [UUID: UUID] = [:]
    /// ブロック名のない記録に付けるブロック名（もとのカテゴリ → そのカテゴリ名のブロック名）
    var blockForCategory: [UUID: UUID] = [:]

    init(categories: [CategoryRecord], projects: [ProjectRecord], now: Date) {
        self.categories = categories
        self.projects = projects
        self.now = now
    }

    private func active(_ name: String) -> CategoryRecord? {
        categories.first { $0.name == name && !$0.isArchived }
    }

    /// `sources`（デトックスのもの。アーカイブ済みも）を `name` のカテゴリのブロック名にする
    mutating func move(sources names: [String], to name: String, group: DetoxGroup, renaming: String?, context: ModelContext) {
        let sources = categories.filter { names.contains($0.name) && !$0.countsAsFocus }
        guard !sources.isEmpty else { return }
        // 同じ名前の集中のカテゴリがある：名前が重なるので組み替えず、グループだけ付ける
        if let existing = active(name), existing.countsAsFocus {
            for source in sources where !source.isArchived { setGroup(source, group) }
            return
        }
        let destination: CategoryRecord
        if let existing = active(name) {
            destination = existing
        } else if let from = renaming, let source = active(from), !source.countsAsFocus {
            source.name = name
            source.updatedAt = now
            destination = source
        } else {
            destination = CategoryRecord(name: name, countsAsFocus: false,
                                         sortOrder: (categories.map(\.sortOrder).max() ?? -1) + 1, at: now)
            context.insert(destination)
            categories.append(destination)
        }
        setGroup(destination, group)
        // 行き先のブロック名（デフォルトのもの）
        for blockName in DefaultCategories.projects.first(where: { $0.category == name })?.names ?? [] {
            _ = project(named: blockName, in: destination, context: context)
        }
        for source in sources {
            // もとのカテゴリの中のブロック名を行き先に移す（同じ名前があればまとめる）
            for record in projects where record.categoryId == source.id && source.id != destination.id {
                if let same = projects.first(where: { $0.categoryId == destination.id && $0.name == record.name && $0.id != record.id }) {
                    projectMap[record.id] = same.id
                    if !record.isArchived { record.isArchived = true; record.updatedAt = now }
                } else {
                    record.categoryId = destination.id
                    record.updatedAt = now
                }
            }
            let sourceName = source.id == destination.id ? (renaming ?? source.name) : source.name
            blockForCategory[source.id] = project(named: sourceName, in: destination, context: context).id
            if source.id != destination.id {
                categoryMap[source.id] = destination.id
                if !source.isArchived { source.isArchived = true; source.updatedAt = now }
            }
        }
    }

    /// 行き先の `name` のブロック名（アーカイブ済みなら戻す。なければ作る）
    private mutating func project(named name: String, in category: CategoryRecord, context: ModelContext) -> ProjectRecord {
        if let existing = projects.first(where: { $0.categoryId == category.id && $0.name == name }) {
            if existing.isArchived { existing.isArchived = false; existing.updatedAt = now }
            return existing
        }
        let record = ProjectRecord(name: name, categoryId: category.id, at: now)
        context.insert(record)
        projects.append(record)
        return record
    }

    /// 運動と、それまで名前でグループを決めていたデトックスのカテゴリ（洗濯・休憩など）にグループを付ける
    func assignGroups() {
        for record in categories where !record.countsAsFocus && !record.isArchived && record.detoxGroupRaw == nil {
            if let group = Self.legacyGroup(name: record.name) { setGroup(record, group) }
        }
    }

    /// 組み替えの前に名前で決めていたグループ（点が下がらないように同じにする。settings.md）。組み替えだけで使う
    private static func legacyGroup(name: String) -> DetoxGroup? {
        switch name {
        case "家事", "掃除", "料理", "洗濯": .housework
        case "運動": .exercise
        case "休み", "瞑想", "休憩": .rest
        default: nil
        }
    }

    private func setGroup(_ record: CategoryRecord, _ group: DetoxGroup) {
        guard record.detoxGroupRaw != group.rawValue else { return }
        record.detoxGroupRaw = group.rawValue
        record.updatedAt = now
    }
}
