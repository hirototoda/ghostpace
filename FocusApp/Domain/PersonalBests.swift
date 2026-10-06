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
}

/// 期間の中の自己ベスト：一番多い1日のポイントとその日の 4:00、集中した時間のベスト（集中した日がなければ nil）
struct PeriodBest: Hashable {
    var points: Double
    var pointsDay: Date
    var focus: PersonalBest?
}

/// 自己ベストのラップ表の1行（ANA-06）：2時間の区間ごとの、今日とポイントのベストの日
struct BestLapRow: Identifiable, Hashable {
    /// 今日の区間
    var section: DateInterval
    /// その区間で増えた今日のポイント（今の区間は今まで）。まだ来ていない区間は nil
    var today: Double?
    /// その区間の終わり（今の区間は今）までにたまった今日のポイント
    var todayTotal: Double?
    /// その区間で増えたベストの日のポイント（今の区間は今日と同じ時刻まで）
    var best: Double
    var bestTotal: Double
    var isCurrent: Bool

    var id: Date { section.start }
    /// 累計の差（今日−ベストの日）。まだ来ていない区間は nil
    var totalGap: Double? { todayTotal.map { $0 - bestTotal } }
}

/// 今日とベストの日の比べ（ANA-06）
struct BestComparison: Hashable {
    /// 今日の今までのポイント
    var today: Double
    /// ベストの日の同じ時刻（4:00 からの経過で揃える）までのポイント
    var bestAtSameTime: Double
    var rows: [BestLapRow]

    var gap: Double { today - bestAtSameTime }
}

enum BestLaps {
    /// 2時間ごとのラップ表。`today`・`best` はその時刻までにたまったポイント。時刻は 4:00 からの経過で揃える。
    /// 今の区間はベストの日も同じ時刻まで、まだ来ていない区間はベストの日だけ。どちらも0の区間は省く
    static func make(today: (Date) -> Double, todayStart: Date, now: Date,
                     best: (Date) -> Double, bestStart: Date) -> [BestLapRow] {
        Laps.sections(dayStart: todayStart).compactMap { section in
            let offset = section.start.timeIntervalSince(todayStart)
            let bestSectionStart = bestStart.addingTimeInterval(offset)
            let row: BestLapRow
            if section.start >= now {
                let end = bestSectionStart.addingTimeInterval(Laps.length)
                row = BestLapRow(section: section, today: nil, todayTotal: nil,
                                 best: best(end) - best(bestSectionStart), bestTotal: best(end), isCurrent: false)
            } else {
                let end = min(section.end, now)
                let bestEnd = bestStart.addingTimeInterval(end.timeIntervalSince(todayStart))
                row = BestLapRow(section: section, today: today(end) - today(section.start), todayTotal: today(end),
                                 best: best(bestEnd) - best(bestSectionStart), bestTotal: best(bestEnd),
                                 isCurrent: now < section.end)
            }
            return shown(row.today ?? 0) == 0 && shown(row.best) == 0 ? nil : row
        }
    }

    /// 表示（0.1pt）で上回っているか。同じに見えるなら false（赤にしない）
    static func beats(_ mine: Double, _ theirs: Double) -> Bool {
        shown(mine) > shown(theirs)
    }

    private static func shown(_ points: Double) -> Double { (points * 10).rounded() }
}
