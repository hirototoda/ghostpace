import Foundation

/// ラップ表の相手（平均・区間ベスト）と理論ベストの材料：過ぎた1日（ANA-06・11）。
/// 時刻はその日の 4:00 からの経過で揃える
struct RecordDay {
    /// その日の 4:00
    var dayStart: Date
    /// その日の集中の一切れ（1日の終わりまで、時刻の順）
    var pieces: [FocusPoints.Piece]
    /// 集中以外の点（デトックス・睡眠・開けた回数・計画どおり）の、その時刻までの合計
    var otherPoints: (Date) -> Double

    /// 4:00 からの経過までのポイント（その日のグラフ・ポイントの推移と同じ数え方）
    func points(at offset: TimeInterval) -> Double {
        let date = dayStart.addingTimeInterval(offset)
        return FocusPoints.points(pieces, until: date) + otherPoints(date)
    }

    /// 4:00 からの経過までの、集中以外の点
    func otherPoints(at offset: TimeInterval) -> Double { otherPoints(dayStart.addingTimeInterval(offset)) }
}

/// 区間ベスト（ANA-11）：その区間に一番ポイントが増えた日とその値（数え直す前の、実際の1日の値）
struct SectionRecord: Hashable {
    /// その日の 4:00
    var dayStart: Date
    var value: Double
}

/// ラップ表の相手の1日（4:00 からの経過 → その時刻までのポイント）を作る（ANA-06・11、analysis.md「比べる相手」「区間ベストと理論ベスト」）
enum LapTargets {
    /// 平均：記録のある日の、その時刻までのポイントの平均。最後は1日の平均。日がなければ nil
    static func average(_ days: [RecordDay]) -> ((TimeInterval) -> Double)? {
        guard !days.isEmpty else { return nil }
        return { offset in days.reduce(0) { $0 + $1.points(at: offset) } / Double(days.count) }
    }

    /// 12区間それぞれの区間ベスト。区間全体の値で比べ、同じなら新しい日。日がなければ空
    static func sectionRecords(_ days: [RecordDay]) -> [SectionRecord] {
        guard !days.isEmpty else { return [] }
        let days = days.sorted { $0.dayStart < $1.dayStart }
        return (0..<Laps.count).map { index in
            let start = Double(index) * Laps.length
            var best: SectionRecord?
            for day in days {
                let value = day.points(at: start + Laps.length) - day.points(at: start)
                // 古い日から見て、同じ値なら新しい日に置き換える
                if value >= best?.value ?? -.infinity { best = SectionRecord(dayStart: day.dayStart, value: value) }
            }
            return best ?? SectionRecord(dayStart: days[days.count - 1].dayStart, value: 0)
        }
    }

    /// 睡眠の区間：`sleep`（今の設定の睡眠の時刻を今日と翌日に当てはめたもの）と半分以上（ちょうど半分も）重なる区間の番号
    static func sleepSections(_ sleep: [DateInterval], dayStart: Date) -> Set<Int> {
        Set(Laps.sections(dayStart: dayStart).enumerated().compactMap { index, section in
            let overlap = sleep.reduce(0.0) { $0 + ($1.intersection(with: section)?.duration ?? 0) }
            return overlap >= Laps.length / 2 ? index : nil
        })
    }

    /// 区間ベストをつないだ1日（4:00 からの経過 → ポイント）。最後の値が理論ベスト。
    /// - 起きている区間：区間ベストの日の値。集中は1回の長さの倍率・重み・開けた時間をもとの日のまま切り出し（区間をまたぐ集中は境目で切る）、
    ///   1日の合計の倍率（8時間・10時間）だけ、つないだ1日で時刻の順に数え直す。集中以外の点はもとの日のその区間の値
    /// - 睡眠の区間（`sleepSections`）：期間の平均の値のまま（1日の合計の数え直しには入れない）
    /// - 区間の途中は、選んだ日（睡眠の区間は平均）の同じ時刻まで
    static func sectionBestDay(_ days: [RecordDay], records: [SectionRecord],
                               sleepSections: Set<Int>) -> (TimeInterval) -> Double {
        let byDay = Dictionary(days.map { ($0.dayStart, $0) }, uniquingKeysWith: { first, _ in first })
        let average = average(days) ?? { _ in 0 }
        // つないだ1日の 4:00。差だけを使うので、どの時刻でもよい
        let frame = Date(timeIntervalSinceReferenceDate: 0)
        var pieces: [FocusPoints.Piece] = []
        for (index, record) in records.enumerated() where !sleepSections.contains(index) {
            guard let day = byDay[record.dayStart] else { continue }
            let section = DateInterval(start: day.dayStart.addingTimeInterval(Double(index) * Laps.length), duration: Laps.length)
            pieces += day.pieces.compactMap { $0.clipped(to: section)?.shifted(by: frame.timeIntervalSince(day.dayStart)) }
        }
        return { offset in
            var total = FocusPoints.points(pieces, until: frame.addingTimeInterval(offset))
            for (index, record) in records.enumerated() {
                let start = Double(index) * Laps.length
                guard offset > start else { break }
                let end = min(offset, start + Laps.length)
                if sleepSections.contains(index) {
                    total += average(end) - average(start)
                } else if let day = byDay[record.dayStart] {
                    total += day.otherPoints(at: end) - day.otherPoints(at: start)
                }
            }
            return total
        }
    }
}

extension HomeSnapshot {
    /// 過ぎた日の材料（ANA-06・11）。`myPoints(until:)` と同じ数え方を、集中の一切れと集中以外に分けて持つ
    var recordDay: RecordDay {
        let detox = self.detox
        let awards = planAwards.map(\.date)
        return RecordDay(dayStart: dayStart,
                         pieces: FocusPoints.pieces(sessions, until: now, opened: detox?.openedIntervals ?? []),
                         otherPoints: { date in
                             (detox?.points(until: date) ?? 0) + Double(awards.filter { $0 <= date }.count)
                         })
    }
}
