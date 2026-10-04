import ActivityKit
import Foundation

/// iPhone のロック画面と画面上部にタイマーを出す（ActivityKit、focus-timer.md TMR-06）。
/// 実行中のセッションと同じものが出ていれば中身だけ変え、違うもの（前のセッション・終わったもの）は消す。
@MainActor
final class ActivityKitLiveActivity: LiveActivityControlling {
    private let clock: any AppClock
    private let system: any AppClock
    /// 出し入れを順番に行う（すぐに一時停止したときなどに、出す前に2つ目を出さないように）
    private var pending: Task<Void, Never>?

    /// `clock` がアプリの時計、`system` が iPhone の時計。見本の時計（-fixedNow）のときだけ差が出る
    init(clock: any AppClock, system: any AppClock = SystemClock()) {
        self.clock = clock
        self.system = system
    }

    func show(_ wanted: TimerActivity?) {
        #if DEBUG
        // 見本の時計（-fixedNow と -liveActivity をシミュレーターで使うとき）：ロック画面の数字は iPhone の時計で数えるので、
        // アプリの時計との差だけ時刻をずらす。ふだんは差がない（2秒未満は読み取りの間のずれとして無視する）
        let shift = system.now().timeIntervalSince(clock.now()).rounded()
        let wanted = wanted.map { TimerActivity(attributes: $0.attributes, state: $0.state.shifted(by: abs(shift) < 2 ? 0 : shift)) }
        #endif
        let previous = pending
        pending = Task { @MainActor in
            await previous?.value
            await Self.apply(wanted)
        }
    }

    private static func apply(_ wanted: TimerActivity?) async {
        var current: Activity<TimerActivityAttributes>?
        for activity in Activity<TimerActivityAttributes>.activities {
            let isWanted = activity.attributes.sessionId == wanted?.attributes.sessionId
            if isWanted, current == nil, activity.activityState == .active || activity.activityState == .stale {
                current = activity
            } else {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }

        guard let wanted else { return }
        if let current {
            if current.content.state != wanted.state {
                await current.update(ActivityContent(state: wanted.state, staleDate: nil))
            }
        } else if ActivityAuthorizationInfo().areActivitiesEnabled {
            // 断られても（iPhone の設定でオフなど）タイマーには影響させない
            _ = try? Activity.request(attributes: wanted.attributes, content: ActivityContent(state: wanted.state, staleDate: nil))
        }
    }
}
