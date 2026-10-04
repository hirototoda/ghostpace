import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings

/// シールドをかける・外す共通の処理。本体と、自動で戻す拡張（BlockMonitor）で同じ名前の置き場を使う。
enum ShieldControl {
    /// 同じ名前の置き場はプロセスをまたいで同じ設定を指すので、使うたびに作る
    static var store: ManagedSettingsStore { ManagedSettingsStore(named: ManagedSettingsStore.Name("always")) }
    /// 集中中の全部ブロック（BLK-04）。いつものブロックとは別の置き場にして、重ねてかける
    static var focusStore: ManagedSettingsStore { ManagedSettingsStore(named: ManagedSettingsStore.Name("focus")) }
    static var unlockActivity: DeviceActivityName { DeviceActivityName("unlock") }
    /// ゲーム・SNS の時間を切り替えるスケジュール（1日3つまで。並べたものはつなげるので3つで足りる）
    static var unblockActivities: [DeviceActivityName] {
        (0..<PlanLimits.unblockPerDay).map { DeviceActivityName("unblock-\($0)") }
    }

    static func isUnblockActivity(_ activity: DeviceActivityName) -> Bool {
        unblockActivities.contains(activity)
    }

    static func decode(_ data: Data) -> FamilyActivitySelection? {
        try? JSONDecoder().decode(FamilyActivitySelection.self, from: data)
    }

    static func apply(_ selection: FamilyActivitySelection) {
        let store = self.store
        store.shield.applications = selection.applicationTokens.isEmpty ? nil : selection.applicationTokens
        store.shield.applicationCategories = selection.categoryTokens.isEmpty ? nil : .specific(selection.categoryTokens)
        store.shield.webDomains = selection.webDomainTokens.isEmpty ? nil : selection.webDomainTokens
        store.shield.webDomainCategories = selection.categoryTokens.isEmpty ? nil : .specific(selection.categoryTokens)
    }

    /// 集中中も使うアプリ以外の全部をブロックする。Web サイトは個別には止めない（app-blocking.md）
    static func applyFocus(allow: FamilyActivitySelection?) {
        focusStore.shield.applicationCategories = .all(except: allow?.applicationTokens ?? [])
    }

    static func clearUsual() {
        let store = self.store
        store.shield.applications = nil
        store.shield.applicationCategories = nil
        store.shield.webDomains = nil
        store.shield.webDomainCategories = nil
        store.clearAllSettings()
    }

    /// ゲーム・SNS の時間の始まり・終わりの合図（BlockMonitor）：決定表で計算し直してかける・外す。外した・戻したを記録する。
    /// 合図が少し早く届いても切り替えられるよう、`tolerance` 秒あとの時刻で計算する
    static func applyForUnblockSignal(store: any BlockStoring, log: any BlockEventLogging, now: Date,
                                      tolerance: TimeInterval, timeZone: TimeZone) {
        let at = now.addingTimeInterval(tolerance)
        UnblockLog.note(store: store, log: log, authorized: true, now: at, timeZone: timeZone)
        // 余裕はゲーム・SNS の時間の端のためだけ。開けた時間は今の時刻で見る（早く戻さない）
        let plan = BlockPolicy.isUnlocked(store.state, now: now) ? .none
            : BlockPolicy.shields(store.state, hasSelection: store.selection != nil, authorized: true, now: at)
        BlockDebugTrace.add("monitor: unblock plan usual=\(plan.usual) focus=\(plan.focus)", now: now)
        if plan.usual, let selection = store.selection.flatMap(decode) { apply(selection) } else { clearUsual() }
        if plan.focus { applyFocus(allow: store.focusAllowSelection.flatMap(decode)) } else { clearFocus() }
    }

    static func clearFocus() {
        let store = focusStore
        store.shield.applicationCategories = nil
        store.clearAllSettings()
    }

    /// 期限が過ぎていて、まだ開けていればブロックに戻す（自動で戻す拡張から呼ぶ）。戻したら true
    @discardableResult
    static func reblockIfExpired(store: any BlockStoring, log: any BlockEventLogging, now: Date,
                                 tolerance: TimeInterval = 0, timeZone: TimeZone) -> Bool {
        BlockDebugTrace.add("monitor: until=\(String(describing: store.state.unlockedUntil))", now: now)
        return BlockReblock.run(store: store, log: log, now: now, tolerance: tolerance, timeZone: timeZone, reason: .expired,
                                focusShield: { applyFocus(allow: $0.flatMap(decode)) }) {
            guard let selection = decode($0) else { return false }
            apply(selection)
            return true
        }
    }
}
