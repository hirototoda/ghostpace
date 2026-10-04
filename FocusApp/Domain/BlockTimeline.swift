import Foundation

/// ブロックの記録から作る、いつものブロックの状態の移り変わり（BLK-11）。
struct BlockTimeline {
    /// ブロックを始めていた区間（始めた〜選択が読めなくなった）
    private(set) var enabled: [DateInterval] = []
    /// 許可が外れていた区間（前に許可を確かめた時刻〜戻ったのに気づいた時刻）
    private(set) var unauthorized: [DateInterval] = []
    /// 長押しで開けていた区間（開けた〜戻った）
    private(set) var unlocked: [DateInterval] = []
    /// ゲーム・SNS の時間で実際に外していた区間（外した〜戻した）
    private(set) var unblocking: [DateInterval] = []

    /// 「外れた」からこれ以内に「戻った」組は、iPhone が一瞬「未確認」と返した誤記録とみなして数えない（過去の記録にも、2026-10-03）
    static let authorizationBlip: TimeInterval = 2 * 60

    init(events: [BlockEvent]) {
        let sorted = events.sorted { $0.occurredAt < $1.occurredAt }
        var enabledSince: Date?, lostSince: Date?, lostNoticedAt: Date?, unlockedSince: Date?, unblockSince: Date?
        func close(_ since: inout Date?, at end: Date, into list: inout [DateInterval]) {
            if let start = since, end > start { list.append(DateInterval(start: start, end: end)) }
            since = nil
        }
        for event in sorted {
            let at = event.occurredAt
            switch event.kind {
            case .started: if enabledSince == nil { enabledSince = at }
            case .selectionLost: close(&enabledSince, at: at, into: &enabled)
            case .authorizationLost:
                if lostSince == nil { lostSince = min(event.sinceAt ?? at, at); lostNoticedAt = at }
            case .authorizationRestored:
                if let noticed = lostNoticedAt, at.timeIntervalSince(noticed) <= Self.authorizationBlip {
                    lostSince = nil
                } else {
                    close(&lostSince, at: at, into: &unauthorized)
                }
                lostNoticedAt = nil
            case .unlocked: if unlockedSince == nil { unlockedSince = at }
            case .reblocked: close(&unlockedSince, at: at, into: &unlocked)
            case .unblockStarted: if unblockSince == nil { unblockSince = at }
            case .unblockEnded: close(&unblockSince, at: at, into: &unblocking)
            case .shieldShown, .unlockRequested, .holdCancelled: break
            }
        }
        // まだ閉じていないものは、ずっと続いているとみなす
        close(&enabledSince, at: .distantFuture, into: &enabled)
        close(&lostSince, at: .distantFuture, into: &unauthorized)
        close(&unlockedSince, at: .distantFuture, into: &unlocked)
        close(&unblockSince, at: .distantFuture, into: &unblocking)
    }

    var boundaries: [DateInterval] { enabled + unauthorized + unlocked + unblocking }

    func isEnabled(at date: Date) -> Bool { enabled.contains { $0.contains(date) } }

    /// デトックスに数えるか：始めていて、許可があり、開けていない。ゲーム・SNS の時間で外していても、予定の中なら数える
    func isCounted(at date: Date, plannedGame: [DateInterval]) -> Bool {
        guard isEnabled(at: date), !unauthorized.contains(where: { $0.contains(date) }),
              !unlocked.contains(where: { $0.contains(date) }) else { return false }
        if unblocking.contains(where: { $0.contains(date) }) { return plannedGame.contains { $0.contains(date) } }
        return true
    }

    /// 自分で開けていたか（DTX-05）：始めていて許可があり、長押しで開けていた、またはゲーム・SNS の時間を過ぎても開いていた。
    /// 始める前・選択が読めない・許可が外れていた間は入れない
    func isOpenedByUser(at date: Date, plannedGame: [DateInterval]) -> Bool {
        guard isEnabled(at: date), !unauthorized.contains(where: { $0.contains(date) }) else { return false }
        if unlocked.contains(where: { $0.contains(date) }) { return true }
        return unblocking.contains { $0.contains(date) } && !plannedGame.contains { $0.contains(date) }
    }
}
