import Foundation

/// タイムラインに出す1日分（docs/product/features/timeline.md）。
struct TimelineDay {
    var dayKey: String
    var dayStart: Date
    var now: Date
    /// 今日（朝4:00区切り）の画面か
    var isToday: Bool
    /// 変更後の今の計画（消したブロックは入らない）
    var planBlocks: [PlanBlockSummary]
    var isNoPlanDay: Bool
    var sessions: [FocusSession]
    /// 終了時刻を早められる日（今日と昨日、TML-04）
    var editableDayKeys: Set<String>
    /// その日に開けた時間と回数（TML-05。ホームと同じ DTX-05 の数え方）。ブロックが一度も効いていない日は nil
    var opened: OpenedTime? = nil

    private var segments: [TimeSegment] { sessions.flatMap { $0.activeSegments(now: now) } }
    var focusSeconds: Int { segments.focusSeconds(until: now) }
    var detoxSeconds: Int { segments.detoxSeconds(until: now) }

    /// 終了時刻を早められるか。終わっていて、今日か昨日の記録で、開始から2分以上（選べる時刻がある）
    func canEdit(_ session: FocusSession) -> Bool {
        Self.canEdit(session, editableDayKeys: editableDayKeys)
    }

    static func canEdit(_ session: FocusSession, editableDayKeys: Set<String>) -> Bool {
        guard let end = session.endAt else { return false }
        return editableDayKeys.contains(session.dayKey) && end.timeIntervalSince(session.startAt) >= 120
    }

    /// 計画ブロックから始めた記録
    func sessions(of block: PlanBlockSummary) -> [FocusSession] {
        sessions.filter { $0.planBlockId == block.id }
    }

    /// そのブロックから始めた記録すべての、一時停止を除いた時間（実行中は今まで）
    func actualSeconds(of block: PlanBlockSummary) -> Int {
        sessions(of: block).reduce(0) { $0 + $1.activeSeconds(at: now) }
    }

    /// 達成率（%）＝実際の時間 ÷ 今のブロックの長さ。まだ始まっていないブロックで記録がなければ nil（「—」）
    func achievementPercent(of block: PlanBlockSummary) -> Int? {
        // ゲーム・SNS の時間（BLK-10）はタイマーを始めないので達成率を出さない
        if block.category.isUnblock { return nil }
        let actual = actualSeconds(of: block)
        if actual == 0 && block.start > now { return nil }
        let planned = max(Int(block.end.timeIntervalSince(block.start)), 1)
        return actual * 100 / planned
    }

    /// 計画外の記録（計画ブロックから始めていないもの、消したブロックから始めたもの）
    var unplannedSessions: [FocusSession] {
        let ids = Set(planBlocks.map(\.id))
        return sessions.filter { $0.planBlockId.map { !ids.contains($0) } ?? true }
    }
}
