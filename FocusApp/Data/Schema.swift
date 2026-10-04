import Foundation
import SwiftData

/// 保存データの形の第1版（docs/design/data-model.md）。
/// 形を変えるときは次の版を足し、AppMigrationPlan に stage を追加する。前の版を書き換えない（NFR-02）。
/// エンティティ間は UUID で参照し、@Relationship は使わない（docs/decisions/0012）。
enum SchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [CategoryRecord.self, ProjectRecord.self, DailyPlanRecord.self, PlanBlockRecord.self, FocusSessionRecord.self]
    }

    @Model
    final class CategoryRecord {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date
        var name: String
        var countsAsFocus: Bool
        var sortOrder: Int
        var isArchived: Bool

        init(id: UUID = UUID(), name: String, countsAsFocus: Bool, sortOrder: Int, isArchived: Bool = false, at date: Date) {
            self.id = id
            self.createdAt = date
            self.updatedAt = date
            self.name = name
            self.countsAsFocus = countsAsFocus
            self.sortOrder = sortOrder
            self.isArchived = isArchived
        }
    }

    @Model
    final class ProjectRecord {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date
        var name: String
        var categoryId: UUID
        var isArchived: Bool

        init(id: UUID = UUID(), name: String, categoryId: UUID, isArchived: Bool = false, at date: Date) {
            self.id = id
            self.createdAt = date
            self.updatedAt = date
            self.name = name
            self.categoryId = categoryId
            self.isArchived = isArchived
        }
    }

    @Model
    final class DailyPlanRecord {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date
        var dayKey: String
        var timeZoneId: String
        /// draft / confirmed / skipped（PlanStatus）
        var statusRaw: String
        var confirmedAt: Date?
        /// 確定時の [PlanSnapshotBlock] の JSON（PLN-03）。以後変更しない
        var snapshotJSON: Data?

        init(id: UUID = UUID(), dayKey: String, timeZoneId: String, statusRaw: String, at date: Date) {
            self.id = id
            self.createdAt = date
            self.updatedAt = date
            self.dayKey = dayKey
            self.timeZoneId = timeZoneId
            self.statusRaw = statusRaw
        }
    }

    @Model
    final class PlanBlockRecord {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date
        var planId: UUID
        var startAt: Date
        var endAt: Date
        var categoryId: UUID
        var projectId: UUID?
        /// 日中の変更で消したブロック（予実分析用に残す）。PersistentModel.isDeleted と名前が衝突するため isRemoved
        var isRemoved: Bool

        init(id: UUID, planId: UUID, startAt: Date, endAt: Date, categoryId: UUID, projectId: UUID?, at date: Date) {
            self.id = id
            self.createdAt = date
            self.updatedAt = date
            self.planId = planId
            self.startAt = startAt
            self.endAt = endAt
            self.categoryId = categoryId
            self.projectId = projectId
            self.isRemoved = false
        }
    }

    @Model
    final class FocusSessionRecord {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date
        var dayKey: String
        var timeZoneId: String
        var planBlockId: UUID?
        var categoryId: UUID
        /// 開始したときにカテゴリが「集中に数える」だったか。後からカテゴリの設定を変えても過去の記録は変わらない（2026-09-30 決定）
        var countsAsFocus: Bool
        var projectId: UUID?
        var startAt: Date
        /// nil なら実行中
        var endAt: Date?
        /// 計画ブロックから開始したときの終了予定（一時停止しても動かない）
        var plannedEndAt: Date?
        /// 計画外で長さを決めたときの長さ（一時停止した分だけ終わりがずれる）
        var plannedDurationSec: Int?
        /// [PauseInterval] の JSON（TMR-03）
        var pausesJSON: Data
        /// 終了時刻を早めたときの元の終了時刻（TMR-08）
        var originalEndAt: Date?
        var note: String?

        init(id: UUID = UUID(), dayKey: String, timeZoneId: String, planBlockId: UUID?, categoryId: UUID, countsAsFocus: Bool,
             projectId: UUID?, startAt: Date, plannedEndAt: Date?, plannedDurationSec: Int?, at date: Date) {
            self.id = id
            self.createdAt = date
            self.updatedAt = date
            self.dayKey = dayKey
            self.timeZoneId = timeZoneId
            self.planBlockId = planBlockId
            self.categoryId = categoryId
            self.countsAsFocus = countsAsFocus
            self.projectId = projectId
            self.startAt = startAt
            self.plannedEndAt = plannedEndAt
            self.plannedDurationSec = plannedDurationSec
            self.pausesJSON = Data("[]".utf8)
        }
    }
}

