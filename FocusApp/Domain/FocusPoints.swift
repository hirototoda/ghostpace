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
        /// 点の重み。押し忘れの申告（TMR-13）は0.8
        var weight: Double = 1
    }

    /// 押し忘れの申告の倍率（TMR-13）
    static let declaredFactor = 0.8

    /// 記録の区間の `until` までの集中のポイント（デトックスのカテゴリの区間は数えない）。
    /// `opened` は開けていた時間（DTX-05）。その間は点を付けない
    static func points(_ segments: [TimeSegment], until date: Date, opened: [DateInterval] = []) -> Double {
        points(segments.filter(\.countsAsFocus).map { Flow(start: $0.start, end: $0.end, weight: $0.isDeclared ? declaredFactor : 1) },
               until: date, opened: opened)
    }

    /// 目標のゴーストの `until` までのポイント。計画のブロックは自分のタイマーと同じに数え、目標を足した分は休みを挟むとみなす
    static func points(_ segments: [PaceSegment], until date: Date) -> Double {
        points(segments.map { Flow(start: $0.start, end: $0.end, rate: $0.rate, continuous: $0.fromPlan) }, until: date)
    }

    static func points(_ flows: [Flow], until date: Date, opened: [DateInterval] = []) -> Double {
        points(pieces(flows, until: date, opened: opened), until: date)
    }

    /// 集中の一切れ：1回の長さの倍率・重み・開けていたかが変わらない時間。
    /// 1日の合計の倍率はここでは掛けず、`points(_:until:)` で時刻の順に掛ける（理論ベストで、つないだ1日を数え直すため。ANA-11）
    struct Piece: Hashable {
        var start: Date
        var end: Date
        /// 1秒あたりに増える集中の秒数
        var rate: Double = 1
        /// 1回の長さの倍率（もとの日のまま）
        var runFactor: Double = 1
        /// 点の重み（申告は0.8）
        var weight: Double = 1
        /// 開けていた時間。0点だが1日の合計は進む
        var opened = false

        /// この一切れで増える集中の秒数
        var seconds: TimeInterval { max(0, end.timeIntervalSince(start)) * rate }

        /// `interval` の中だけにする。重ならなければ nil
        func clipped(to interval: DateInterval) -> Piece? {
            var piece = self
            piece.start = max(start, interval.start)
            piece.end = min(end, interval.end)
            return piece.end > piece.start ? piece : nil
        }

        func shifted(by offset: TimeInterval) -> Piece {
            var piece = self
            piece.start = start.addingTimeInterval(offset)
            piece.end = end.addingTimeInterval(offset)
            return piece
        }
    }

    /// 記録の区間の `until` までの集中の一切れ（デトックスのカテゴリの区間は入れない）。時刻の順
    static func pieces(_ segments: [TimeSegment], until date: Date, opened: [DateInterval] = []) -> [Piece] {
        pieces(segments.filter(\.countsAsFocus).map { Flow(start: $0.start, end: $0.end, weight: $0.isDeclared ? declaredFactor : 1) },
               until: date, opened: opened)
    }

    /// `until` までの集中の一切れ。1回の長さの倍率が変わる所と、開けた時間に出入りする所で分ける
    static func pieces(_ flows: [Flow], until date: Date, opened: [DateInterval] = []) -> [Piece] {
        let openedBounds = opened.flatMap { [$0.start, $0.end] }
        var result: [Piece] = []
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
                // 次に1回の長さの倍率が変わる・開けた時間に出入りするまでの集中の秒数
                var step = left
                for bound in openedBounds where bound > cursor { step = min(step, bound.timeIntervalSince(cursor) * flow.rate) }
                if flow.continuous {
                    for limit in runLimits where run < limit { step = min(step, limit - run) }
                }
                let next = cursor.addingTimeInterval(step / flow.rate)
                let middle = cursor.addingTimeInterval(step / flow.rate / 2)
                result.append(Piece(start: cursor, end: next, rate: flow.rate,
                                    runFactor: flow.continuous ? runFactor(run) : 1, weight: flow.weight,
                                    opened: opened.contains { $0.start < middle && middle < $0.end }))
                cursor = next
                if flow.continuous { run += step }
                left -= step
            }
            lastContinuousEnd = flow.continuous ? max(lastContinuousEnd ?? .distantPast, end) : nil
        }
        return result
    }

    /// 一切れを並んだ順に `until` まで数える。1日の合計の倍率は、ここで集中の秒数を足しながら掛ける
    static func points(_ pieces: [Piece], until date: Date) -> Double {
        var total = 0.0
        var day: TimeInterval = 0
        for piece in pieces where piece.start < date {
            var piece = piece
            piece.end = min(piece.end, date)
            var left = piece.seconds
            while left > 0 {
                var step = left
                for limit in dayLimits where day < limit { step = min(step, limit - day) }
                if !piece.opened {
                    total += focusPerSecond * step * max(min(piece.runFactor, dayFactor(day)), floor) * piece.weight
                }
                day += step
                left -= step
            }
        }
        return total
    }
}
