import Foundation

/// タイムラインに出す1日分（docs/product/features/timeline.md）。
struct TimelineDay {
    var dayKey: String
    var dayStart: Date
    var now: Date
    /// 今日（その日の区切りで分けた日）の画面か
    var isToday: Bool
    /// 変更後の今の計画（消したブロックは入らない）
    var planBlocks: [PlanBlockSummary]
    var isNoPlanDay: Bool
    var sessions: [FocusSession]
    /// 記録を直せる日（今日と昨日、TML-04・TML-06）
    var editableDayKeys: Set<String>
    /// その日に開けた時間と回数（TML-05。ホームと同じ DTX-05 の数え方）。ブロックが一度も効いていない日は nil
    var opened: OpenedTime? = nil
    /// 日の名前の日の 0:00（見出しの日付）。nil ならその日の始まりの日
    var dayDate: Date? = nil

    /// 見出しの日付
    var displayDate: Date { dayDate ?? dayStart }

    private var segments: [TimeSegment] { sessions.flatMap { $0.activeSegments(now: now) } }
    var focusSeconds: Int { segments.focusSeconds(until: now) }
    var detoxSeconds: Int { segments.detoxSeconds(until: now) }

    /// 直せるか。終わっていて、今日か昨日の記録。タイマーの記録は終了時刻を早めるだけなので開始から2分以上（選べる時刻がある）。
    /// 手動の記録（TMR-13）は開始・終わりを変える・消すができるので、長さを問わない
    func canEdit(_ session: FocusSession) -> Bool {
        Self.canEdit(session, editableDayKeys: editableDayKeys)
    }

    static func canEdit(_ session: FocusSession, editableDayKeys: Set<String>) -> Bool {
        guard let end = session.endAt, editableDayKeys.contains(session.dayKey) else { return false }
        return session.isDeclared || end.timeIntervalSince(session.startAt) >= 120
    }

    /// 今日・昨日の画面に「＋ 手動で記録」を出すか（TML-06）
    var canAddManual: Bool { editableDayKeys.contains(dayKey) }

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