/// 第2版（2026-10-01）：1日の計画に目標（GHO-10）、計画のテンプレート（PLN-07）を足した。
/// 第1版からは軽量の移行（項目と種類を足すだけ。足した項目には初期値がある）。
enum SchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)

    static var models: [any PersistentModel.Type] {
        [CategoryRecord.self, ProjectRecord.self, DailyPlanRecord.self, PlanBlockRecord.self, FocusSessionRecord.self,
         PlanTemplateRecord.self]
    }

    @Model
    final class CategoryRecord {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date
        var name: String
        var countsAsFocus: Bool
        var sortOrder: Int
        var isArchived: Bool

        init(id: UUID = UUID(), name: String, countsAsFocus: Bool, sortOrder: Int, isArchived: Bool = false, at date: Date) {
            self.id = id
            self.createdAt = date
            self.updatedAt = date
            self.name = name
            self.countsAsFocus = countsAsFocus
            self.sortOrder = sortOrder
            self.isArchived = isArchived
        }
    }

    @Model
    final class ProjectRecord {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date
        var name: String
        var categoryId: UUID
        var isArchived: Bool

        init(id: UUID = UUID(), name: String, categoryId: UUID, isArchived: Bool = false, at date: Date) {
            self.id = id
            self.createdAt = date
            self.updatedAt = date
            self.name = name
            self.categoryId = categoryId
            self.isArchived = isArchived
        }
    }

    @Model
    final class DailyPlanRecord {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date
        var dayKey: String
        var timeZoneId: String
        /// draft / confirmed / skipped（PlanStatus）
        var statusRaw: String
        var confirmedAt: Date?
        /// 確定時の [PlanSnapshotBlock] の JSON（PLN-03）。以後変更しない
        var snapshotJSON: Data?
        /// 手で決めた今日の目標（GHO-10）。nil なら計画の集中の合計
        var goalFocusSec: Int? = nil
        /// 目標を手で変えたか
        var goalEdited: Bool = false

        init(id: UUID = UUID(), dayKey: String, timeZoneId: String, statusRaw: String, at date: Date) {
            self.id = id
            self.createdAt = date
            self.updatedAt = date
            self.dayKey = dayKey
            self.timeZoneId = timeZoneId
            self.statusRaw = statusRaw
        }
    }

    @Model
    final class PlanBlockRecord {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date
        var planId: UUID
        var startAt: Date
        var endAt: Date
        var categoryId: UUID
        var projectId: UUID?
        /// 日中の変更で消したブロック（予実分析用に残す）。PersistentModel.isDeleted と名前が衝突するため isRemoved
        var isRemoved: Bool

        init(id: UUID, planId: UUID, startAt: Date, endAt: Date, categoryId: UUID, projectId: UUID?, at date: Date) {
            self.id = id
            self.createdAt = date
            self.updatedAt = date
            self.planId = planId
            self.startAt = startAt
            self.endAt = endAt
            self.categoryId = categoryId
            self.projectId = projectId
            self.isRemoved = false
        }
    }

    @Model
    final class FocusSessionRecord {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date
        var dayKey: String
        var timeZoneId: String
        var planBlockId: UUID?
        var categoryId: UUID
        /// 開始したときにカテゴリが「集中に数える」だったか。後からカテゴリの設定を変えても過去の記録は変わらない（2026-09-30 決定）
        var countsAsFocus: Bool
        var projectId: UUID?
        var startAt: Date
        /// nil なら実行中
        var endAt: Date?
        /// 計画ブロックから開始したときの終了予定（一時停止しても動かない）
        var plannedEndAt: Date?
        /// 計画外で長さを決めたときの長さ（一時停止した分だけ終わりがずれる）
        var plannedDurationSec: Int?
        /// [PauseInterval] の JSON（TMR-03）
        var pausesJSON: Data
        /// 終了時刻を早めたときの元の終了時刻（TMR-08）
        var originalEndAt: Date?
        var note: String?

        init(id: UUID = UUID(), dayKey: String, timeZoneId: String, planBlockId: UUID?, categoryId: UUID, countsAsFocus: Bool,
             projectId: UUID?, startAt: Date, plannedEndAt: Date?, plannedDurationSec: Int?, at date: Date) {
            self.id = id
            self.createdAt = date
            self.updatedAt = date
            self.dayKey = dayKey
            self.timeZoneId = timeZoneId
            self.planBlockId = planBlockId
            self.categoryId = categoryId
            self.countsAsFocus = countsAsFocus
            self.projectId = projectId
            self.startAt = startAt
            self.plannedEndAt = plannedEndAt
            self.plannedDurationSec = plannedDurationSec
            self.pausesJSON = Data("[]".utf8)
        }
    }

    /// 計画のテンプレート（PLN-07）。最大7つ。時刻は「時:分」だけ持つ
    @Model
    final class PlanTemplateRecord {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date
        var name: String
        var sortOrder: Int
        /// [TemplateBlockValue] の JSON
        var blocksJSON: Data

        init(id: UUID = UUID(), name: String, sortOrder: Int, blocksJSON: Data, at date: Date) {
            self.id = id
            self.createdAt = date
            self.updatedAt = date
            self.name = name
            self.sortOrder = sortOrder
            self.blocksJSON = blocksJSON
        }
    }
}

