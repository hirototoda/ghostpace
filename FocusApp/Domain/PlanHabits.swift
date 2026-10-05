import Foundation

/// 習慣（PLN-08、docs/product/features/daily-plan.md「習慣」）。毎日決まった時刻にすること。
/// ゲーム・SNS の時間（3つまで）とほかのブロック（3つまで）。時刻は「時:分」だけ持ち、新しく作る下書きに当てはめる。
struct PlanHabits: Hashable {
    /// ゲーム・SNS の時間を除いたブロックの数の上限（2026-10-04 オーナー決定）
    static let blockLimit = 3

    var blocks: [PlanTemplate.Block] = []

    init(blocks: [PlanTemplate.Block] = []) {
        self.blocks = blocks
    }

    /// 編集した計画（その日に当てはめた形）から作る
    init(plan: PlanDraft, calendar: Calendar) {
        blocks = PlanTemplate(name: "", plan: plan, calendar: calendar).blocks
    }

    /// `dayStart`（その日の4:00）の日に当てはめた下書き。0:00〜3:59 は暦の翌日
    func draft(dayStart: Date, calendar: Calendar) -> PlanDraft {
        PlanTemplate(name: "", blocks: blocks).draft(dayStart: dayStart, calendar: calendar)
    }

    /// 習慣の画面で保存できない理由。計画と同じ理由（重なり・4:00 またぎ・ゲーム・SNS は3つまで）に、ほかのブロックは3つまでを足す
    static func problem(with block: PlanBlockDraft, in draft: PlanDraft, dayStart: Date) -> String? {
        if !block.isUnblock, draft.blocks.filter({ !$0.isUnblock && $0.id != block.id }).count >= blockLimit {
            return "習慣のブロックは\(blockLimit)つまでです"
        }
        return draft.problem(with: block, dayStart: dayStart)
    }
}

extension PlanBlockDraft {
    /// 習慣のブロックと同じ中身・時刻か（テンプレートを読み込んでも残すブロック、2026-10-05 オーナー決定）
    func matches(_ other: PlanBlockDraft) -> Bool {
        category.id == other.category.id && project?.id == other.project?.id && start == other.start && minutes == other.minutes
    }
}

extension PlanDraft {
    /// 今の計画にある、習慣どおりのブロック
    func habitBlocks(_ habits: PlanDraft) -> [PlanBlockDraft] {
        blocks.filter { block in habits.blocks.contains(where: block.matches) }
    }

    /// 朝の計画でテンプレートを読み込む（PLN-07）。習慣どおりのブロックは残し、テンプレートのブロックのうち
    /// 残したブロックと重ならず、ゲーム・SNS の時間が1日3つに収まるものを入れる。目標はそのまま（呼ぶ側で決める）
    func loading(_ template: PlanDraft, keeping habits: PlanDraft) -> PlanDraft {
        var result = self
        result.blocks = habitBlocks(habits)
        for block in template.sortedBlocks {
            if result.blocks.contains(where: { $0.matches(block) || block.overlaps($0) }) { continue }
            if block.isUnblock, result.unblockCount >= Self.unblockLimit { continue }
            result.blocks.append(block)
        }
        return result
    }
}
