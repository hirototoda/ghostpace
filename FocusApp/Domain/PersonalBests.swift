import Foundation

/// 自己ベストの期間（ANA-06、2026-10-06 オーナー決定）
enum BestPeriod: Hashable, CaseIterable {
    case all, month, week
}

enum BestPeriods {
    /// 期間の最初の日の 4:00。週は月曜から、月は1日から（どちらも朝4:00で区切る）。全期間は nil。
    /// `today` は今日の 4:00。今日は入れないので、期間は「最初の日 〜 昨日」
    static func start(_ period: BestPeriod, today: Date, calendar: Calendar) -> Date? {
        let back: Int
        switch period {
        case .all: return nil
        // weekday は日曜=1 … 土曜=7。月曜から何日たったか
        case .week: back = (calendar.component(.weekday, from: today) + 5) % 7
        case .month: back = calendar.component(.day, from: today) - 1
        }
        return calendar.date(byAdding: .day, value: -back, to: today)
    }

    /// 期間の日の範囲（ANA-06）。`recordDays` は記録のある過ぎた日（その日の 4:00）。
    /// 今週（今月）に記録のある日が1日もない間は、先週（先月）を期間にする（2026-10-11 オーナー決定）。
    /// 先週（先月）にも記録のある日がなければ今週（今月）のまま（「まだ記録なし」）。2週・2か月前まではさかのぼらない。
    /// 今週と今月は別々に決める
    static func range(_ period: BestPeriod, today: Date, calendar: Calendar, recordDays: [Date]) -> BestRange {
        guard let start = start(period, today: today, calendar: calendar) else { return BestRange(start: nil, end: today) }
        let current = BestRange(start: start, end: today)
        guard !recordDays.contains(where: current.contains) else { return current }
        let previousStart = switch period {
        case .all: Date?.none
        case .week: calendar.date(byAdding: .day, value: -7, to: start)
        case .month: calendar.date(byAdding: .month, value: -1, to: start)
        }
        guard let previousStart else { return current }
        let previous = BestRange(start: previousStart, end: start, isFallback: true)
        return recordDays.contains(where: previous.contains) ? previous : current
    }
}

/// 期間の日の範囲：`start` の日 〜 `end` の前の日（どちらもその日の 4:00）。全期間は `start` が nil
struct BestRange: Hashable {
    var start: Date?
    var end: Date
    /// 今週（今月）に記録のある日がないので、先週（先月）に代えた
    var isFallback = false

    func contains(_ day: Date) -> Bool {
        (start.map { day >= $0 } ?? true) && day < end
    }
}

/// 期間の中の自己ベスト：一番多い1日のポイントとその日の 4:00、集中した時間のベスト（集中した日がなければ nil）
struct PeriodBest: Hashable {
    var points: Double
    var pointsDay: Date
    var focus: PersonalBest?
    /// 今週（今月）に記録のある日がないので、先週（先月）の日で出している（切り替えの文字「先週」「先月」、2026-10-11）
    var isFallback = false
}

/// ラップ表の比べる相手（ANA-06、2026-10-07 オーナー決定）。どれも選んでいる期間の記録のある日から作る
enum LapTarget: Hashable, CaseIterable {
    /// ポイントのベストの日
    case bestDay
    /// 記録のある日の、その時刻までの平均
    case average
    /// 区間ベストをつないだ1日（ANA-11）
    case sectionBest
}

/// 自己ベストのラップ表の1行（ANA-06）：2時間の区間ごとの、今日と相手（ベストの日・平均・区間ベスト）
struct BestLapRow: Identifiable, Hashable {
    /// 今日の区間
    var section: DateInterval
    /// その区間で増えた今日のポイント（今の区間は今まで）。まだ来ていない区間は nil
    var today: Double?
    /// その区間の終わり（今の区間は今）までにたまった今日のポイント
    var todayTotal: Double?
    /// その区間で増えた相手のポイント（今の区間は今日と同じ時刻まで）
    var theirs: Double
    var theirsTotal: Double
    var isCurrent: Bool
    /// その区間の区間ベスト（数え直す前の、実際の1日の値。★に使う、ANA-11）。なければ nil
    var record: Double? = nil

