import Foundation

/// ラップ表の相手（平均・区間ベスト）と理論ベストの材料：過ぎた1日（ANA-06・11）。
/// 時刻は同じ時刻でそろえる（GHO-02）：`origin`（日の名前の日の 0:00）からの経過で比べる
struct RecordDay {
    /// その日の始まり
    var dayStart: Date
    /// その日の集中の一切れ（1日の終わりまで、時刻の順）
    var pieces: [FocusPoints.Piece]
    /// 集中以外の点（デトックス・睡眠・開けた回数・計画どおり）の、その時刻までの合計
    var otherPoints: (Date) -> Double
    /// その日の終わり（区切り）。nil なら切らない
    var dayEnd: Date? = nil
    /// 経過を数える基準（日の名前の日の 0:00）。nil ならその日の始まり（区切りの履歴がない日どうし）
    var origin: Date? = nil

    private var base: Date { origin ?? dayStart }

    /// 時刻をその日の中に収める（始まりより前は0、終わりより後はその日の合計）
    private func clamped(_ date: Date) -> Date { min(max(date, dayStart), dayEnd ?? .distantFuture) }

    /// 基準からの経過までのポイント（その日のグラフ・ポイントの推移と同じ数え方）
    func points(at offset: TimeInterval) -> Double {
        let date = clamped(base.addingTimeInterval(offset))
        return FocusPoints.points(pieces, until: date) + otherPoints(date)
    }

    /// 基準からの経過までの、集中以外の点
    func otherPoints(at offset: TimeInterval) -> Double { otherPoints(clamped(base.addingTimeInterval(offset))) }

    /// 基準からの経過の区間を、その日の時刻にしたもの
    func interval(_ section: LapSection) -> DateInterval {
        DateInterval(start: base.addingTimeInterval(section.start), end: base.addingTimeInterval(max(section.start, section.end)))
    }

    /// 基準の時刻（つないだ1日に重ねるのに使う）
    var originDate: Date { base }
}

/// ラップ表の区間（今日の基準からの経過、秒）。今日の一日の始まりから2時間ごと（ANA-06・11）
struct LapSection: Hashable {
    var start: TimeInterval
    var end: TimeInterval

    var length: TimeInterval { end - start }

    /// 今日の区間を、今日の基準 `origin` からの経過にしたもの
    static func of(dayStart: Date, dayEnd: Date? = nil, origin: Date? = nil) -> [LapSection] {
        let origin = origin ?? dayStart
        return Laps.sections(dayStart: dayStart, dayEnd: dayEnd).map {
            LapSection(start: $0.start.timeIntervalSince(origin), end: $0.end.timeIntervalSince(origin))
        }
    }

    /// 区切りの履歴がない日（4:00 からの12区間）
    static var legacy: [LapSection] {
        (0..<Laps.count).map { LapSection(start: Double($0) * Laps.length, end: Double($0 + 1) * Laps.length) }
    }
}

/// 区間ベスト（ANA-11）：その区間に一番ポイントが増えた日とその値（数え直す前の、実際の1日の値）
struct SectionRecord: Hashable {
    /// その日の始まり
    var dayStart: Date
    var value: Double
}

/// ラップ表の相手の1日（基準からの経過 → その時刻までのポイント）を作る（ANA-06・11、analysis.md「比べる相手」「区間ベストと理論ベスト」）
enum LapTargets {
    /// 同点とみなす幅。区間の値・1日の値は累計の引き算・足し算なので、同じ点でも浮動小数の誤差で小さくずれる
    static let tieTolerance = 1e-9

    /// `a` が `b` より多い、または同じ（誤差の幅の中）
    static func atLeast(_ a: Double, _ b: Double) -> Bool { a >= b - tieTolerance }
    /// 平均：記録のある日の、その時刻までのポイントの平均。最後は1日の平均。日がなければ nil
    static func average(_ days: [RecordDay]) -> ((TimeInterval) -> Double)? {
        guard !days.isEmpty else { return nil }
        return { offset in days.reduce(0) { $0 + $1.points(at: offset) } / Double(days.count) }
    }

