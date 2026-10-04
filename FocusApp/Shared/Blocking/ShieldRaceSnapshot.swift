import Foundation

/// シールドに出す差の材料（BLK-05、data-model.md「ShieldRaceSnapshot」）。
/// 本体が読み直すたびに書き、拡張がシールドを出す時刻の分まで計算する。
struct ShieldRaceSnapshot: Codable, Equatable, Sendable {
    /// 相手の曲線の間隔（秒）
    static let step: TimeInterval = 15 * 60

    var writtenAt: Date
    /// 4:00 区切りの日
    var dayKey: String
    var dayStart: Date
    var focusSecAtWrite: Int
    /// 書いた時点で集中のタイマーが動いていたか（一時停止中・デトックスは false）
    var isFocusRunning: Bool
    /// 「先週の自分より」「目標より」
    var opponentPrefix: String
    /// 相手の累積集中（日付の区切りから15分ごと、秒）。相手がいなければ空
    var opponentCurve: [Int]

    func focusSeconds(at now: Date) -> Int {
        focusSecAtWrite + (isFocusRunning ? max(0, Int(now.timeIntervalSince(writtenAt))) : 0)
    }

    /// 相手のその時刻までの集中。あいだは直線でつなぐ
    func opponentSeconds(at now: Date) -> Int? {
        guard let last = opponentCurve.last else { return nil }
        let position = now.timeIntervalSince(dayStart) / Self.step
        guard position > 0 else { return opponentCurve.first }
        let index = Int(position)
        guard index + 1 < opponentCurve.count else { return last }
        let fraction = position - Double(index)
        let from = Double(opponentCurve[index]), to = Double(opponentCurve[index + 1])
        return Int((from + (to - from) * fraction).rounded())
    }

    /// 相手との差（プラスならリード）。別の日・相手なしなら nil
    func diffSeconds(at now: Date, calendar: Calendar) -> Int? {
        guard DayBoundary.dayKey(containing: now, calendar: calendar) == dayKey,
              let opponent = opponentSeconds(at: now) else { return nil }
        return focusSeconds(at: now) - opponent
    }
}

/// シールドの文言（app-blocking.md「シールド」）。
struct ShieldText: Equatable, Sendable {
    var title: String
    var subtitle: String
    var primaryButton: String
    var secondaryButton: String

    /// シールドから GhostPace を直接は開けないので、「開く」のあとの流れを書いておく
    static let howTo = "「開く」を押すと通知が届きます。通知か GhostPace を開いて、3秒長押しすると5秒後に開けます"

    static func make(snapshot: ShieldRaceSnapshot?, now: Date, calendar: Calendar, isFocusBlocking: Bool = false) -> ShieldText {
        var subtitle = howTo
        if let snapshot, let diff = snapshot.diffSeconds(at: now, calendar: calendar) {
            subtitle = "今日は\(snapshot.opponentPrefix) \(DurationFormat.signed(diff))\n\n" + howTo
        }
        let title = isFocusBlocking ? "集中中はブロック中" : "ゲームと SNS はブロック中"
        return ShieldText(title: title, subtitle: subtitle, primaryButton: "閉じる", secondaryButton: "開く")
    }
}
