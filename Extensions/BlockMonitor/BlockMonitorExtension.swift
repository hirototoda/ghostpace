import DeviceActivity
import Foundation

/// 開けた時間が終わったらブロックに戻す（BLK-07）。15分以上はスケジュールの終わり、5分・10分は終わる前の合図で戻す。
/// 期限を過ぎていて、まだ開けているときだけ戻す（前のスケジュールの合図や二重の呼び出しでは何もしない）。
final class BlockMonitorExtension: DeviceActivityMonitor {
    /// 合図が数秒早く届いても戻せるように
    private let tolerance: TimeInterval = 30

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        BlockDebugTrace.add("monitor: intervalDidStart \(activity.rawValue)", now: SystemClock().now())
        if ShieldControl.isUnblockActivity(activity) { unblockSignal() }
    }

    override func intervalWillEndWarning(for activity: DeviceActivityName) {
        super.intervalWillEndWarning(for: activity)
        BlockDebugTrace.add("monitor: willEndWarning \(activity.rawValue)", now: SystemClock().now())
        if ShieldControl.isUnblockActivity(activity) { unblockSignal() } else { reblock(activity) }
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        BlockDebugTrace.add("monitor: intervalDidEnd \(activity.rawValue)", now: SystemClock().now())
        if ShieldControl.isUnblockActivity(activity) { unblockSignal() } else { reblock(activity) }
    }

    /// ゲーム・SNS の時間の始まり・終わり（BLK-10）。決定表で計算し直す
    private func unblockSignal() {
        guard let defaults = BlockShared.defaults, let url = BlockShared.eventLogURL else { return }
        ShieldControl.applyForUnblockSignal(store: UserDefaultsBlockStore(defaults: defaults), log: FileBlockEventLog(url: url),
                                            now: SystemClock().now(), tolerance: tolerance, timeZone: .current)
    }

    private func reblock(_ activity: DeviceActivityName) {
        guard activity == ShieldControl.unlockActivity, let defaults = BlockShared.defaults,
              let url = BlockShared.eventLogURL else { return }
        ShieldControl.reblockIfExpired(store: UserDefaultsBlockStore(defaults: defaults), log: FileBlockEventLog(url: url),
                                       now: SystemClock().now(), tolerance: tolerance, timeZone: .current)
    }
}