/// 保存データの形の第3版（2026-10-02）：睡眠の記録（SleepRecord、DTX-02）を足した。ほかは第2版と同じ。
enum SchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)

    static var models: [any PersistentModel.Type] {
        [CategoryRecord.self, ProjectRecord.self, DailyPlanRecord.self, PlanBlockRecord.self, FocusSessionRecord.self,
         PlanTemplateRecord.self, SleepRecord.self]
    }

    @Model
    final class CategoryRecord {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date
        var name: String
        var countsAsFocus: Bool
        var sortOrder: Int
        var isArchived: Bool

        init(id: UUID = UUID(), name: String, countsAsFocus: Bool, sortOrder: Int, isArchived: Bool = false, at date: Date) {
            self.id = id
            self.createdAt = date
            self.updatedAt = date
            self.name = name
            self.countsAsFocus = countsAsFocus
            self.sortOrder = sortOrder
            self.isArchived = isArchived
        }
    }

    @Model
    final class ProjectRecord {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date
        var name: String
        var categoryId: UUID
        var isArchived: Bool

        init(id: UUID = UUID(), name: String, categoryId: UUID, isArchived: Bool = false, at date: Date) {
            self.id = id
            self.createdAt = date
            self.updatedAt = date
            self.name = name
            self.categoryId = categoryId
            self.isArchived = isArchived
        }
    }

    @Model
    final class DailyPlanRecord {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date
        var dayKey: String
        var timeZoneId: String
        /// draft / confirmed / skipped（PlanStatus）
        var statusRaw: String
        var confirmedAt: Date?
        /// 確定時の [PlanSnapshotBlock] の JSON（PLN-03）。以後変更しない
        var snapshotJSON: Data?
        /// 手で決めた今日の目標（GHO-10）。nil なら計画の集中の合計
        var goalFocusSec: Int? = nil
        /// 目標を手で変えたか
        var goalEdited: Bool = false

        init(id: UUID = UUID(), dayKey: String, timeZoneId: String, statusRaw: String, at date: Date) {
            self.id = id
            self.createdAt = date
            self.updatedAt = date
            self.dayKey = dayKey
            self.timeZoneId = timeZoneId
            self.statusRaw = statusRaw
        }
    }

    @Model
    final class PlanBlockRecord {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date
        var planId: UUID
        var startAt: Date
        var endAt: Date
        var categoryId: UUID
        var projectId: UUID?
        /// 日中の変更で消したブロック（予実分析用に残す）。PersistentModel.isDeleted と名前が衝突するため isRemoved
        var isRemoved: Bool

        init(id: UUID, planId: UUID, startAt: Date, endAt: Date, categoryId: UUID, projectId: UUID?, at date: Date) {
            self.id = id
            self.createdAt = date
            self.updatedAt = date
            self.planId = planId
            self.startAt = startAt
            self.endAt = endAt
            self.categoryId = categoryId
            self.projectId = projectId
            self.isRemoved = false
        }
    }

    @Model
    final class FocusSessionRecord {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date
        var dayKey: String
        var timeZoneId: String
        var planBlockId: UUID?
        var categoryId: UUID
        /// 開始したときにカテゴリが「集中に数える」だったか。後からカテゴリの設定を変えても過去の記録は変わらない（2026-09-30 決定）
        var countsAsFocus: Bool
        var projectId: UUID?
        var startAt: Date
        /// nil なら実行中
        var endAt: Date?
        /// 計画ブロックから開始したときの終了予定（一時停止しても動かない）
        var plannedEndAt: Date?
        /// 計画外で長さを決めたときの長さ（一時停止した分だけ終わりがずれる）
        var plannedDurationSec: Int?
        /// [PauseInterval] の JSON（TMR-03）
        var pausesJSON: Data
        /// 終了時刻を早めたときの元の終了時刻（TMR-08）
        var originalEndAt: Date?
        var note: String?

        init(id: UUID = UUID(), dayKey: String, timeZoneId: String, planBlockId: UUID?, categoryId: UUID, countsAsFocus: Bool,
             projectId: UUID?, startAt: Date, plannedEndAt: Date?, plannedDurationSec: Int?, at date: Date) {
            self.id = id
            self.createdAt = date
            self.updatedAt = date
            self.dayKey = dayKey
            self.timeZoneId = timeZoneId
            self.planBlockId = planBlockId
            self.categoryId = categoryId
            self.countsAsFocus = countsAsFocus
            self.projectId = projectId
            self.startAt = startAt
            self.plannedEndAt = plannedEndAt
            self.plannedDurationSec = plannedDurationSec
            self.pausesJSON = Data("[]".utf8)
        }
    }

    /// 計画のテンプレート（PLN-07）。最大7つ。時刻は「時:分」だけ持つ
    @Model
    final class PlanTemplateRecord {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date
        var name: String
        var sortOrder: Int
        /// [TemplateBlockValue] の JSON
        var blocksJSON: Data

        init(id: UUID = UUID(), name: String, sortOrder: Int, blocksJSON: Data, at date: Date) {
            self.id = id
            self.createdAt = date
            self.updatedAt = date
            self.name = name
            self.sortOrder = sortOrder
            self.blocksJSON = blocksJSON
        }
    }

    /// 睡眠の記録（DTX-02、第3版）。その日の朝に終わった睡眠。1日に1つ
    @Model
    final class SleepRecord {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date
        var dayKey: String
        var timeZoneId: String
        var startAt: Date
        var endAt: Date
        /// health（ヘルスケア）／setting（設定の時刻）／manual（手で直した）
        var sourceRaw: String

        init(id: UUID = UUID(), dayKey: String, timeZoneId: String, startAt: Date, endAt: Date, sourceRaw: String, at date: Date) {
            self.id = id
            self.createdAt = date
            self.updatedAt = date
            self.dayKey = dayKey
            self.timeZoneId = timeZoneId
            self.startAt = startAt
            self.endAt = endAt
            self.sourceRaw = sourceRaw
        }
    }
}

