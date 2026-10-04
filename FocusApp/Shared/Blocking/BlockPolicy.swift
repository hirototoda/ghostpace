import Foundation

/// ブロックの決まり（docs/product/features/app-blocking.md、ADR-0013）。本体と拡張の両方で使う。
/// 現在時刻は引数で受け取る（本体は AppClock、拡張は SystemClock から渡す）。
enum BlockPolicy {
    /// 開くまでに押し続ける秒数（BLK-08。2026-10-01 に5秒から3秒へ）
    static let holdSeconds: Double = 3
    /// 押し終わってから開くまでに数える秒数（BLK-08。この間は「やめる」で取りやめられる）
    static let countdownSeconds = 5
    /// 開ける長さ（分）。5分〜1時間、5分刻み（BLK-07）
    static let unlockMinuteOptions = Array(stride(from: 5, through: 60, by: 5))
    /// 長押しの画面を開いたときの長さ。前回の長さは覚えない
    static let defaultUnlockMinutes = 15
    /// シールドの「開く」から、本体を開いたら長押しの画面を出す秒数
    static let holdRequestWindow: TimeInterval = 120
    /// DeviceActivitySchedule の最短の長さ（ios-constraints.md）
    static let minimumScheduleMinutes = 15

    /// 開けている期限。選べない長さなら nil
    static func unlockedUntil(now: Date, minutes: Int) -> Date? {
        guard unlockMinuteOptions.contains(minutes) else { return nil }
        return now.addingTimeInterval(Double(minutes) * 60)
    }

    /// 期限が過ぎている（期限ちょうどを含む）。開けていなければ false
    static func isExpired(_ state: BlockState, now: Date) -> Bool {
        state.unlockedUntil.map { now >= $0 } ?? false
    }

    static func isUnlocked(_ state: BlockState, now: Date) -> Bool {
        state.unlockedUntil.map { now < $0 } ?? false
    }

    /// 今ブロックしているはずか
    static func isBlocked(_ state: BlockState, now: Date) -> Bool {
        state.isEnabled && !isUnlocked(state, now: now)
    }

    /// 今かかるブロック（app-blocking.md「今かかるブロック」の決定表、BLK-12）。
    /// どの合図でもこれで計算し直す。前の状態との差分は考えない。
    /// `isFocusBlocking` は「集中のタイマーが動いていて一時停止していない」こと（拡張はタイマーを読めないので覚えておく）
    static func shields(_ state: BlockState, hasSelection: Bool, authorized: Bool, now: Date) -> ShieldPlan {
        guard state.isEnabled, hasSelection, authorized, !isUnlocked(state, now: now) else { return .none }
        if state.isFocusBlocking { return ShieldPlan(usual: true, focus: true) }
        return isInUnblockWindow(state, now: now) ? .none : ShieldPlan(usual: true, focus: false)
    }

    /// 今ゲーム・SNS の時間の中か（BLK-10。始まりちょうどを含み、終わりちょうどは含まない）
    static func isInUnblockWindow(_ state: BlockState, now: Date) -> Bool {
        state.unblockWindows.contains { $0.start <= now && now < $0.end }
    }

    /// 今のゲーム・SNS の時間の終わり（中でなければ nil）
    static func unblockWindowEnd(_ state: BlockState, now: Date) -> Date? {
        state.unblockWindows.first { $0.start <= now && now < $0.end }?.end
    }

    /// ゲーム・SNS の時間でいつものブロックを外しているか（決定表で「外」になる理由がゲーム・SNS の時間だけのとき）
    static func isUnblocking(_ state: BlockState, hasSelection: Bool, authorized: Bool, now: Date) -> Bool {
        state.isEnabled && hasSelection && authorized && !isUnlocked(state, now: now) && !state.isFocusBlocking
            && isInUnblockWindow(state, now: now)
    }

