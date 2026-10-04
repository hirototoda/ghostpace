import Foundation

/// 計画のテンプレート（PLN-07、docs/product/features/daily-plan.md）。時刻は「時:分」だけ持ち、読み込んだ日に当てはめる。
struct PlanTemplate: Identifiable, Hashable {
    struct Block: Hashable {
        var hour: Int
        var minute: Int
        var minutes: Int
        var category: CategoryOption
        var project: ProjectOption?
    }

    var id = UUID()
    var name: String
    var blocks: [Block]

    static let maxCount = 7

    /// 時刻順（朝4:00から）
    var sortedBlocks: [Block] {
        blocks.sorted { ($0.hour - DayBoundary.hour + 24) % 24 * 60 + $0.minute < ($1.hour - DayBoundary.hour + 24) % 24 * 60 + $1.minute }
    }

    var focusSeconds: Int { blocks.filter(\.category.countsAsFocus).reduce(0) { $0 + $1.minutes * 60 } }
    /// ゲーム・SNS の時間（BLK-10）は入れない
    var detoxSeconds: Int { blocks.filter(\.category.countsAsDetox).reduce(0) { $0 + $1.minutes * 60 } }

    /// `dayStart`（その日の4:00）の日に当てはめた計画。0:00〜3:59 は翌日の暦の日付になる（朝4:00区切り）。
    /// 今より前の時間帯のブロックも読み込む（2026-10-01 決定）。
    func draft(dayStart: Date, calendar: Calendar) -> PlanDraft {
        PlanDraft(blocks: blocks.map { block in
            let hourFromStart = (block.hour - DayBoundary.hour + 24) % 24
            let start = calendar.date(byAdding: .minute, value: hourFromStart * 60 + block.minute, to: dayStart) ?? dayStart
            return PlanBlockDraft(start: start, minutes: block.minutes, category: block.category, project: block.project)
        })
    }

    /// 今の計画から作る（「この計画をテンプレートとして保存」）。
    init(name: String, plan: PlanDraft, calendar: Calendar) {
        self.name = name
        blocks = plan.sortedBlocks.map { block in
            let parts = calendar.dateComponents([.hour, .minute], from: block.start)
            return Block(hour: parts.hour ?? 0, minute: parts.minute ?? 0, minutes: block.minutes,
                         category: block.category, project: block.project)
        }
    }

    init(id: UUID = UUID(), name: String, blocks: [Block]) {
        self.id = id
        self.name = name
        self.blocks = blocks
    }

    /// 初めから入れておく「理想の休日」。カテゴリが見つからないブロックは入れない。
    /// 2026-10-03 から瞑想は休みの、掃除は家事のブロック名（settings.md「カテゴリの組み替え」）
    static func idealHoliday(categories: [CategoryOption], projects: [ProjectOption] = []) -> PlanTemplate {
        let items: [(Int, Int, Int, String, String?)] = [
            (7, 0, 15, "休み", "瞑想"), (7, 30, 60, "運動", nil), (9, 0, 180, "勉強", nil), (13, 30, 30, "家事", "掃除"),
            (20, 0, 60, "読書", nil),
        ]
        return PlanTemplate(name: "理想の休日", blocks: items.compactMap { hour, minute, minutes, name, projectName in
            categories.first { $0.name == name }.map { category in
                Block(hour: hour, minute: minute, minutes: minutes, category: category,
                      project: projectName.flatMap { projectName in projects.first { $0.category == category && $0.name == projectName } })
            }
        })
    }
}