/// 第4版（2026-10-03）：カテゴリにデトックスのグループ、睡眠に手で直す前の時刻を足した（DTX-03・DTX-02）。
/// どちらも空を許す項目なので、第3版から軽量の移行で読める
enum SchemaV4: VersionedSchema {
    static let versionIdentifier = Schema.Version(4, 0, 0)

    static var models: [any PersistentModel.Type] {
        [CategoryRecord.self, ProjectRecord.self, DailyPlanRecord.self, PlanBlockRecord.self, FocusSessionRecord.self,
         PlanTemplateRecord.self, SleepRecord.self]
    }

    @Model
    final class CategoryRecord {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date
        var name: String
        var countsAsFocus: Bool
        var sortOrder: Int
        var isArchived: Bool
        /// デトックスのグループ（housework／exercise／rest）。nil は上乗せなし（第4版、DTX-03）
        var detoxGroupRaw: String? = nil

        init(id: UUID = UUID(), name: String, countsAsFocus: Bool, sortOrder: Int, isArchived: Bool = false, at date: Date) {
            self.id = id
            self.createdAt = date
            self.updatedAt = date
            self.name = name
            self.countsAsFocus = countsAsFocus
            self.sortOrder = sortOrder
            self.isArchived = isArchived
        }
    }

    @Model
    final class ProjectRecord {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date
        var name: String
        var categoryId: UUID
        var isArchived: Bool

