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
        raceCurves(rival: opponent.map(RaceRival.opponent))
    }

    /// 裏のグラフの線。相手が今日（ANA-05）のときは、今日の線を今（この日の時刻に揃えたもの）で止める。
    /// 自分の線には、タイマーの始まりと終わりの時刻にも点を置く（線の色の境目を記録の時刻どおりにするため、2026-10-11）
    func raceCurves(rival: RaceRival?) -> [RaceCurve] {
        let end = max(now, dayStart)
        let boundaries = sessions.flatMap { [$0.start, $0.end] }.filter { $0 > dayStart && $0 < end }
        var curves = [RaceCurve(kind: .minePoints, values: sampleDates(until: end, extra: boundaries).map {
            .init(date: $0, value: myPoints(until: $0))
        })]
        switch rival {
        case .opponent(let opponent):
            if opponentPoints(opponent, at: dayStart) != nil {
                curves.append(RaceCurve(kind: .opponentPoints, values: sampleDates(until: dayEnd).map {
                    .init(date: $0, value: opponentPoints(opponent, at: $0) ?? 0)
                }))
            }
        case .today:
            // 今日がまだ 4:00 ちょうど（線がない）なら出さない
            if let todayRival, todayRival.now > dayStart {
                curves.append(RaceCurve(kind: .opponentPoints, values: sampleDates(until: min(todayRival.now, dayEnd)).map {
                    .init(date: $0, value: todayRival.points($0))
                }))
            }
        case nil:
            break
        }
        return curves
    }

    /// 相手の `date` までのポイント。相手が今日なら、今日の 4:00 からの同じ経過までの値（今より先は今の値）
    func rivalPoints(_ rival: RaceRival, at date: Date) -> Double? {
        switch rival {
        case .opponent(let opponent): opponentPoints(opponent, at: date)
        case .today: todayRival?.points(date)
        }
    }

    /// 上の行（GHO-13）の自分・相手・差。`head` は［▶］で流している線の先（nil なら今の値）。
    /// 差は自分−相手。相手が今日（ANA-05）のときは今日−この日で、時刻は今日の今まで（線の先がそれより後でも今日は今の値）
    func raceHeader(_ rival: RaceRival?, head: Date?) -> RaceHeader {
        switch rival {
        case .today:
            let time = head ?? todayRival?.now ?? now
            let mine = myPoints(until: min(time, now))
            let theirs = todayRival?.points(time)
            return RaceHeader(mine: mine, theirs: theirs, gap: theirs.map { $0 - mine })
        case .opponent(let opponent):
            let time = head ?? now
            let mine = myPoints(until: min(time, now))
            let theirs = opponentPoints(opponent, at: time)
            return RaceHeader(mine: mine, theirs: theirs, gap: RaceChartLayout.gap(mine: mine, theirs: theirs))
        case nil:
            return RaceHeader(mine: myPoints(until: min(head ?? now, now)), theirs: nil, gap: nil)
        }
    }

    /// 相手とのラップ（GHO-06）。相手が今日なら、今日の今の区間まで（自分＝この日、相手＝今日）
    func rivalLaps(_ rival: RaceRival) -> [Lap] {
        switch rival {
        case .opponent(let opponent): return laps(opponent)
        case .today:
            guard let todayRival else { return [] }
            return Laps.make(mine: sessions, opponent: todayRival.focusSeconds, dayStart: dayStart, now: min(now, todayRival.now))
        }
    }

    /// 中間地点（相手の1日分の半分）。今日はまだ1日分がないので出さない
    func rivalHalfway(_ rival: RaceRival) -> Date? {
        switch rival {
        case .opponent(let opponent): halfwayTime(opponent)
        case .today: nil
        }
    }

    /// `from`〜`to` の自分の線の色（2026-10-11 オーナー決定）：集中のカテゴリのタイマー中は集中、
    /// デトックスのカテゴリのタイマー中はデトックス、それ以外（一時停止・タイマーなし）はほか。申告した時間もタイマーと同じ。
    /// 線の点はタイマーの始まりと終わりにも置くので、点と点のあいだはどれか1つになる（真ん中の時刻で決める）
    func lineActivity(from start: Date, to end: Date) -> LineActivity {
        let middle = start.addingTimeInterval(end.timeIntervalSince(start) / 2)
        guard let segment = sessions.first(where: { $0.start <= middle && middle < $0.end }) else { return .other }
        return segment.countsAsFocus ? .focus : .detox
    }

    /// 4:00 から5分おきの時刻と、今・終わりの時刻と、`extra` の時刻。
    private func sampleDates(until end: Date, extra: [Date] = []) -> [Date] {
        var dates: Set<Date> = []
        var cursor = dayStart
        while cursor < end {
            dates.insert(cursor)
            cursor = cursor.addingTimeInterval(Self.curveStep)
        }
        dates.insert(end)
        if now > dayStart, now < end { dates.insert(now) }
        dates.formUnion(extra.filter { $0 > dayStart && $0 < end })
        return dates.sorted()
    }
}

