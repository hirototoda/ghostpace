import Foundation

/// ロック画面と画面上部に出すタイマーの中身（focus-timer.md TMR-06）。
/// 数字は iPhone が時刻から数えるので、ここで作る値は開始・一時停止・再開のときだけ変わる。
struct TimerActivity: Hashable {
    typealias State = TimerActivityAttributes.ContentState

    var attributes: TimerActivityAttributes
    var state: State

    static let pausedCaption = "一時停止中"
    static let stopwatchCaption = "経過"

    /// 実行中のセッションから作る。数字の決め方はタイマー画面と同じ：
    /// 一時停止中、計画外は止まり、計画ブロックから始めたものは減り続ける。
    static func make(_ session: FocusSession, now: Date, timeZone: TimeZone) -> TimerActivity {
        let attributes = TimerActivityAttributes(sessionId: session.id, title: session.title,
                                                 categoryName: session.category.name,
                                                 countsAsFocus: session.category.countsAsFocus)
        let elapsed = session.activeDuration(at: now)
        // 一時停止の分を後ろにずらした開始時刻。動いている間は時間がたっても変わらない
        let shiftedStart = wholeSecond(now.addingTimeInterval(-elapsed))

        guard let plannedEnd = session.plannedEnd(at: now) else {
            let state = session.isPaused
                ? State(caption: pausedCaption, reading: .fixed(seconds: session.activeSeconds(at: now), overtime: false), progress: .none)
                : State(caption: stopwatchCaption, reading: .countUp(from: shiftedStart), progress: .none)
            return TimerActivity(attributes: attributes, state: state)
        }

        let end = wholeSecond(plannedEnd)
        guard session.isPaused else {
            // 予定の終わりより後に始めたとき（ブロックの終わりを過ぎてから開始）は、初めから満杯の円
            return TimerActivity(attributes: attributes, state: State(caption: clockText(end, timeZone: timeZone) + " まで",
                                                                      reading: .countdown(to: end),
                                                                      progress: .live(start: min(shiftedStart, end), end: end)))
        }
        let remaining = plannedEnd.timeIntervalSince(now)
        let progress = remaining <= 0 ? 1 : min(elapsed / max(elapsed + remaining, 1), 1)
        let reading: TimerActivityAttributes.Reading
        if session.plannedEndAt != nil {
            reading = .countdown(to: end)
        } else {
            let seconds = session.remainingSeconds(at: now) ?? 0
            reading = .fixed(seconds: abs(seconds), overtime: seconds < 0)
        }
        return TimerActivity(attributes: attributes, state: State(caption: pausedCaption, reading: reading, progress: .fixed(progress)))
    }

    /// 秒の端数を落とす（読み直すたびに値が揺れて書き換えが起きないように）
    private static func wholeSecond(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate.rounded())
    }

    /// `13:00`。タイマー画面の「終了予定」と同じ2桁の書き方
    private static func clockText(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}

/// ロック画面と画面上部の表示を出し入れする。nil なら消す。
@MainActor
protocol LiveActivityControlling: AnyObject {
    func show(_ activity: TimerActivity?)
}

/// 何もしない（見本データ・UI テスト用）。最後に出そうとした値を覚えておく。
@MainActor
final class NoLiveActivity: LiveActivityControlling {
    private(set) var shown: TimerActivity?

    func show(_ activity: TimerActivity?) { shown = activity }
}
