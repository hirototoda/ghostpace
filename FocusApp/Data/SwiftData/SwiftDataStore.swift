import Foundation
import SwiftData

/// Repository の SwiftData 実装。保存に失敗したら変更を取り消して throw する（画面と保存内容をずらさない）。
@MainActor
final class SwiftDataStore: RecordStore {
    let context: ModelContext
    let clock: any AppClock
    /// 保存の直前に呼ぶ。テストと DEBUG の `-failSave` で保存を失敗させるために使う
    var saveHook: (() throws -> Void)?
    /// 保存するたびに増える番号（数え直しのキャッシュの目印、ANA-06・07）
    private(set) var revision = 0

    init(container: ModelContainer, clock: any AppClock) {
        context = ModelContext(container)
        context.autosaveEnabled = false
        self.clock = clock
    }

    /// 変更をまとめて保存する。途中で失敗したら（保存の失敗を含めて）変更を取り消して throw する。
    func write<T>(_ body: () throws -> T) throws -> T {
        do {
            let result = try body()
            // 何もしない操作（確定済みへの下書き保存など）は保存しない
            if context.hasChanges {
                try saveHook?()
                try context.save()
                revision += 1
            }
            return result
        } catch {
            context.rollback()
            throw error
        }
    }

    // MARK: カテゴリ・ブロック名

    func seedDefaultsIfNeeded() throws {
        try write {
            guard try context.fetchCount(FetchDescriptor<CategoryRecord>()) == 0 else { return }
            let now = clock.now()
            for (index, option) in DefaultCategories.all.enumerated() {
                let record = CategoryRecord(name: option.name, countsAsFocus: option.countsAsFocus, sortOrder: index, at: now)
                record.detoxGroupRaw = option.detoxGroup?.rawValue
                context.insert(record)
                for name in DefaultCategories.projects.first(where: { $0.category == option.name })?.names ?? [] {
                    context.insert(ProjectRecord(name: name, categoryId: record.id, at: now))
                }
            }
        }
    }

    func categories() throws -> [CategoryOption] {
        try allCategories(includeArchived: false)
    }

    func allCategories() throws -> [CategoryOption] {
        try allCategories(includeArchived: true)
    }

    private func allCategories(includeArchived: Bool) throws -> [CategoryOption] {
        let descriptor = FetchDescriptor<CategoryRecord>(sortBy: [SortDescriptor(\.sortOrder)])
        return try context.fetch(descriptor)
            .filter { includeArchived || !$0.isArchived }
            .map(Self.option)
    }

    private static func option(_ record: CategoryRecord) -> CategoryOption {
        CategoryOption(id: record.id, name: record.name, countsAsFocus: record.countsAsFocus,
                       detoxGroup: record.detoxGroupRaw.flatMap(DetoxGroup.init(rawValue:)))
    }

    func projects() throws -> [ProjectOption] {
        try allProjects(includeArchived: false)
    }

    func allProjects() throws -> [ProjectOption] {
        try allProjects(includeArchived: true)
    }

