import ActivityKit
import Foundation

/// ロック画面と画面上部（Dynamic Island）に出すタイマー（focus-timer.md TMR-06）。
/// 本体と拡張（TimerActivity）の両方に入る。中身は本体が `TimerActivity.make` で作る。
struct TimerActivityAttributes: ActivityAttributes, Hashable {
    /// 表示中に変わる値。数字は iPhone が自分で数えるので、時刻だけを渡す（アプリを開かなくても動く）
    struct ContentState: Codable, Hashable {
        /// 見出し：「13:00 まで」「経過」「一時停止中」
        var caption: String
        var reading: Reading
        var progress: Progress

        /// iPhone の時計に合わせて時刻をずらす（見本の時計 `-fixedNow` のときだけ。見出しはそのまま）
        func shifted(by seconds: TimeInterval) -> ContentState {
            guard seconds != 0 else { return self }
            var state = self
            state.reading = reading.shifted(by: seconds)
            state.progress = progress.shifted(by: seconds)
            return state
        }
    }

    /// 大きな数字
    enum Reading: Codable, Hashable {
        /// この時刻まで数え下げ、過ぎたらそのまま超過を数え上げる
        case countdown(to: Date)
        /// この時刻から数え上げる（ストップウォッチ。一時停止の分は後ろにずらしてある）
        case countUp(from: Date)
        /// 止まった数字（一時停止中）
        case fixed(seconds: Int, overtime: Bool)

        func shifted(by seconds: TimeInterval) -> Reading {
            switch self {
            case .countdown(let date): .countdown(to: date.addingTimeInterval(seconds))
            case .countUp(let date): .countUp(from: date.addingTimeInterval(seconds))
            case .fixed: self
            }
        }
    }

    /// 進み具合の円
    enum Progress: Codable, Hashable {
        /// start から end にかけて埋まる（end を過ぎたら満杯）
        case live(start: Date, end: Date)
        /// 止まった値（0〜1）
        case fixed(Double)
        /// 出さない（ストップウォッチ）
        case none

        func shifted(by seconds: TimeInterval) -> Progress {
            switch self {
            case .live(let start, let end): .live(start: start.addingTimeInterval(seconds), end: end.addingTimeInterval(seconds))
            case .fixed, .none: self
            }
        }
    }

    var sessionId: UUID
    /// ブロック名（なければカテゴリ名）
    var title: String
    var categoryName: String
    var countsAsFocus: Bool
}