/// 裏のグラフの相手（GHO-13）。ホームで選んだ相手か、分析で自己ベストから開いたときの今日（ANA-05、2026-10-11）。
/// 今日はホームの相手選びには出さないので、`Opponent` とは分けて持つ
enum RaceRival: Hashable {
    case opponent(Opponent)
    case today

    /// 上の行の名前（「先週」「目標」「今日」）
    var shortName: String {
        switch self {
        case .opponent(let opponent): opponent.shortName
        case .today: String(localized: "今日")
        }
    }

    /// 下の行の線の見分け方の名前
    var pickerName: String {
        switch self {
        case .opponent(let opponent): opponent.pickerName
        case .today: String(localized: "今日")
        }
    }

    /// ラップの差（前向きなら＋）。相手が今日なら今日−この日（ラップ表と同じ向き）、ほかは自分−相手
    func lapDiff(_ lap: Lap) -> Int {
        self == .today ? -lap.diff : lap.diff
    }
}

/// 上の行の値（GHO-13）
struct RaceHeader: Equatable {
    var mine: Double
    var theirs: Double?
    /// 前向きなら＋（自分−相手。相手が今日なら今日−この日）。相手がいなければ nil
    var gap: Double?
}

/// 今日を相手にしたその日のグラフ（ANA-05、2026-10-11）の今日。時刻はその日の時刻に揃えて（4:00 からの経過が同じ）持つ
struct TodayRival {
    /// 今日の今を、その日の時刻に揃えたもの
    var now: Date
    /// その日の時刻 `date` に揃えた今日のポイント・集中した時間（今より先は今の値）
    var points: (Date) -> Double
    var focusSeconds: (Date) -> Int

    init(today: HomeSnapshot, alignedTo dayStart: Date) {
        let offset = today.dayStart.timeIntervalSince(dayStart)
        let todayNow = today.now
        now = todayNow.addingTimeInterval(-offset)
        points = { today.myPoints(until: min($0.addingTimeInterval(offset), todayNow)) }
        focusSeconds = { today.sessions.focusSeconds(until: min($0.addingTimeInterval(offset), todayNow)) }
    }
}

/// 自分の線の色（GHO-13、2026-10-11）
enum LineActivity: Hashable {
    /// 集中のカテゴリのタイマー中（藍）
    case focus
    /// デトックスのカテゴリのタイマー中（青緑）
    case detox
    /// それ以外・一時停止（薄い藍）
    case other
}

extension RaceCurve {
    /// 色の分かれた1本ぶん
    struct ColoredPiece: Hashable {
        var activity: LineActivity
        var values: [Value]
    }

    /// 線を色ごとに分ける。となりどうしは境目の点を両方に入れてつなぐ
    static func split(_ values: [Value], activity: (Date, Date) -> LineActivity) -> [ColoredPiece] {
        guard values.count >= 2 else { return values.isEmpty ? [] : [ColoredPiece(activity: .other, values: values)] }
        var pieces: [ColoredPiece] = []
        for (a, b) in zip(values, values.dropFirst()) {
            let kind = activity(a.date, b.date)
            if pieces.last?.activity == kind {
                pieces[pieces.count - 1].values.append(b)
            } else {
                pieces.append(ColoredPiece(activity: kind, values: [a, b]))
            }
        }
        return pieces
    }
}
