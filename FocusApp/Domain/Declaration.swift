import Foundation

/// 押し忘れの申告（TMR-13、docs/product/features/focus-timer.md「押し忘れの申告」）。申告できるかを決める。
enum Declaration {
    enum Problem: Hashable {
        case gameTime
        case notInMorningPlan
        case hasRecord
        case notEnded
        case invalidEnd
        case overlapsRecord
        case opened

        var message: String {
            switch self {
            case .gameTime: "ゲーム・SNS の時間は申告できません"
            case .notInMorningPlan: "朝の計画にないブロックは申告できません"
            case .hasRecord: "このブロックにはもう記録があります"
            case .notEnded: "終わったブロックだけ申告できます"
            case .invalidEnd: "終わりは計画の時刻までにしてください"
            case .overlapsRecord: "ほかの記録と重なっています"
            case .opened: "この時間に開けていたので申告できません"
            }
        }
    }

    /// ブロックの最中に始めるとき「開始から始めていた」を聞くのは、開始からこれ以上たったときだけ
    static let lateStartMinimum: TimeInterval = 5 * 60

    /// 終わったブロックを `end` まで申告できないときの理由。できるなら nil。
    /// - morningBlockIds: 朝に確定した計画の写し（PLN-03）のブロック
    /// - opened: 長押しで開けていた時間（DTX-05）
    static func problem(block: PlanBlockDraft, end: Date, morningBlockIds: Set<UUID>, sessions: [FocusSession],
                        opened: [DateInterval], now: Date) -> Problem? {
        if block.isUnblock { return .gameTime }
        if !morningBlockIds.contains(block.id) { return .notInMorningPlan }
        if sessions.contains(where: { $0.planBlockId == block.id }) { return .hasRecord }
        if block.end > now { return .notEnded }
        if end <= block.start || end > block.end { return .invalidEnd }
        return clash(from: block.start, to: end, sessions: sessions, opened: opened)
    }

    /// ブロックの最中に始めるとき、申告にできる開始（ブロックの開始）。聞かないときは nil
    static func lateStart(block: PlanBlockDraft, morningBlockIds: Set<UUID>, sessions: [FocusSession],
                          opened: [DateInterval], now: Date) -> Date? {
        guard !block.isUnblock, morningBlockIds.contains(block.id),
              now.timeIntervalSince(block.start) >= lateStartMinimum, now < block.end,
              !sessions.contains(where: { $0.planBlockId == block.id }),
              clash(from: block.start, to: now, sessions: sessions, opened: opened) == nil else { return nil }
        return block.start
    }

    private static func clash(from start: Date, to end: Date, sessions: [FocusSession], opened: [DateInterval]) -> Problem? {
        if sessions.contains(where: { $0.startAt < end && start < ($0.endAt ?? .distantFuture) }) { return .overlapsRecord }
        if opened.contains(where: { $0.start < end && start < $0.end }) { return .opened }
        return nil
    }
}
