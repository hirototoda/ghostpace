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
    var sortedBlocks: [Block] { sortedBlocks(fromMinutes: DayBoundary.morningHour * 60) }

    /// 時刻順（`fromMinutes`（0:00 からの分。一日の始まりの時刻）から）
    func sortedBlocks(fromMinutes origin: Int) -> [Block] {
        func key(_ block: Block) -> Int { ((block.hour * 60 + block.minute - origin) % 1440 + 1440) % 1440 }
        return blocks.sorted { key($0) < key($1) }
    }

    var focusSeconds: Int { blocks.filter(\.category.countsAsFocus).reduce(0) { $0 + $1.minutes * 60 } }
    /// ゲーム・SNS の時間（BLK-10）は入れない
    var detoxSeconds: Int { blocks.filter(\.category.countsAsDetox).reduce(0) { $0 + $1.minutes * 60 } }

    /// その日（`dayStart`〜`dayEnd`）に当てはめた計画。時:分は、日の名前の日に当てはめた時刻がその日の中にあればそれ、
    /// なければ前の日・次の日の同じ時刻のうちその日の中にあるもの（区切りが夜なら区切り以降は前の夜、
    /// 区切りが夜中なら区切りより前は翌日の夜中。2026-10-21、Claude 補足、Q47）。
    /// その日の区切りをまたぐブロック（区切りの設定を変えてまたぐようになったもの）は入れない。
    /// 今より前の時間帯のブロックも読み込む（2026-10-01 決定）。
    /// 暦の日付に時:分を当てはめるので、夏時間の切り替えの日も同じ時刻になる
    /// - dayEnd: nil なら24時間後。dayDate: 日の名前の日の 0:00（nil なら dayStart の暦の日）
    func draft(dayStart: Date, dayEnd: Date? = nil, dayDate: Date? = nil, calendar: Calendar) -> PlanDraft {
        let dayEnd = dayEnd ?? calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86400)
        let dayDate = dayDate ?? calendar.startOfDay(for: dayStart)
        return PlanDraft(blocks: blocks.compactMap { block in
            let starts = [0, -1, 1].compactMap { offset -> Date? in
                guard let day = calendar.date(byAdding: .day, value: offset, to: dayDate) else { return nil }
                return calendar.date(bySettingHour: block.hour, minute: block.minute, second: 0, of: day)
            }
            guard let start = starts.first(where: { $0 >= dayStart && $0 < dayEnd }),
                  start.addingTimeInterval(Double(block.minutes * 60)) <= dayEnd else { return nil }
            return PlanBlockDraft(start: start, minutes: block.minutes, category: block.category, project: block.project)
        })
    }

    /// その日に当てはめた計画
    func draft(day: BoundaryDay, calendar: Calendar) -> PlanDraft {
        draft(dayStart: day.start, dayEnd: day.end, dayDate: day.date, calendar: calendar)
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
