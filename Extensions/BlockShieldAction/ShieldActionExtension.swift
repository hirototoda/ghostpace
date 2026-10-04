import ManagedSettings
import UserNotifications

/// シールドのボタン（BLK-08）。「閉じる」はホーム画面へ。「開く」は時刻を残し、GhostPace の長押しの画面へ移る通知を出す。
/// シールドから GhostPace を直接開くことはできない（ios-constraints.md）。
final class ShieldActionExtension: ShieldActionDelegate {
    override func handle(action: ShieldAction, for application: ApplicationToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        respond(to: action, completion: Completion(handler: completionHandler))
    }

    override func handle(action: ShieldAction, for webDomain: WebDomainToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        respond(to: action, completion: Completion(handler: completionHandler))
    }

    override func handle(action: ShieldAction, for category: ActivityCategoryToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        respond(to: action, completion: Completion(handler: completionHandler))
    }

    /// 返事をすると拡張はすぐ終わるので、「開く」は通知の登録が終わってから返事をする
    private func respond(to action: ShieldAction, completion: Completion) {
        guard action == .secondaryButtonPressed else {
            completion.handler(.close)
            return
        }
        requestUnlock { completion.handler(.close) }
    }

    private func requestUnlock(then done: @escaping @Sendable () -> Void) {
        let now = SystemClock().now()
        if let defaults = BlockShared.defaults {
            let store = UserDefaultsBlockStore(defaults: defaults)
            var state = store.state
            state.unlockRequestedAt = now
            store.state = state
        }
        if let url = BlockShared.eventLogURL {
            try? FileBlockEventLog(url: url).append(
                BlockEvent(occurredAt: now, timeZoneId: TimeZone.current.identifier, kind: .unlockRequested))
        }
        let content = UNMutableNotificationContent()
        content.title = "GhostPace で3秒長押しして開く"
        content.body = "押すと長押しの画面が開きます"
        content.userInfo = ["kind": BlockShared.holdNotificationKind]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: BlockShared.holdNotificationKind, content: content, trigger: nil)) { _ in
            done()
        }
    }
}

/// システムから渡される返事の関数。1回だけ呼べばよく、どのスレッドから呼んでもよい（ShieldActionDelegate の約束）。
/// 通知の登録が終わったとき（別のスレッド）に呼ぶために包む。
private struct Completion: @unchecked Sendable {
    let handler: (ShieldActionResponse) -> Void
}
