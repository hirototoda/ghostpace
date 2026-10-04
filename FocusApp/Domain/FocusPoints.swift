import Foundation

/// 集中のポイント（GHO-14、docs/product/features/ghost-race.md「集中の点」、ADR-0019）。
/// - 集中10分＝1pt。1回で90分を超えた分は×0.75、3時間を超えた分は×0.5
/// - 1日の合計が8時間を超えた分は×0.75、10時間を超えた分は×0.5
/// - 2つの倍率は低いほうを使い、0.5 より下げない
/// - 集中していない時間（止めた・一時停止）が5分続いたら1回目から数え直す。5分未満なら続き（止めていた時間は数えない）
/// - 集中中に長押しで開けていた時間は0点。1回の長さ・1日の合計は進む（休みには入れない。2026-10-03 オーナー決定）
/// - デトックス・睡眠・開けた回数の点は DetoxDay（DTX-03）
enum FocusPoints {
    static let focusPerSecond = 1.0 / 600
    /// これ以上休んだら1回目から数え直す
    static let restToStartOver: TimeInterval = 5 * 60
    static let floor = 0.5
    /// 1回の長さ：これを超えたら×0.75、×0.5
    static let runLimits: [TimeInterval] = [90 * 60, 3 * 3600]
    /// 1日の合計：これを超えたら×0.75、×0.5
    static let dayLimits: [TimeInterval] = [8 * 3600, 10 * 3600]

    /// 1回の長さの倍率（続けた集中の秒数から）
    static func runFactor(_ seconds: TimeInterval) -> Double { factor(seconds, limits: runLimits) }

    /// 1日の合計の倍率（その日の集中の秒数から）
    static func dayFactor(_ seconds: TimeInterval) -> Double { factor(seconds, limits: dayLimits) }

    private static func factor(_ seconds: TimeInterval, limits: [TimeInterval]) -> Double {
        seconds < limits[0] ? 1 : seconds < limits[1] ? 0.75 : 0.5
    }

    /// 集中が進む区間。`rate` は1秒あたりに増える集中の秒数。
    /// `continuous` が false の区間（目標のゴーストが目標を足した分）は、休みを挟みながら進むとみなして
    /// 1回の長さの倍率を掛けない（2026-10-03）
    struct Flow {
        var start: Date
        var end: Date
        var rate: Double = 1
        var continuous = true
    }

    /// 記録の区間の `until` までの集中のポイント（デトックスのカテゴリの区間は数えない）。
    /// `opened` は開けていた時間（DTX-05）。その間は点を付けない
    static func points(_ segments: [TimeSegment], until date: Date, opened: [DateInterval] = []) -> Double {
        points(segments.filter(\.countsAsFocus).map { Flow(start: $0.start, end: $0.end) }, until: date, opened: opened)
    }

    /// 目標のゴーストの `until` までのポイント。計画のブロックは自分のタイマーと同じに数え、目標を足した分は休みを挟むとみなす
    static func points(_ segments: [PaceSegment], until date: Date) -> Double {
        points(segments.map { Flow(start: $0.start, end: $0.end, rate: $0.rate, continuous: $0.fromPlan) }, until: date)
    }

    static func points(_ flows: [Flow], until date: Date, opened: [DateInterval] = []) -> Double {
        let openedBounds = opened.flatMap { [$0.start, $0.end] }
        var total = 0.0
        var day: TimeInterval = 0
        var run: TimeInterval = 0
        var lastContinuousEnd: Date?
        for flow in flows.sorted(by: { $0.start < $1.start }) {
            let end = min(flow.end, date)
            guard end > flow.start, flow.rate > 0 else { continue }
            if flow.continuous {
                if let last = lastContinuousEnd, flow.start.timeIntervalSince(last) < restToStartOver {
                    // 5分未満で再開：前の続き
                } else {
                    run = 0
                }
            }
            var left = end.timeIntervalSince(flow.start) * flow.rate
            var cursor = flow.start
            while left > 0 {
                // 次に倍率が変わる・開けた時間に出入りするまでの集中の秒数
                var step = left
                for bound in openedBounds where bound > cursor { step = min(step, bound.timeIntervalSince(cursor) * flow.rate) }
                for limit in dayLimits where day < limit { step = min(step, limit - day) }
                if flow.continuous {
                    for limit in runLimits where run < limit { step = min(step, limit - run) }
                }
                let factor = max(min(flow.continuous ? runFactor(run) : 1, dayFactor(day)), floor)
                let middle = cursor.addingTimeInterval(step / flow.rate / 2)
                if !opened.contains(where: { $0.start < middle && middle < $0.end }) {
                    total += focusPerSecond * step * factor
                }
                cursor = cursor.addingTimeInterval(step / flow.rate)
                day += step
                if flow.continuous { run += step }
                left -= step
            }
            lastContinuousEnd = flow.continuous ? max(lastContinuousEnd ?? .distantPast, end) : nil
        }
        return total
    }
}