    var id: Date { section.start }
    /// 累計の差（今日−相手）。表に出る2つの数字（0.1pt）の差なので、見た目の引き算と合う。まだ来ていない区間は nil
    var totalGap: Double? { todayTotal.map { BestLaps.shownGap($0, theirsTotal) } }
    /// 区間の数字を赤にするか（今日が相手を上回った）
    var todayWins: Bool { today.map { BestLaps.beats($0, theirs) } ?? false }
    /// 累計の数字と差を赤にするか
    var totalWins: Bool { todayTotal.map { BestLaps.beats($0, theirsTotal) } ?? false }
    /// 金の ★：今日の区間が区間ベストを表示（0.1pt）で超えた。今日が 0.0 以下なら付けない（ANA-11）
    var gold: Bool {
        guard let today, let record else { return false }
        return BestLaps.beats(today, 0) && BestLaps.beats(today, record)
    }
}

/// 今日と相手の比べ（ANA-06）
struct BestComparison: Hashable {
    /// 今日の今までのポイント
    var today: Double
    /// 相手の同じ時刻（4:00 からの経過で揃える）までのポイント
    var theirsAtSameTime: Double
    var rows: [BestLapRow]
    /// 相手を作った日の数（平均の見出し「平均（12日）」）
    var days = 1

    var gap: Double { BestLaps.shownGap(today, theirsAtSameTime) }
    var wins: Bool { BestLaps.beats(today, theirsAtSameTime) }
}

enum BestLaps {
    /// 2時間ごとのラップ表。`today` はその時刻までにたまった今日のポイント、`theirs` は 4:00 からの経過までの相手のポイント。
    /// 今の区間は相手も同じ時刻まで、まだ来ていない区間は相手だけ。どちらも0の区間は省く。
    /// `records` は区間ごとの区間ベスト（12個。★に使う）
    static func make(today: (Date) -> Double, todayStart: Date, now: Date,
                     theirs: (TimeInterval) -> Double, records: [Double] = []) -> [BestLapRow] {
        Laps.sections(dayStart: todayStart).enumerated().compactMap { index, section in
            let start = section.start.timeIntervalSince(todayStart)
            let record = records.indices.contains(index) ? records[index] : nil
            let row: BestLapRow
            if section.start >= now {
                let end = start + Laps.length
                row = BestLapRow(section: section, today: nil, todayTotal: nil,
                                 theirs: theirs(end) - theirs(start), theirsTotal: theirs(end), isCurrent: false, record: record)
            } else {
                let end = min(section.end, now)
                let offset = end.timeIntervalSince(todayStart)
                row = BestLapRow(section: section, today: today(end) - today(section.start), todayTotal: today(end),
                                 theirs: theirs(offset) - theirs(start), theirsTotal: theirs(offset),
                                 isCurrent: now < section.end, record: record)
            }
            return shown(row.today ?? 0) == 0 && shown(row.theirs) == 0 ? nil : row
        }
    }

    /// 表示（0.1pt）で上回っているか。同じに見えるなら false（赤にしない）
    static func beats(_ mine: Double, _ theirs: Double) -> Bool {
        shown(mine) > shown(theirs)
    }

    /// 表示（0.1pt）どうしの差。差だけ別に丸めると「12.0 と 12.0 で +0.1」のようにずれるため
    static func shownGap(_ mine: Double, _ theirs: Double) -> Double {
        (shown(mine) - shown(theirs)) / 10
    }

    /// 表示（0.1pt）の値を10倍した整数。ホームのラップ（GHO-06）の 0.0 の判定にも使う
    static func shown(_ points: Double) -> Double { (points * 10).rounded() }
}