    private func allProjects(includeArchived: Bool) throws -> [ProjectOption] {
        let categories = try categoryMap()
        let descriptor = FetchDescriptor<ProjectRecord>(sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.name)])
        return try context.fetch(descriptor)
            .filter { includeArchived || !$0.isArchived }
            .map { ProjectOption(id: $0.id, name: $0.name, category: categories[$0.categoryId] ?? .unknown) }
    }

    func createProject(name: String, category: CategoryOption) throws -> ProjectOption? {
        return try write {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let categoryId = category.id
            let existing = try context.fetch(FetchDescriptor<ProjectRecord>(predicate: #Predicate {
                $0.categoryId == categoryId && $0.name == trimmed && !$0.isArchived
            }))
            if let record = existing.first {
                return ProjectOption(id: record.id, name: record.name, category: category)
            }
            let record = ProjectRecord(name: trimmed, categoryId: categoryId, at: clock.now())
            context.insert(record)
            return ProjectOption(id: record.id, name: trimmed, category: category)
        }
    }

    // MARK: 設定のカテゴリ・ブロック名

    func archivedCategories() throws -> [CategoryOption] {
        let descriptor = FetchDescriptor<CategoryRecord>(predicate: #Predicate { $0.isArchived },
                                                         sortBy: [SortDescriptor(\.sortOrder)])
        return try context.fetch(descriptor).map { CategoryOption(id: $0.id, name: $0.name, countsAsFocus: $0.countsAsFocus) }
    }

    func archivedProjects() throws -> [ProjectOption] {
        try allProjects().filter { project in
            try projectRecord(id: project.id).isArchived
        }
    }

    func createCategory(name: String, countsAsFocus: Bool, detoxGroup: DetoxGroup?) throws -> CategoryOption? {
        return try write {
            let trimmed = Self.trimmed(name)
            guard !trimmed.isEmpty else { return nil }
            if let existing = try activeCategory(named: trimmed) { return Self.option(existing) }
            let all = try context.fetch(FetchDescriptor<CategoryRecord>())
            let record = CategoryRecord(name: trimmed, countsAsFocus: countsAsFocus,
                                        sortOrder: (all.map(\.sortOrder).max() ?? -1) + 1, at: clock.now())
            record.detoxGroupRaw = countsAsFocus ? nil : detoxGroup?.rawValue
            context.insert(record)
            return Self.option(record)
        }
    }

    func updateCategory(id: UUID, name: String, countsAsFocus: Bool, detoxGroup: DetoxGroup?) throws {
        try write {
            let record = try categoryRecord(id: id)
            let trimmed = Self.trimmed(name)
            guard !trimmed.isEmpty else { throw RecordError.emptyName }
            if let other = try activeCategory(named: trimmed), other.id != id { throw RecordError.duplicateName }
            // 集中に切り替えるとグループは消す（settings.md）
            let groupRaw = countsAsFocus ? nil : detoxGroup?.rawValue
            guard record.name != trimmed || record.countsAsFocus != countsAsFocus || record.detoxGroupRaw != groupRaw else { return }
            record.name = trimmed
            record.countsAsFocus = countsAsFocus
            record.detoxGroupRaw = groupRaw
            record.updatedAt = clock.now()
        }
    }

    func setCategoryArchived(id: UUID, _ archived: Bool) throws {
        try write {
            let record = try categoryRecord(id: id)
            guard record.isArchived != archived else { return }
            if archived {
                let active = try context.fetchCount(FetchDescriptor<CategoryRecord>(predicate: #Predicate { !$0.isArchived }))
                guard active > 1 else { throw RecordError.lastCategory }
            } else if let other = try activeCategory(named: record.name), other.id != id {
                throw RecordError.duplicateName
            }
            record.isArchived = archived
            record.updatedAt = clock.now()
        }
    }

    func renameProject(id: UUID, name: String) throws {
        try write {
            let record = try projectRecord(id: id)
            let trimmed = Self.trimmed(name)
            guard !trimmed.isEmpty else { throw RecordError.emptyName }
            let categoryId = record.categoryId
            let same = try context.fetch(FetchDescriptor<ProjectRecord>(predicate: #Predicate {
                $0.categoryId == categoryId && $0.name == trimmed && !$0.isArchived
            }))
            if same.contains(where: { $0.id != id }) { throw RecordError.duplicateName }
            guard record.name != trimmed else { return }
            record.name = trimmed
            record.updatedAt = clock.now()
        }
    }

    func setProjectArchived(id: UUID, _ archived: Bool) throws {
        try write {
            let record = try projectRecord(id: id)
            guard record.isArchived != archived else { return }
            if !archived {
                let categoryId = record.categoryId, name = record.name
                let same = try context.fetch(FetchDescriptor<ProjectRecord>(predicate: #Predicate {
                    $0.categoryId == categoryId && $0.name == name && !$0.isArchived
                }))
                if !same.isEmpty { throw RecordError.duplicateName }
            }
            record.isArchived = archived
            record.updatedAt = clock.now()
        }
    }

    private static func trimmed(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func activeCategory(named name: String) throws -> CategoryRecord? {
        try context.fetch(FetchDescriptor<CategoryRecord>(predicate: #Predicate { $0.name == name && !$0.isArchived })).first
    }

    private func categoryRecord(id: UUID) throws -> CategoryRecord {
        var descriptor = FetchDescriptor<CategoryRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let record = try context.fetch(descriptor).first else { throw RecordError.notFound }
        return record
    }

    private func projectRecord(id: UUID) throws -> ProjectRecord {
        var descriptor = FetchDescriptor<ProjectRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let record = try context.fetch(descriptor).first else { throw RecordError.notFound }
        return record
    }

    /// 保存しているカテゴリと、行を持たない「ゲーム・SNS」（BLK-10）
    private func categoryMap() throws -> [UUID: CategoryOption] {
        var map = Dictionary(try allCategories().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        map[CategoryOption.gameSNS.id] = .gameSNS
        return map
    }

    private func projectMap() throws -> [UUID: ProjectOption] {
        Dictionary(try allProjects().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: 計画

    /// 同じ日の計画が複数あれば、更新日時が新しいもの。
    private func planRecord(dayKey: String) throws -> DailyPlanRecord? {
        var descriptor = FetchDescriptor<DailyPlanRecord>(predicate: #Predicate { $0.dayKey == dayKey },
                                                          sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func blockRecords(planId: UUID) throws -> [PlanBlockRecord] {
        try context.fetch(FetchDescriptor<PlanBlockRecord>(predicate: #Predicate { $0.planId == planId },
                                                           sortBy: [SortDescriptor(\.startAt)]))
    }

    func plan(dayKey: String) throws -> StoredPlan? {
        guard let record = try planRecord(dayKey: dayKey) else { return nil }
        let categories = try categoryMap()
        let projects = try projectMap()
        let blocks = try blockRecords(planId: record.id).filter { !$0.isRemoved }.map { block in
            PlanBlockDraft(id: block.id, start: block.startAt, minutes: Int(block.endAt.timeIntervalSince(block.startAt)) / 60,
                           category: categories[block.categoryId] ?? .unknown,
                           project: block.projectId.flatMap { projects[$0] })
        }
        return StoredPlan(status: PlanStatus(raw: record.statusRaw),
                          draft: PlanDraft(blocks: blocks, goalSeconds: record.goalEdited ? record.goalFocusSec : nil))
    }

    func snapshot(dayKey: String) throws -> [PlanSnapshotBlock]? {
        try planRecord(dayKey: dayKey)?.snapshotJSON.flatMap(PlanSnapshotBlock.decode)
    }

    func saveDraft(_ draft: PlanDraft, dayKey: String, timeZone: TimeZone) throws {
        try write {
            let record: DailyPlanRecord
            switch try planRecord(dayKey: dayKey) {
            case nil: record = insertPlan(dayKey: dayKey, timeZone: timeZone, status: .draft)
            case let existing? where PlanStatus(raw: existing.statusRaw) == .draft: record = existing
            default: return
            }
            try writeBlocks(draft, to: record, markRemoved: false)
            writeGoal(draft, to: record)
        }
    }

    func confirm(_ draft: PlanDraft, dayKey: String, timeZone: TimeZone) throws {
        try write {
            let record: DailyPlanRecord
            switch try planRecord(dayKey: dayKey) {
            case nil: record = insertPlan(dayKey: dayKey, timeZone: timeZone, status: .draft)
            case let existing?:
                switch PlanStatus(raw: existing.statusRaw) {
                // 計画なし日にも、あとから計画を作れる（2026-09-30 決定）
                case .draft, .skipped: record = existing
                case .confirmed, .unknown: return
                }
            }
            try writeBlocks(draft, to: record, markRemoved: false)
            writeGoal(draft, to: record)
            let now = clock.now()
            record.statusRaw = "confirmed"
            record.confirmedAt = now
            record.snapshotJSON = PlanSnapshotBlock.encode(draft.sortedBlocks.map(PlanSnapshotBlock.init))
            record.updatedAt = now
        }
    }

    func skip(dayKey: String, timeZone: TimeZone, goalSeconds: Int?) throws {
        try write {
            var goal = PlanDraft()
            goal.goalSeconds = goalSeconds.flatMap { $0 > 0 ? $0 : nil }
            switch try planRecord(dayKey: dayKey) {
            case nil:
                writeGoal(goal, to: insertPlan(dayKey: dayKey, timeZone: timeZone, status: .skipped))
            case let existing?:
                switch PlanStatus(raw: existing.statusRaw) {
                case .draft:
                    try blockRecords(planId: existing.id).forEach(context.delete)
                    existing.statusRaw = "skipped"
                    existing.updatedAt = clock.now()
                    // 下書きの目標は残さず、渡された目標にする
                    writeGoal(goal, to: existing)
                case .skipped, .unknown: return
                case .confirmed: throw RecordError.invalidPlanState
                }
            }
        }
    }

    func saveChanges(_ draft: PlanDraft, dayKey: String) throws {
        try write {
            guard let record = try planRecord(dayKey: dayKey), PlanStatus(raw: record.statusRaw) == .confirmed else {
                throw RecordError.invalidPlanState
            }
            try writeBlocks(draft, to: record, markRemoved: true)
            writeGoal(draft, to: record)
            record.updatedAt = clock.now()
        }
    }

    func setGoal(_ seconds: Int?, dayKey: String) throws {
        try write {
            guard let record = try planRecord(dayKey: dayKey) else { throw RecordError.notFound }
            var draft = PlanDraft()
            draft.goalSeconds = seconds
            writeGoal(draft, to: record)
        }
    }

    /// 目標（GHO-10）。手で決めていなければ（nil）計画に合わせて動く
    private func writeGoal(_ draft: PlanDraft, to plan: DailyPlanRecord) {
        let edited = draft.goalSeconds != nil
        guard plan.goalEdited != edited || plan.goalFocusSec != draft.goalSeconds else { return }
        plan.goalEdited = edited
        plan.goalFocusSec = draft.goalSeconds
        plan.updatedAt = clock.now()
    }

    private func insertPlan(dayKey: String, timeZone: TimeZone, status: PlanStatus) -> DailyPlanRecord {
        let record = DailyPlanRecord(dayKey: dayKey, timeZoneId: timeZone.identifier, statusRaw: status.raw ?? "draft", at: clock.now())
        context.insert(record)
        return record
    }

    /// ブロックを id で突き合わせて更新・追加する。なくなったものは、確定後なら削除の印、下書きなら行ごと消す。
    private func writeBlocks(_ draft: PlanDraft, to plan: DailyPlanRecord, markRemoved: Bool) throws {
        let now = clock.now()
        let existing = try blockRecords(planId: plan.id)
        let keep = Set(draft.blocks.map(\.id))
        for block in draft.blocks {
            if let record = existing.first(where: { $0.id == block.id }) {
                if record.startAt != block.start || record.endAt != block.end || record.categoryId != block.category.id
                    || record.projectId != block.project?.id || record.isRemoved {
                    record.startAt = block.start
                    record.endAt = block.end
                    record.categoryId = block.category.id
                    record.projectId = block.project?.id
                    record.isRemoved = false
                    record.updatedAt = now
                }
            } else {
                context.insert(PlanBlockRecord(id: block.id, planId: plan.id, startAt: block.start, endAt: block.end,
                                               categoryId: block.category.id, projectId: block.project?.id, at: now))
            }
        }
        for record in existing where !keep.contains(record.id) && !record.isRemoved {
            if markRemoved {
                record.isRemoved = true
                record.updatedAt = now
            } else {
                context.delete(record)
            }
        }
        plan.updatedAt = now
    }

    // MARK: セッション

    private func sessionRecord(id: UUID) throws -> FocusSessionRecord {
        var descriptor = FetchDescriptor<FocusSessionRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let record = try context.fetch(descriptor).first else { throw RecordError.notFound }
        return record
    }

    private func value(_ record: FocusSessionRecord, categories: [UUID: CategoryOption], projects: [UUID: ProjectOption]) -> FocusSession {
        // 集中かどうかは、今のカテゴリの設定ではなく開始したときの値
        var category = categories[record.categoryId] ?? .unknown
        category.countsAsFocus = record.countsAsFocus
        return FocusSession(id: record.id, dayKey: record.dayKey, category: category,
                            project: record.projectId.flatMap { projects[$0] }, planBlockId: record.planBlockId,
                            startAt: record.startAt, endAt: record.endAt, plannedEndAt: record.plannedEndAt,
                            plannedDurationSec: record.plannedDurationSec, pauses: PauseInterval.decode(record.pausesJSON),
                            originalEndAt: record.originalEndAt, isDeclared: record.isDeclared ?? false)
    }

    private func value(_ record: FocusSessionRecord) throws -> FocusSession {
        value(record, categories: try categoryMap(), projects: try projectMap())
    }

    /// 実行中が複数あれば、開始が新しいもの。
    private func runningRecord() throws -> FocusSessionRecord? {
        var descriptor = FetchDescriptor<FocusSessionRecord>(predicate: #Predicate { $0.endAt == nil },
                                                             sortBy: [SortDescriptor(\.startAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func runningSession() throws -> FocusSession? {
        try runningRecord().map(value)
    }

    func start(_ request: StartRequest) throws -> FocusSession {
        return try write {
            guard try runningRecord() == nil else { throw RecordError.alreadyRunning }
            let now = clock.now()
            let record = FocusSessionRecord(
                dayKey: DayBoundary.dayKey(containing: now, calendar: .app(timeZone: request.timeZone)),
                timeZoneId: request.timeZone.identifier, planBlockId: request.planBlockId,
                categoryId: request.category.id, countsAsFocus: request.category.countsAsFocus,
                projectId: request.project?.id, startAt: now,
                plannedEndAt: request.plannedEndAt, plannedDurationSec: request.plannedDurationSec, at: now)
            context.insert(record)
            return try value(record)
        }
    }

    /// 押し忘れの申告（TMR-13）。終わった記録として、申告の印を付けて足す。できるかどうかは呼ぶ側で確かめる
    func declare(_ request: DeclareRequest) throws -> FocusSession {
        try write {
            guard request.end > request.start else { throw SessionError.invalidEnd }
            let record = FocusSessionRecord(
                dayKey: DayBoundary.dayKey(containing: request.start, calendar: .app(timeZone: request.timeZone)),
                timeZoneId: request.timeZone.identifier, planBlockId: request.planBlockId,
                categoryId: request.category.id, countsAsFocus: request.category.countsAsFocus,
                projectId: request.project?.id, startAt: request.start,
                plannedEndAt: request.plannedEndAt, plannedDurationSec: nil, at: clock.now())
            record.endAt = request.end
            record.isDeclared = true
            context.insert(record)
            return try value(record)
        }
    }

    func pause(id: UUID) throws {
        try write {
            let record = try sessionRecord(id: id)
            var pauses = PauseInterval.decode(record.pausesJSON)
            guard record.endAt == nil, pauses.last.map({ $0.end != nil }) ?? true else { return }
            let now = clock.now()
            pauses.append(PauseInterval(start: now, end: nil))
            record.pausesJSON = PauseInterval.encode(pauses)
            record.updatedAt = now
        }
    }

    func resume(id: UUID) throws {
        try write {
            let record = try sessionRecord(id: id)
            var pauses = PauseInterval.decode(record.pausesJSON)
            guard record.endAt == nil, let last = pauses.indices.last, pauses[last].end == nil else { return }
            let now = clock.now()
            pauses[last].end = now
            record.pausesJSON = PauseInterval.encode(pauses)
            record.updatedAt = now
        }
    }

    func end(id: UUID, reportedEnd: Date?) throws -> EndResult {
        return try write {
            let record = try sessionRecord(id: id)
            guard record.endAt == nil else { return .saved }
            let now = clock.now()
            let target = reportedEnd ?? now
            // 開始と同じ瞬間（またはそれより前）に終えたら、長さ0として記録しない
            let ended = target > record.startAt ? try value(record).ending(at: now, reportedEnd: target) : nil
            if (ended?.activeDuration(at: now) ?? 0) < FocusSession.minimumSeconds {
                context.delete(record)
                return .discardedTooShort
            }
            guard let ended else { return .discardedTooShort }
            record.endAt = ended.endAt
            record.pausesJSON = PauseInterval.encode(ended.pauses)
            record.originalEndAt = ended.originalEndAt
            record.updatedAt = now
            return .saved
        }
    }

    func shortenEnd(id: UUID, to newEnd: Date) throws {
        try write {
            let record = try sessionRecord(id: id)
            let shortened = try value(record).shortened(to: newEnd)
            record.endAt = shortened.endAt
            record.pausesJSON = PauseInterval.encode(shortened.pauses)
            record.originalEndAt = shortened.originalEndAt
            record.updatedAt = clock.now()
        }
    }

    func allSessions() throws -> [FocusSession] {
        let categories = try categoryMap()
        let projects = try projectMap()
        return try context.fetch(FetchDescriptor<FocusSessionRecord>(sortBy: [SortDescriptor(\.startAt)]))
            .map { value($0, categories: categories, projects: projects) }
    }

    func sessions(dayKey: String) throws -> [FocusSession] {
        let categories = try categoryMap()
        let projects = try projectMap()
        let descriptor = FetchDescriptor<FocusSessionRecord>(predicate: #Predicate { $0.dayKey == dayKey },
                                                             sortBy: [SortDescriptor(\.startAt)])
        return try context.fetch(descriptor).map { value($0, categories: categories, projects: projects) }
    }

    // MARK: テンプレート（PLN-07）

    private func templateRecords() throws -> [PlanTemplateRecord] {
        try context.fetch(FetchDescriptor<PlanTemplateRecord>(sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)]))
    }

    func templates() throws -> [PlanTemplate] {
        let categories = try categoryMap()
        let projects = try projectMap()
        return try templateRecords().map { record in
            PlanTemplate(id: record.id, name: record.name, blocks: TemplateBlockValue.decode(record.blocksJSON).map { value in
                PlanTemplate.Block(hour: value.hour, minute: value.minute, minutes: value.minutes,
                                   category: categories[value.categoryId] ?? .unknown,
                                   project: value.projectId.flatMap { projects[$0] })
            })
        }
    }

    func saveTemplate(_ template: PlanTemplate) throws {
        try write {
            let name = Self.trimmed(template.name)
            guard !name.isEmpty else { throw RecordError.emptyName }
            let json = TemplateBlockValue.encode(template.sortedBlocks.map(TemplateBlockValue.init))
            let records = try templateRecords()
            if let record = records.first(where: { $0.id == template.id }) {
                record.name = name
                record.blocksJSON = json
                record.updatedAt = clock.now()
                return
            }
            guard records.count < PlanTemplate.maxCount else { throw RecordError.tooManyTemplates }
            context.insert(PlanTemplateRecord(id: template.id, name: name, sortOrder: (records.map(\.sortOrder).max() ?? -1) + 1,
                                              blocksJSON: json, at: clock.now()))
        }
    }

    func deleteTemplate(id: UUID) throws {
        try write {
            try templateRecords().filter { $0.id == id }.forEach(context.delete)
        }
    }

    func seedTemplatesIfNeeded() throws -> Bool {
        guard try context.fetchCount(FetchDescriptor<PlanTemplateRecord>()) == 0 else { return false }
        try saveTemplate(.idealHoliday(categories: try categories(), projects: try projects()))
        return true
    }
}

/// テンプレートのブロックの保存形（JSON）。読めなければ空として扱う。
struct TemplateBlockValue: Codable, Hashable {
    var hour: Int
    var minute: Int
    var minutes: Int
    var categoryId: UUID
    var projectId: UUID?

    init(_ block: PlanTemplate.Block) {
        hour = block.hour
        minute = block.minute
        minutes = block.minutes
        categoryId = block.category.id
        projectId = block.project?.id
    }

    static func encode(_ values: [TemplateBlockValue]) -> Data {
        (try? JSONEncoder().encode(values)) ?? Data("[]".utf8)
    }

    static func decode(_ data: Data) -> [TemplateBlockValue] {
        (try? JSONDecoder().decode([TemplateBlockValue].self, from: data)) ?? []
    }
}

// MARK: 睡眠（DTX-02）

extension SwiftDataStore {
    private func sleepRecord(dayKey: String) throws -> SleepRecord? {
        // 同じ日が2つあれば、更新日時が新しいものを使う（data-model.md）
        try context.fetch(FetchDescriptor<SleepRecord>(predicate: #Predicate { $0.dayKey == dayKey },
                                                       sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])).first
    }

    func sleep(dayKey: String) throws -> SleepLine? {
        try sleepRecord(dayKey: dayKey).map {
            var line = SleepLine(start: $0.startAt, end: $0.endAt, source: SleepLine.Source(raw: $0.sourceRaw))
            if let start = $0.originalStartAt, let end = $0.originalEndAt, end > start {
                line.original = DateInterval(start: start, end: end)
            }
            return line
        }
    }

    func saveSleep(_ sleep: SleepLine, dayKey: String, timeZone: TimeZone) throws {
        try write {
            if let record = try sleepRecord(dayKey: dayKey) {
                // 初めて手で直すとき、直す前の値を残す（以後変えない。第4版、DTX-02・03）
                if sleep.source == .manual, SleepLine.Source(raw: record.sourceRaw) != .manual, record.originalStartAt == nil {
                    record.originalStartAt = record.startAt
                    record.originalEndAt = record.endAt
                }
                // ヘルスケアから読み直したら「直す前」も消す（次に手で直すときは読み直した値が直す前。2026-10-03）
                if sleep.source == .health {
                    record.originalStartAt = nil
                    record.originalEndAt = nil
                }
                record.startAt = sleep.start
                record.endAt = sleep.end
                record.sourceRaw = sleep.source.rawValue
                record.timeZoneId = timeZone.identifier
                record.updatedAt = clock.now()
            } else {
                context.insert(SleepRecord(dayKey: dayKey, timeZoneId: timeZone.identifier, startAt: sleep.start,
                                           endAt: sleep.end, sourceRaw: sleep.source.rawValue, at: clock.now()))
            }
        }
    }
}
