import Foundation

/// 裏のグラフの線1本。値はその時刻までにたまったポイント（GHO-13。2026-10-02 から時間の線はなくしてポイントだけ）。
struct RaceCurve: Hashable {
    enum Kind: Hashable {
        case minePoints, opponentPoints

        var isOpponent: Bool { self == .opponentPoints }
    }

    struct Value: Hashable {
        var date: Date
        var value: Double
    }

    var kind: Kind
    var values: [Value]
}

extension HomeSnapshot {
    /// グラフの点の間隔（5分）
    static let curveStep: TimeInterval = 5 * 60

    /// トラックの上の自分と相手の進み（1周＝相手の1日分。相手がいなければ今日の計画の集中）。
    /// 1を超えたらゴール（一番上）で止まる（GHO-12）
    func raceProgress(_ opponent: Opponent?) -> (me: Double, opponent: Double?) {
        if let opponent, let now = opponentFocusSeconds(opponent), let whole = opponentWholeDaySeconds(opponent) {
            let whole = Double(max(whole, 1))
            return (min(Double(focusSeconds) / whole, 1), min(Double(now) / whole, 1))
        }
        let planned = plannedFocusSeconds
        return (planned > 0 ? min(Double(focusSeconds) / Double(planned), 1) : 0, nil)
    }

    /// 自分のポイント（今まで）。集中とデトックス（DTX-03）の合計
    var points: Double { myPoints(until: now) }

    func myPoints(until date: Date) -> Double {
        FocusPoints.points(sessions, until: date, opened: detox?.openedIntervals ?? []) + otherPoints.until(date)
    }

    /// 相手の `date` までのポイント。相手がいなければ nil。
    /// 先週のデトックスがない日（丸1日分の記録がない）は、自分だけデトックスの点が付いて比べられないので nil（線を出さない）
    func opponentPoints(_ opponent: Opponent, at date: Date) -> Double? {
        switch opponent {
        case .lastWeek:
            guard let ghostDetox else { return nil }
            return FocusPoints.points(ghost?.segments ?? [], until: date, opened: ghostDetox.openedIntervals)
                + ghostDetox.points(until: date) + Double(ghostPlanAwards.filter { $0 <= date }.count)
        case .goal:
            return goal.map {
                FocusPoints.points($0.segments, until: date) + (goalDetox?.points(until: date) ?? 0)
                    + Double(goalPlanAwards.filter { $0 <= date }.count)
            }
        }
    }

    /// 裏のグラフの線（ポイント）。自分は 4:00〜今、相手は 4:00〜翌4:00（今の時刻にも点を置く）。
    /// 相手のポイントがない日（先週のデトックスがない日など）は自分の線だけ
    func raceCurves(opponent: Opponent?) -> [RaceCurve] {
        var curves = [RaceCurve(kind: .minePoints, values: sampleDates(until: max(now, dayStart)).map {
            .init(date: $0, value: myPoints(until: $0))
        })]
        if let opponent, opponentPoints(opponent, at: dayStart) != nil {
            curves.append(RaceCurve(kind: .opponentPoints, values: sampleDates(until: dayEnd).map {
                .init(date: $0, value: opponentPoints(opponent, at: $0) ?? 0)
            }))
        }
        return curves
    }

    /// 4:00 から5分おきの時刻と、今・終わりの時刻。
    private func sampleDates(until end: Date) -> [Date] {
        var dates: [Date] = []
        var cursor = dayStart
        while cursor < end {
            dates.append(cursor)
            cursor = cursor.addingTimeInterval(Self.curveStep)
        }
        dates.append(end)
        if now > dayStart, now < end, !dates.contains(now) { dates.append(now) }
        return dates.sorted()
    }
}
