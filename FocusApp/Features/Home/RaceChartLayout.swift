import Foundation

/// 裏のポイントのグラフ（GHO-13）の見える範囲と、開いたときの動き。
/// 2026-10-03 オーナー決定：今の2時間前〜1時間先の3時間で始め、横にずらせて、［1日］で 4:00〜翌4:00
/// （同じ日に8時間から3時間へ。差が見えにくかったため）。
/// 開いて最初に裏返したときは、3時間の幅で 4:00 から線の先を追いかけ、今に近づくほどゆっくりになって止まる。
struct RaceChartLayout {
    var dayStart: Date
    var dayEnd: Date
    var now: Date

    /// 動いている途中の形
    struct Frame: Equatable {
        /// 線の先（ここまで描く）
        var head: Date
        /// 見えている範囲
        var domain: ClosedRange<Date>
    }

    static let hour: TimeInterval = 3600
    /// 見えている幅（止まったときも、歩いている間も）
    static let windowLength = 3 * hour
    /// 今より先を見せる長さ（相手のこの先1時間）
    static let lookAhead = 1 * hour
    /// 裏返りきるのを待つ時間（秒）
    static let flipWaitSeconds = 0.35

    /// 止まったときの3時間（今の2時間前〜1時間先。1日からはみ出すなら端に寄せる）
    var homeWindow: ClosedRange<Date> {
        window(endingAt: now.addingTimeInterval(Self.lookAhead), length: Self.windowLength)
    }

    /// 1日（4:00〜翌4:00）からはみ出さない窓
    func window(endingAt end: Date, length: TimeInterval) -> ClosedRange<Date> {
        let upper = min(max(end, dayStart.addingTimeInterval(length)), dayEnd)
        return upper.addingTimeInterval(-length)...upper
    }

    /// 4:00 ちょうどはまだ線がないので動かない
    var playsIntro: Bool { now > dayStart }

    /// 裏が見えたときに動くか。起動・ほかのアプリから戻ってから最初の1回だけ。
    /// 視差効果を減らす設定・1日全体で始めるとき・4:00 ちょうどは動かない（動かなかった回は「最初の1回」に数えない）
    func playsIntro(alreadyPlayed: Bool, reduceMotion: Bool, wholeDay: Bool) -> Bool {
        !alreadyPlayed && !reduceMotion && !wholeDay && playsIntro
    }

    /// 止まっているときに見えている範囲。1日は 4:00〜翌4:00、3時間はずらした位置（なければ今のまわり）から3時間
    func visibleRange(wholeDay: Bool, scrollStart: Date?) -> ClosedRange<Date> {
        if wholeDay { return dayStart...dayEnd }
        let start = scrollStart ?? homeWindow.lowerBound
        return start...start.addingTimeInterval(Self.windowLength)
    }

    /// 指で横にずらしたあとの3時間の左端。`translation` は指の動き（右が＋）、`plotWidth` はグラフの幅。
    /// 幅いっぱい＝3時間の割合で動かし、4:00〜翌4:00 からはみ出さない
    func panned(from start: Date, by translation: CGFloat, plotWidth: CGFloat) -> Date {
        guard plotWidth > 0 else { return start }
        let moved = start.addingTimeInterval(-Double(translation / plotWidth) * Self.windowLength)
        return min(max(moved, dayStart), dayEnd.addingTimeInterval(-Self.windowLength))
    }

    /// 上の行の差（自分−相手）。相手のポイントがない日は nil（差を出さない）
    static func gap(mine: Double, theirs: Double?) -> Double? {
        theirs.map { mine - $0 }
    }

    /// 差の色：丸めて0以上なら前向きな色（true）、後ろなら落ち着いた色（false）
    static func isAhead(_ gap: Double) -> Bool { (gap * 10).rounded() >= 0 }

    /// 動く時間（秒）。4:00 からの時間に合わせて2〜4.5秒（12時間で4秒。3秒と比べてオーナーが選んだ）
    var introSeconds: Double {
        min(max(2 + now.timeIntervalSince(dayStart) / Self.hour / 6, 2), 4.5)
    }

    /// 歩いている間の3時間（線の先を止まったときと同じ、2時間前〜1時間先の境目に置く）
    func walkWindow(head: Date) -> ClosedRange<Date> {
        window(endingAt: head.addingTimeInterval(Self.lookAhead), length: Self.windowLength)
    }

    /// 進み（0〜1）のときの線の先と見えている範囲。初めは速く、今に近づくほどゆっくり（12時間の日は最後の1時間に4割強の時間）
    func introFrame(_ progress: Double) -> Frame {
        let head = Self.lerp(dayStart, now, Self.easeOut(min(max(progress, 0), 1)))
        return Frame(head: head, domain: walkWindow(head: head))
    }

    /// 縦の範囲。1日は0から。3時間は見えている点の一番下〜一番上に上下15%の余白。
    /// 高さは最低4pt（真ん中から広げる）、0より下になるなら上へずらす。
    /// ただし見えている点にマイナスがあるときは、0より下も出す（2026-10-03、GHO-14）
    static func yDomain(values: [Double], wholeDay: Bool) -> ClosedRange<Double> {
        guard var low = values.min(), var high = values.max() else { return 0...10 }
        let hasNegative = low < 0
        if wholeDay {
            guard hasNegative else { return 0...max(high * 1.05, 1) }
            let pad = max(high - low, 1) * 0.05
            return (low - pad)...(high + pad)
        }
        if high - low < 4 {
            let middle = (low + high) / 2
            low = middle - 2
            high = middle + 2
        }
        let pad = (high - low) * 0.15
        low -= pad
        high += pad
        if low < 0, !hasNegative {
            high -= low
            low = 0
        }
        return low...high
    }

    /// `head` までの点（間は直線で足す）
    static func cut(_ values: [RaceCurve.Value], at head: Date) -> [RaceCurve.Value] {
        var result = values.filter { $0.date <= head }
        if let last = result.last, last.date < head,
           let next = values.first(where: { $0.date > head }) {
            let ratio = head.timeIntervalSince(last.date) / next.date.timeIntervalSince(last.date)
            result.append(.init(date: head, value: last.value + (next.value - last.value) * ratio))
        }
        return result
    }

    /// 上の行の差（例「差 −10.0pt」）。小数1桁に丸め、丸めて0なら符号なし
    static func gapText(_ points: Double) -> String {
        let rounded = (points * 10).rounded() / 10
        let number = abs(rounded).formatted(.number.precision(.fractionLength(1)))
        let sign = rounded > 0 ? "+" : rounded < 0 ? "−" : ""
        return String(localized: "差 \(sign)\(number)pt")
    }

    /// だんだんゆっくり（3次）
    static func easeOut(_ t: Double) -> Double {
        1 - pow(1 - t, 3)
    }

    static func lerp(_ a: Date, _ b: Date, _ t: Double) -> Date {
        a.addingTimeInterval(b.timeIntervalSince(a) * t)
    }
}