    /// 並べたゲーム・SNS の時間をつなげる（あいだでブロックしない）
    static func mergedWindows(_ windows: [UnblockWindow]) -> [UnblockWindow] {
        var merged: [UnblockWindow] = []
        for window in windows.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, window.start <= last.end {
                merged[merged.count - 1].end = max(last.end, window.end)
            } else {
                merged.append(window)
            }
        }
        return merged
    }

    /// ゲーム・SNS の時間を切り替えるスケジュール。始まり（過ぎていれば今の分）から、終わり＋15分まで。
    /// 終わりは「終わる前の合図」（15分前＝ゲーム・SNS の時間の終わり）で戻す（開けた時間と同じ。ios-constraints.md）。
    /// もう終わった時間は入れない
    static func unblockSchedules(_ windows: [UnblockWindow], now: Date) -> [ReblockSchedule] {
        windows.filter { $0.end > now }.map { window in
            ReblockSchedule(start: floorToMinute(max(window.start, now)),
                            end: ceilToMinute(window.end).addingTimeInterval(Double(minimumScheduleMinutes) * 60),
                            warningMinutes: minimumScheduleMinutes)
        }
    }

    /// シールドの「開く」から2分以内で、まだ開けていない
    static func wantsHoldScreen(_ state: BlockState, now: Date) -> Bool {
        guard let requested = state.unlockRequestedAt, !isUnlocked(state, now: now) else { return false }
        let elapsed = now.timeIntervalSince(requested)
        return elapsed >= 0 && elapsed <= holdRequestWindow
    }

    /// 自動で戻すスケジュール。分単位なので、期限を分に切り上げる（早く戻さない）。
    /// 実機で「スケジュールの終わり」の合図が届かず「終わる前の合図」は届いた（2026-10-01）ので、
    /// どの長さでも「戻す時刻＋15分」で終わるスケジュールにし、15分前の合図（＝戻す時刻）で戻す。終わりの合図は予備。
    static func reblockSchedule(now: Date, minutes: Int) -> ReblockSchedule? {
        guard let until = unlockedUntil(now: now, minutes: minutes) else { return nil }
        let fire = ceilToMinute(until)
        let warning = minimumScheduleMinutes
        return ReblockSchedule(start: floorToMinute(now), end: fire.addingTimeInterval(Double(warning) * 60),
                               warningMinutes: warning)
    }

    static func floorToMinute(_ date: Date) -> Date {
        let seconds = date.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (seconds / 60).rounded(.down) * 60)
    }

    static func ceilToMinute(_ date: Date) -> Date {
        let seconds = date.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (seconds / 60).rounded(.up) * 60)
    }
}

/// 期限切れのときにブロックに戻す手順（Screen Time に触れる部分は `shield` で受け取る。テストのため）。
enum BlockReblock {
    /// 期限（から `tolerance` 秒前）を過ぎていて、まだ開けていれば、期限を消してかけ直し「戻った」を記録する。
    /// すでに戻っていれば何もしない（前のスケジュールの合図・二重の呼び出しで二重に記録しない）。戻したら true。
    /// `shield` が false（選択を読めなかった）なら選択を消し、設定で選び直してもらう。
    /// 集中のタイマー中なら `focusShield` で全部ブロックもかけ直す（集中中も使うアプリを渡す）
    @discardableResult
    static func run(store: any BlockStoring, log: any BlockEventLogging, now: Date, tolerance: TimeInterval = 0,
                    timeZone: TimeZone, reason: BlockEvent.ReblockReason, focusShield: (Data?) -> Void = { _ in },
                    shield: (Data) -> Bool) -> Bool {
        var state = store.state
        guard BlockPolicy.isExpired(state, now: now.addingTimeInterval(tolerance)) else { return false }
        state.unlockedUntil = nil
        store.state = state
        // 拡張は許可を確かめられないので、許可ありとして決定表を引く（許可がなければ iPhone がかけない）
        let plan = BlockPolicy.shields(state, hasSelection: store.selection != nil, authorized: true, now: now)
        if plan.usual, let selection = store.selection {
            if shield(selection) {
                if plan.focus { focusShield(store.focusAllowSelection) }
            } else {
                store.selection = nil
                try? log.append(BlockEvent(occurredAt: now, timeZoneId: timeZone.identifier, kind: .selectionLost))
            }
        }
        try? log.append(BlockEvent(occurredAt: now, timeZoneId: timeZone.identifier, kind: .reblocked, reblockReason: reason))
        // ゲーム・SNS の時間の中で開けた時間が終わったら、そのまま外しておく（記録する）
        UnblockLog.note(store: store, log: log, authorized: true, now: now, timeZone: timeZone)
        return true
    }
}

