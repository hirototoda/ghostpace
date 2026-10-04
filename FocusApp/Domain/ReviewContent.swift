import Foundation

/// 夜の振り返りの中身（REV-01、docs/product/features/review.md）。数字だけで、保存はしない。
struct ReviewContent {
    struct CategoryTotal: Hashable, Identifiable {
        var id: UUID
        var name: String
        var seconds: Int
        var countsAsFocus: Bool
    }

    struct OpponentDiff: Hashable {
        var opponent: Opponent
        /// 相手がこの時刻までに集中した時間
        var theirSeconds: Int
        /// 今の自分との差（プラスならリード）
        var diffSeconds: Int
    }

    /// 先週の同じ曜日の自分との勝ち負け（GHO-04。2026-10-02 オーナー決定：集中・デトックス・ポイントの3つ、総合はなし。
    /// 2026-10-03 にデトックスを「開けた時間」に変更、DTX-05）
    struct Verdict: Hashable, Identifiable {
        enum Item: String, CaseIterable, Hashable {
            case focus, opened, points

            var label: String {
                switch self {
                case .focus: String(localized: "集中")
                case .opened: String(localized: "開けた時間")
                case .points: String(localized: "ポイント")
                }
            }
        }

        enum Result: Hashable {
            case win, lose, draw
            /// 先週の記録が足りなくて比べられない（使い始めの週の開けた時間・ポイント）
            case noRecord
        }

        var item: Item
        var mine: Double
        var theirs: Double?
        var id: Item { item }

        var result: Result {
            guard let theirs else { return .noRecord }
            // 表示と同じ細かさでそろえて比べる：時間は分（1分未満は切り捨て）、ポイントは小数1桁
            let a = shown(mine), b = shown(theirs)
            // 開けた時間は少ないほうが勝ち（DTX-05）
            let (better, worse) = item == .opened ? (a < b, a > b) : (a > b, a < b)
            return better ? .win : worse ? .lose : .draw
        }

        private func shown(_ value: Double) -> Double {
            item == .points ? (value * 10).rounded() : (value / 60).rounded(.down)
        }
    }

    var dayStart: Date
    var focusSeconds: Int
    /// 今日開けた時間と回数（ホームと同じ、DTX-05）。今日ブロックが一度も効いていなければ nil
    var opened: OpenedTime?
    var categories: [CategoryTotal]
    var opponents: [OpponentDiff]
    /// 先週の自分との勝ち負け。先週の記録がまったくない日は空
    var verdicts: [Verdict]
    /// 朝の計画とのズレ（15分以上、終わったブロックだけ、最大2つ）
    var gaps: [ReviewGap]
    var isNoPlanDay: Bool

    /// - snapshot: 朝の計画（確定時の写し）。計画なし日は nil
    static func make(home: HomeSnapshot, sessions: [FocusSession], snapshot: [PlanSnapshotBlock]?) -> ReviewContent {
        let now = home.now
        var totals: [UUID: CategoryTotal] = [:]
        var order: [UUID] = []
        for session in sessions {
            let seconds = session.activeSeconds(at: now)
            guard seconds > 0 else { continue }
            if totals[session.category.id] == nil {
                order.append(session.category.id)
                totals[session.category.id] = CategoryTotal(id: session.category.id, name: session.category.name, seconds: 0,
                                                            countsAsFocus: session.category.countsAsFocus)
            }
            totals[session.category.id]?.seconds += seconds
        }
        let categories = order.compactMap { totals[$0] }.enumerated()
            .sorted { $0.element.seconds != $1.element.seconds ? $0.element.seconds > $1.element.seconds : $0.offset < $1.offset }
            .map(\.element)
        // 先週の自分は勝ち負けの表に出すので、ここは目標との差だけ
        let opponents = [Opponent.goal].compactMap { opponent -> OpponentDiff? in
            guard let theirs = home.opponentFocusSeconds(opponent), let diff = home.opponentDiffSeconds(opponent) else { return nil }
            return OpponentDiff(opponent: opponent, theirSeconds: theirs, diffSeconds: diff)
        }
        // 先週のタイマーの記録がなくても、ブロックの記録が丸1日分あれば比べる（先週の集中は0分）
        let hasLastWeek = home.ghost != nil || home.ghostDetox != nil
        let opened = home.opened
        // 開けた時間の行は、今日ブロックが一度も効いていなければ出さない。
        // 先週のその日にブロックが一度も効いていなければ「先週の記録なし」（何もしなくても0分で勝ててしまうため）
        let lastWeekOpened = home.ghostDetox.flatMap { $0.wasBlocking(until: now) ? Double($0.openedSeconds(until: now)) : nil }
        let openedVerdict = opened.map { Verdict(item: .opened, mine: Double($0.seconds), theirs: lastWeekOpened) }
        let verdicts: [Verdict] = !hasLastWeek ? [] : [
            Verdict(item: .focus, mine: Double(home.focusSeconds), theirs: Double(home.ghostFocusSeconds ?? 0)),
            openedVerdict,
            Verdict(item: .points, mine: home.points, theirs: home.opponentPoints(.lastWeek, at: now)),
        ].compactMap { $0 }
        return ReviewContent(
            dayStart: home.dayStart, focusSeconds: home.focusSeconds, opened: opened,
            categories: categories, opponents: opponents, verdicts: verdicts,
            gaps: snapshot.map { ReviewGaps.largest(snapshot: $0, sessions: sessions, now: now) } ?? [],
            isNoPlanDay: snapshot == nil)
    }
}
