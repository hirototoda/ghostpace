import Foundation

/// 夜の振り返りで出す「朝の計画と実際のズレ」（REV-01、docs/product/features/review.md）。
/// 朝の計画（スナップショット、PLN-03）のブロックごとに、そのブロックから始めた記録の時間と比べる。
struct ReviewGap: Identifiable, Hashable {
    var block: PlanSnapshotBlock
    var plannedSeconds: Int
    var actualSeconds: Int
    var id: UUID { block.blockId }
    var title: String { block.projectName ?? block.categoryName }
    /// 実際 − 予定。マイナスなら足りなかった
    var diffSeconds: Int { actualSeconds - plannedSeconds }
}

enum ReviewGaps {
    /// 出すのは最大2つ
    static let maxCount = 2
    /// これより小さいズレは出さない（Q19、2026-10-01 決定）
    static let minimumSeconds = 15 * 60

    /// ズレの大きい順に最大2つ。終わりの時刻を過ぎたブロックだけ（まだ来ていないブロックはズレに数えない）。
    static func largest(snapshot: [PlanSnapshotBlock], sessions: [FocusSession], now: Date) -> [ReviewGap] {
        snapshot
            // ゲーム・SNS の時間（BLK-10）はタイマーを始めないのでズレに数えない
            .filter { $0.endAt <= now && !CategoryOption.isUnblock(id: $0.categoryId) }
            .map { block in
                ReviewGap(block: block, plannedSeconds: Int(block.endAt.timeIntervalSince(block.startAt)),
                          actualSeconds: sessions.filter { $0.planBlockId == block.blockId }
                              .reduce(0) { $0 + $1.activeSeconds(at: now) })
            }
            .filter { abs($0.diffSeconds) >= minimumSeconds }
            .sorted { abs($0.diffSeconds) != abs($1.diffSeconds) ? abs($0.diffSeconds) > abs($1.diffSeconds) : $0.block.startAt < $1.block.startAt }
            .prefix(maxCount)
            .map { $0 }
    }
}
