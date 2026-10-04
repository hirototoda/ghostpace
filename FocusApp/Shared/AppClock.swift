import Foundation
import SwiftUI

/// 現在時刻の取得元。アプリ内で現在時刻が必要なときは必ずこれを経由する（Date() の直接呼び出しは禁止）。
/// Swift 標準の `Clock` と名前が衝突するため `AppClock` とする。
protocol AppClock: Sendable {
    func now() -> Date
}

/// 実際の現在時刻。Date() を呼んでよいのはここだけ。
struct SystemClock: AppClock {
    func now() -> Date { Date() }
}

/// 常に同じ時刻を返す。ユニットテスト用。
struct FixedClock: AppClock {
    let date: Date

    func now() -> Date { date }
}

/// 指定した時刻から始まり、実時間と同じ速さで進む。
/// シミュレーター検証で `-fixedNow` を指定したときに使う（タイマーが進むように、止まった時計にはしない）。
struct OffsetClock: AppClock {
    let offset: TimeInterval
    let base: any AppClock

    init(startingAt start: Date, base: any AppClock = SystemClock()) {
        self.offset = start.timeIntervalSince(base.now())
        self.base = base
    }

    func now() -> Date { base.now().addingTimeInterval(offset) }
}

extension EnvironmentValues {
    @Entry var clock: any AppClock = SystemClock()
}