        init(id: UUID = UUID(), name: String, categoryId: UUID, isArchived: Bool = false, at date: Date) {
            self.id = id
            self.createdAt = date
            self.updatedAt = date
            self.name = name
            self.categoryId = categoryId
            self.isArchived = isArchived
        }
    }

    @Model
    final class DailyPlanRecord {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date
        var dayKey: String
        var timeZoneId: String
        /// draft / confirmed / skipped（PlanStatus）
        var statusRaw: String
        var confirmedAt: Date?
        /// 確定時の [PlanSnapshotBlock] の JSON（PLN-03）。以後変更しない
        var snapshotJSON: Data?
        /// 手で決めた今日の目標（GHO-10）。nil なら計画の集中の合計
        var goalFocusSec: Int? = nil
        /// 目標を手で変えたか
        var goalEdited: Bool = false

        init(id: UUID = UUID(), dayKey: String, timeZoneId: String, statusRaw: String, at date: Date) {
            self.id = id
            self.createdAt = date
            self.updatedAt = date
            self.dayKey = dayKey
            self.timeZoneId = timeZoneId
            self.statusRaw = statusRaw
        }
    }

    @Model
    final class PlanBlockRecord {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date
        var planId: UUID
        var startAt: Date
        var endAt: Date
        var categoryId: UUID
        var projectId: UUID?
        /// 日中の変更で消したブロック（予実分析用に残す）。PersistentModel.isDeleted と名前が衝突するため isRemoved
        var isRemoved: Bool

        init(id: UUID, planId: UUID, startAt: Date, endAt: Date, categoryId: UUID, projectId: UUID?, at date: Date) {
            self.id = id
            self.createdAt = date
            self.updatedAt = date
            self.planId = planId
            self.startAt = startAt
            self.endAt = endAt
            self.categoryId = categoryId
            self.projectId = projectId
            self.isRemoved = false
        }
    }

    @Model
    final class FocusSessionRecord {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date
        var dayKey: String
        var timeZoneId: String
        var planBlockId: UUID?
        var categoryId: UUID
        /// 開始したときにカテゴリが「集中に数える」だったか。後からカテゴリの設定を変えても過去の記録は変わらない（2026-09-30 決定）
        var countsAsFocus: Bool
        var projectId: UUID?
        var startAt: Date
        /// nil なら実行中
        var endAt: Date?
        /// 計画ブロックから開始したときの終了予定（一時停止しても動かない）
        var plannedEndAt: Date?
        /// 計画外で長さを決めたときの長さ（一時停止した分だけ終わりがずれる）
        var plannedDurationSec: Int?
        /// [PauseInterval] の JSON（TMR-03）
        var pausesJSON: Data
        /// 終了時刻を早めたときの元の終了時刻（TMR-08）
        var originalEndAt: Date?
        var note: String?

