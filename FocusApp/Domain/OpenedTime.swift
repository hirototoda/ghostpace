import Foundation

/// その日に開けた時間と回数（DTX-05、docs/product/features/digital-detox.md「画面に出す数字」）。
/// ホームの小さい数字と夜の振り返りで同じ言い方にする（2026-10-03 オーナー決定）。
struct OpenedTime: Hashable {
    /// 長押しで開けていた時間＋ゲーム・SNS の時間を過ぎても開いていた分（秒）
    var seconds: Int
    /// 長押しで開けた回数
    var count: Int

    /// 一度も開けていない
    var isNone: Bool { seconds == 0 && count == 0 }

    /// 時間の部分。例「25分」「1分未満」
    var durationText: String {
        seconds < 60 ? String(localized: "1分未満") : DurationFormat.japanese(seconds)
    }

    /// 文章にしたもの（読み上げにも使う）。例「開けた 25分（2回）」「開けた 5分」「開けていない」「開けた 1分未満（1回）」
    var text: String {
        if isNone { return String(localized: "開けていない") }
        return count > 0 ? String(localized: "開けた \(durationText)（\(count)回）") : String(localized: "開けた \(durationText)")
    }
}
