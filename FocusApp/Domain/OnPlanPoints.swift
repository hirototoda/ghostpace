import Foundation

/// 計画どおりの点（GHO-16、docs/product/features/ghost-race.md「計画どおりの点」）と、遅れて始めたときの終わり（TMR-15）
enum OnPlanPoints {
    /// 開始の前後これ以内に始める
    static let window: TimeInterval = 3600
    static let ratio = 0.8
    static let minimumMinutes = 30
    static let dailyLimit = 3

    struct Award: Hashable {
        var blockId: UUID
        /// 計画の長さの80%に届いた時刻
        var date: Date
    }

    /// 自分の点が付いた時刻（`now` まで、早い順に1日3つまで）。
    /// - morningBlockIds: 朝の計画の写しのブロック（いつも対象）
    /// - addedAt: ブロックを計画に足した時刻（朝の計画にないブロックは、始める1時間以上前に足したものだけ対象）
    static func awards(blocks: [PlanBlockDraft], sessions: [FocusSession], morningBlockIds: Set<UUID>,
                       addedAt: [UUID: Date], now: Date) -> [Award] {
        let found = blocks.compactMap { block -> Award? in
            guard isTarget(block) else { return nil }
            let mine = sessions.filter { $0.planBlockId == block.id && !$0.isDeclared }.sorted { $0.startAt < $1.startAt }
            guard let first = mine.first, abs(first.startAt.timeIntervalSince(block.start)) <= window else { return nil }
            if !morningBlockIds.contains(block.id) {
                guard let added = addedAt[block.id], added <= first.startAt.addingTimeInterval(-window) else { return nil }
            }
            let length = Double(first.plannedDurationSec ?? block.minutes * 60)
            return reach(length * ratio, segments: mine.flatMap { $0.activeSegments(now: now) }, now: now)
                .map { Award(blockId: block.id, date: $0) }
        }
        return Array(found.sorted { $0.date < $1.date }.prefix(dailyLimit))
    }

    /// 目標のゴーストの点の時刻：対象のブロック（30分以上、早い順に3つ）の開始＋長さの80%
    static func goalAwards(blocks: [PlanBlockDraft]) -> [Date] {
        Array(blocks.filter(isTarget).sorted { $0.start < $1.start }.prefix(dailyLimit)
            .map { $0.start.addingTimeInterval(Double($0.minutes * 60) * ratio) })
    }

    /// 計画ブロックを `start` に始めたときのタイマーの終わり。遅れて始めたら長さぶんずらす（それ以外はブロックの終わり）
    static func plannedEnd(blockStart: Date, blockEnd: Date, startingAt start: Date) -> Date {
        start > blockStart ? start.addingTimeInterval(max(60, blockEnd.timeIntervalSince(blockStart))) : blockEnd
    }

    static func isTarget(_ block: PlanBlockDraft) -> Bool {
        !block.isUnblock && block.minutes >= minimumMinutes
    }

    /// 区間を順に足して `target` 秒に届いた時刻
    private static func reach(_ target: Double, segments: [TimeSegment], now: Date) -> Date? {
        var total = 0.0
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            let end = min(segment.end, now)
            guard end > segment.start else { continue }
            let length = end.timeIntervalSince(segment.start)
            if total + length >= target { return segment.start.addingTimeInterval(target - total) }
            total += length
        }
        return nil
    }
}