        init(id: UUID = UUID(), dayKey: String, timeZoneId: String, planBlockId: UUID?, categoryId: UUID, countsAsFocus: Bool,
             projectId: UUID?, startAt: Date, plannedEndAt: Date?, plannedDurationSec: Int?, at date: Date) {
            self.id = id
            self.createdAt = date
            self.updatedAt = date
            self.dayKey = dayKey
            self.timeZoneId = timeZoneId
            self.planBlockId = planBlockId
            self.categoryId = categoryId
            self.countsAsFocus = countsAsFocus
            self.projectId = projectId
            self.startAt = startAt
            self.plannedEndAt = plannedEndAt
            self.plannedDurationSec = plannedDurationSec
            self.pausesJSON = Data("[]".utf8)
        }
    }

    /// 計画のテンプレート（PLN-07）。最大7つ。時刻は「時:分」だけ持つ
    @Model
    final class PlanTemplateRecord {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date
        var name: String
        var sortOrder: Int
        /// [TemplateBlockValue] の JSON
        var blocksJSON: Data

        init(id: UUID = UUID(), name: String, sortOrder: Int, blocksJSON: Data, at date: Date) {
            self.id = id
            self.createdAt = date
            self.updatedAt = date
            self.name = name
            self.sortOrder = sortOrder
            self.blocksJSON = blocksJSON
        }
    }

    /// 睡眠の記録（DTX-02、第3版・第4版）。その日の朝に終わった睡眠。1日に1つ
    @Model
    final class SleepRecord {
        var id: UUID
        var createdAt: Date
        var updatedAt: Date
        var dayKey: String
        var timeZoneId: String
        var startAt: Date
        var endAt: Date
        /// health（ヘルスケア）／setting（設定の時刻）／manual（手で直した）
        var sourceRaw: String
        /// 手で直す前の時刻（第4版、DTX-02・03）。最初に手で直したときの直前の値。手で直していなければ nil
        var originalStartAt: Date? = nil
        var originalEndAt: Date? = nil

        init(id: UUID = UUID(), dayKey: String, timeZoneId: String, startAt: Date, endAt: Date, sourceRaw: String, at date: Date) {
            self.id = id
            self.createdAt = date
            self.updatedAt = date
            self.dayKey = dayKey
            self.timeZoneId = timeZoneId
            self.startAt = startAt
            self.endAt = endAt
            self.sourceRaw = sourceRaw
        }
    }
}

typealias CategoryRecord = SchemaV4.CategoryRecord
typealias ProjectRecord = SchemaV4.ProjectRecord
typealias DailyPlanRecord = SchemaV4.DailyPlanRecord
typealias PlanBlockRecord = SchemaV4.PlanBlockRecord
typealias FocusSessionRecord = SchemaV4.FocusSessionRecord
typealias PlanTemplateRecord = SchemaV4.PlanTemplateRecord
typealias SleepRecord = SchemaV4.SleepRecord

enum AppMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SchemaV1.self, SchemaV2.self, SchemaV3.self, SchemaV4.self] }
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: SchemaV1.self, toVersion: SchemaV2.self),
         .lightweight(fromVersion: SchemaV2.self, toVersion: SchemaV3.self),
         .lightweight(fromVersion: SchemaV3.self, toVersion: SchemaV4.self)]
    }
}

enum AppStore {
    /// 保存先を開く。`url` が nil ならメモリ内。
    static func makeContainer(url: URL?) throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV4.self)
        let configuration = if let url {
            ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        } else {
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        }
        return try ModelContainer(for: schema, migrationPlan: AppMigrationPlan.self, configurations: configuration)
    }

    /// 通常の保存先（Application Support/default.store）。
    static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "default.store")
    }
}
