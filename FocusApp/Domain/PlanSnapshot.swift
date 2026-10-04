import Foundation

/// 1日の計画の状態。
enum PlanStatus: Hashable {
    case draft
    case confirmed
    case skipped
    /// 知らない値（将来の版で書かれたもの）。確定済みとして表示し、書き換えない
    case unknown

    init(raw: String) {
        self = switch raw {
        case "draft": .draft
        case "confirmed": .confirmed
        case "skipped": .skipped
        default: .unknown
        }
    }

    /// 保存する値。unknown は保存しない（元の値を残す）
    var raw: String? {
        switch self {
        case .draft: "draft"
        case .confirmed: "confirmed"
        case .skipped: "skipped"
        case .unknown: nil
        }
    }
}

/// 保存されている1日の計画。ブロックは削除の印がないものだけ。
struct StoredPlan: Hashable {
    var status: PlanStatus
    var draft: PlanDraft
}

/// 確定時の計画ブロックの写し（PLN-03）。名前も残すので、後でカテゴリ名を変えても朝の計画が読める。
struct PlanSnapshotBlock: Codable, Hashable {
    var blockId: UUID
    var startAt: Date
    var endAt: Date
    var categoryId: UUID
    var categoryName: String
    var projectId: UUID?
    var projectName: String?

    init(blockId: UUID, startAt: Date, endAt: Date, categoryId: UUID, categoryName: String, projectId: UUID?, projectName: String?) {
        self.blockId = blockId
        self.startAt = startAt
        self.endAt = endAt
        self.categoryId = categoryId
        self.categoryName = categoryName
        self.projectId = projectId
        self.projectName = projectName
    }

    init(_ block: PlanBlockDraft) {
        self.init(blockId: block.id, startAt: block.start, endAt: block.end, categoryId: block.category.id,
                  categoryName: block.category.name, projectId: block.project?.id, projectName: block.project?.name)
    }

    static func encode(_ blocks: [PlanSnapshotBlock]) -> Data {
        (try? JSONEncoder().encode(blocks)) ?? Data("[]".utf8)
    }

    /// 読めなければ nil（計画そのものは読める）。
    static func decode(_ data: Data) -> [PlanSnapshotBlock]? {
        try? JSONDecoder().decode([PlanSnapshotBlock].self, from: data)
    }
}
