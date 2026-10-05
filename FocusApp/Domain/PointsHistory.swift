import Foundation

/// ポイントの推移（ANA-04）の1日分。過去の日もホームと同じ計算で、その日の記録から毎回数え直す（保存しない）
struct DayPoints: Identifiable, Hashable {
    /// その日の 4:00
    var dayStart: Date
    /// その日の合計（今日は今まで）。タイマーの記録・計画・保存した睡眠のどれもない日は nil（記録なし）
    var points: Double?
    /// 先週の同じ曜日（今日は同じ時刻まで）。丸1日分のブロックの記録がない日など、比べられない日は nil
    var lastWeek: Double?
    var isToday: Bool

    var id: Date { dayStart }

    /// 先週の同じ曜日との差（自分−先週）。どちらかがない日は nil
    var gap: Double? {
        guard let points, let lastWeek else { return nil }
        return points - lastWeek
    }
}

enum PointsHistory {
    /// 一覧の行に出す平均。今日（途中）と記録のない日を除く
    static func average(_ days: [DayPoints]) -> Double? {
        let values = days.filter { !$0.isToday }.compactMap(\.points)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}