    /// 区間それぞれの区間ベスト。区間全体の値で比べ、同じ（誤差の幅の中）なら新しい日。日がなければ空。
    /// 区間は今日と同じ時刻の区間（区切りが今日と違う日は、その時刻の分の値で比べる。2026-10-21、Claude 補足、Q46）
    static func sectionRecords(_ days: [RecordDay], sections: [LapSection] = LapSection.legacy) -> [SectionRecord] {
        guard !days.isEmpty else { return [] }
        let days = days.sorted { $0.dayStart < $1.dayStart }
        return sections.map { section in
            var best: SectionRecord?
            for day in days {
                let value = day.points(at: section.end) - day.points(at: section.start)
                // 古い日から見て、同じ値なら新しい日に置き換える
                if atLeast(value, best?.value ?? -.infinity) { best = SectionRecord(dayStart: day.dayStart, value: value) }
            }
            return best ?? SectionRecord(dayStart: days[days.count - 1].dayStart, value: 0)
        }
    }

    /// 睡眠の区間：設定の睡眠の時刻（0:00 からの分）を今日（その朝と夜）に当てはめ、半分以上（ちょうど半分も）重なる区間の番号
    static func sleepSections(startMinutes: Int, endMinutes: Int, day: BoundaryDay, calendar: Calendar) -> Set<Int> {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: day.date) ?? day.date.addingTimeInterval(86400)
        let sleep = [day.date, tomorrow].map {
            SleepLine.fromSetting(startMinutes: startMinutes, endMinutes: endMinutes, dayStart: $0, calendar: calendar).interval
        }
        return sleepSections(sleep, dayStart: day.start, dayEnd: day.end)
    }

    /// 区切りの履歴がないとき（朝4:00区切り）
    static func sleepSections(startMinutes: Int, endMinutes: Int, dayStart: Date, calendar: Calendar) -> Set<Int> {
        sleepSections(startMinutes: startMinutes, endMinutes: endMinutes,
                      day: DayBoundary(calendar: calendar).day(containing: dayStart), calendar: calendar)
    }

    /// 睡眠の区間：`sleep` と半分以上（ちょうど半分も）重なる区間の番号
    static func sleepSections(_ sleep: [DateInterval], dayStart: Date, dayEnd: Date? = nil) -> Set<Int> {
        Set(Laps.sections(dayStart: dayStart, dayEnd: dayEnd).enumerated().compactMap { index, section in
            let overlap = sleep.reduce(0.0) { $0 + ($1.intersection(with: section)?.duration ?? 0) }
            return overlap >= section.duration / 2 && overlap > 0 ? index : nil
        })
    }

    /// 区間ベストをつないだ1日（基準からの経過 → ポイント）。最後の値が理論ベスト。
    /// - 起きている区間：区間ベストの日の値。集中は1回の長さの倍率・重み・開けた時間をもとの日のまま切り出し（区間をまたぐ集中は境目で切る）、
    ///   1日の合計の倍率（8時間・10時間）だけ、つないだ1日で時刻の順に数え直す。集中以外の点はもとの日のその区間の値
    /// - 睡眠の区間（`sleepSections`）：期間の平均の値のまま（1日の合計の数え直しには入れない）
    /// - 区間の途中は、選んだ日（睡眠の区間は平均）の同じ時刻まで
    static func sectionBestDay(_ days: [RecordDay], records: [SectionRecord], sleepSections: Set<Int>,
                               sections: [LapSection] = LapSection.legacy) -> (TimeInterval) -> Double {
        let byDay = Dictionary(days.map { ($0.dayStart, $0) }, uniquingKeysWith: { first, _ in first })
        let average = average(days) ?? { _ in 0 }
        // つないだ1日の基準。差だけを使うので、どの時刻でもよい
        let frame = Date(timeIntervalSinceReferenceDate: 0)
        var pieces: [FocusPoints.Piece] = []
        for (index, record) in records.enumerated() where !sleepSections.contains(index) && sections.indices.contains(index) {
            guard let day = byDay[record.dayStart] else { continue }
            let section = day.interval(sections[index])
            pieces += day.pieces.compactMap { $0.clipped(to: section)?.shifted(by: frame.timeIntervalSince(day.originDate)) }
        }
        return { offset in
            var total = FocusPoints.points(pieces, until: frame.addingTimeInterval(offset))
            for (index, record) in records.enumerated() where sections.indices.contains(index) {
                let start = sections[index].start
                guard offset > start else { break }
                let end = min(offset, sections[index].end)
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

extension LapTargets {
    /// ポイントの多い順（ベスト10・ベストの日）。同じ（誤差の幅の中）なら新しい日が上。記録なしの日は入れない
    static func ranked(_ days: [DayPoints]) -> [DayPoints] {
        days.filter { $0.points != nil }.sorted { a, b in
            let (x, y) = (a.points ?? 0, b.points ?? 0)
            return abs(x - y) <= tieTolerance ? a.dayStart > b.dayStart : x > y
        }
    }
}

/// 自己ベストの1つの期間の材料（ANA-06・09・11）：記録のある日、区間ベスト、理論ベスト、ベスト10。
/// 期間・記録・日付・睡眠の設定が変わったときだけ作り、相手を切り替えたときはラップ表だけを作り直す
struct PeriodRecords {
    /// 記録のある日（古い日が先）
    let days: [RecordDay]
    /// 区間ごとの区間ベスト（今日の区間の数。★に使う）。日がなければ空
    let records: [SectionRecord]
    /// ポイントの多い順（同じなら新しい日が上）
    let ranked: [DayPoints]
    /// 理論ベスト。日がなければ nil
    let theoreticalBest: Double?
    private let average: ((TimeInterval) -> Double)?
    private let sectionBest: (TimeInterval) -> Double

    /// ベスト10
    var topDays: [DayPoints] { Array(ranked.prefix(10)) }

    /// - days: 記録のある日のポイントと材料
    /// - sleepSections: 睡眠の区間（今の設定で決める）
    /// - sections: 今日の区間（今日の基準からの経過）。区間ベストは今日と同じ時刻の区間で比べる
    init(days: [(points: DayPoints, day: RecordDay)], sleepSections: Set<Int>, sections: [LapSection] = LapSection.legacy) {
        let days = days.sorted { $0.points.dayStart < $1.points.dayStart }
        self.days = days.map(\.day)
        records = LapTargets.sectionRecords(self.days, sections: sections)
        ranked = LapTargets.ranked(days.map(\.points))
        average = LapTargets.average(self.days)
        sectionBest = LapTargets.sectionBestDay(self.days, records: records, sleepSections: sleepSections, sections: sections)
        theoreticalBest = days.isEmpty ? nil : sectionBest(sections.last?.end ?? 0)
    }

    /// 相手の1日（基準からの経過 → ポイント）。期間に記録のある日がなければ nil
    func curve(_ target: LapTarget) -> ((TimeInterval) -> Double)? {
        guard !days.isEmpty else { return nil }
        switch target {
        case .bestDay:
            guard let best = ranked.first, let day = days.first(where: { $0.dayStart == best.dayStart }) else { return nil }
            return day.points(at:)
        case .average: return average
        case .sectionBest: return sectionBest
        }
    }
}

/// 集中以外の点（デトックス・睡眠・開けた回数・計画どおり、DTX-03・GHO-16）。
/// ホームのポイント（`HomeSnapshot.myPoints(until:)`）と分析の材料（`RecordDay`）で同じ式を使う
struct OtherPoints {
    var detox: DetoxDay?
    /// 計画どおりの点が付いた時刻
    var planAwards: [Date]

    func until(_ date: Date) -> Double {
        (detox?.points(until: date) ?? 0) + Double(planAwards.filter { $0 <= date }.count)
    }
}

extension HomeSnapshot {
    /// 集中以外の点
    var otherPoints: OtherPoints { OtherPoints(detox: detox, planAwards: planAwards.map(\.date)) }

    /// 過ぎた日の材料（ANA-06・11）。`myPoints(until:)` と同じ数え方を、集中の一切れと集中以外に分けて持つ。
    /// 覚えておくのはこれだけにする（HomeSnapshot を丸ごと覚えない）
    var recordDay: RecordDay {
        RecordDay(dayStart: dayStart, pieces: FocusPoints.pieces(sessions, until: now, opened: detox?.openedIntervals ?? []),
                  otherPoints: otherPoints.until, dayEnd: dayEnd, origin: dayDate)
    }
}