/// ゲーム・SNS の時間で外した・戻したの記録（BLK-11）。本体と拡張の両方から呼ぶ。
enum UnblockLog {
    /// 決定表で「ゲーム・SNS の時間で外している」かが前と変わっていれば、state を直して記録する。記録したら true
    @discardableResult
    static func note(store: any BlockStoring, log: any BlockEventLogging, authorized: Bool, now: Date,
                     timeZone: TimeZone) -> Bool {
        var state = store.state
        let unblocking = BlockPolicy.isUnblocking(state, hasSelection: store.selection != nil, authorized: authorized, now: now)
        guard unblocking != state.isUnblocking else { return false }
        state.isUnblocking = unblocking
        store.state = state
        try? log.append(BlockEvent(occurredAt: now, timeZoneId: timeZone.identifier,
                                   kind: unblocking ? .unblockStarted : .unblockEnded))
        return true
    }
}

/// かけるブロック。いつものブロック（ゲームと SNS）と、集中中の全部ブロック。
struct ShieldPlan: Equatable, Sendable {
    var usual: Bool
    var focus: Bool

    static let none = ShieldPlan(usual: false, focus: false)
}

/// 開けたあとに戻すスケジュール（DeviceActivitySchedule に渡す値）。
struct ReblockSchedule: Equatable, Sendable {
    var start: Date
    var end: Date
    /// nil ならスケジュールの終わりで戻す。値があれば終わりのこの分前の合図で戻す
    var warningMinutes: Int?

    /// 実際に戻す時刻
    var fireAt: Date { end.addingTimeInterval(-Double(warningMinutes ?? 0) * 60) }
}

/// 本体と拡張で共有するブロックの状態（data-model.md「BlockState」）。
struct BlockState: Codable, Equatable, Sendable {
    /// いつものブロックを始めたか
    var isEnabled = false
    /// 開けている期限（UTC）。nil か過ぎていればブロック中
    var unlockedUntil: Date?
    /// シールドの「開く」を押した時刻
    var unlockRequestedAt: Date?
    /// 集中中の全部ブロックをかけたい状態か（BLK-04。集中のタイマーが動いていて一時停止していない）。
    /// 開けている間も true のまま覚えておき、戻すときに全部ブロックもかけ直す
    var isFocusBlocking = false
    /// 今日と明日のゲーム・SNS の時間（BLK-10、UTC。並べたものはつなげてある）。本体が確定した計画から書く。拡張はこれを正とする
    var unblockWindows: [UnblockWindow] = []
    /// ゲーム・SNS の時間でいつものブロックを外しているか（「外した／戻した」を二重に記録しないため）
    var isUnblocking = false

    init(isEnabled: Bool = false, unlockedUntil: Date? = nil, unlockRequestedAt: Date? = nil, isFocusBlocking: Bool = false,
         unblockWindows: [UnblockWindow] = [], isUnblocking: Bool = false) {
        self.isEnabled = isEnabled
        self.unlockedUntil = unlockedUntil
        self.unlockRequestedAt = unlockRequestedAt
        self.isFocusBlocking = isFocusBlocking
        self.unblockWindows = unblockWindows
        self.isUnblocking = isUnblocking
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, unlockedUntil, unlockRequestedAt, isFocusBlocking, unblockWindows, isUnblocking
    }

    /// 前の版で保存した状態（項目が足りない）も読めるように、ない項目は初期値にする
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        unlockedUntil = try container.decodeIfPresent(Date.self, forKey: .unlockedUntil)
        unlockRequestedAt = try container.decodeIfPresent(Date.self, forKey: .unlockRequestedAt)
        isFocusBlocking = try container.decodeIfPresent(Bool.self, forKey: .isFocusBlocking) ?? false
        unblockWindows = try container.decodeIfPresent([UnblockWindow].self, forKey: .unblockWindows) ?? []
        isUnblocking = try container.decodeIfPresent(Bool.self, forKey: .isUnblocking) ?? false
    }
}

/// ゲーム・SNS の時間の1つ（BLK-10）。
struct UnblockWindow: Codable, Equatable, Sendable {
    var start: Date
    var end: Date
}
