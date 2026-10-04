import Foundation

/// 進み方が一定の区間。`rate` は1秒あたりに増える集中の秒数（1なら、その間ずっと集中）。
struct PaceSegment: Hashable {
    var start: Date
    var end: Date
    var rate: Double
    /// 計画の集中ブロックそのもの。ポイントで「続けて1回」とみなすのはこれだけ（目標を足した分は休みを挟むとみなす、GHO-14）
    var fromPlan = false

    func seconds(until date: Date) -> Double {
        max(0, min(end, date).timeIntervalSince(start)) * rate
    }
}

/// 目標のゴースト（GHO-10、docs/product/features/ghost-race.md）。今日の目標時間を、計画どおりに進める。
/// - 集中の計画ブロックの時間帯に、その長さだけ進む
/// - 目標が計画より多い分は、起きている時間（その朝に起きた時刻〜その夜に寝る時刻）の、ブロックのない時間に均等に足す（Q11、2026-10-03）
///   寝る時刻が分からなければ 20:00 まで、起きた時刻が分からなければ最初の計画ブロックから。最後のブロックが遅ければそこまで
///   空き時間より多い分は、空き時間をすべて集中にし、残りは範囲の終わりの後に続ける（Q18）
/// - 目標は計画の集中の合計より少なくできない（Q12）
/// - 計画なし日は 8:00〜20:00 に均等に進む。12時間を超えたら前後に同じだけ広げ、その間ずっと集中（Q13）
struct GoalGhost: Hashable {
    /// 実際に使う目標（計画の集中の合計を下回らない）
    var goalSeconds: Int
    var segments: [PaceSegment]

    static let noPlanStartHour = 8
    static let noPlanEndHour = 20

    /// - plan: 今の計画。nil かブロックがなければ計画なし日として扱う
    /// - goalSeconds: 手で決めた目標。nil なら計画の集中の合計
    /// - sleep: [その朝に終わった睡眠, その夜の睡眠]。目標の多い分を足す範囲（起きている時間）に使う。
    ///   1つだけならその朝の睡眠（寝る時刻は分からない）。アプリでは設定の時刻で補うので、いつも2つ
    init(plan: PlanDraft?, goalSeconds: Int?, sleep: [DateInterval], dayStart: Date, calendar: Calendar) {
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86400)
        let allBlocks = plan?.sortedBlocks ?? []
        // ゲーム・SNS の時間（BLK-10）は目標の範囲を決めるのに使わない。ただし空き時間にはしない（そこに目標を足さない）
        let blocks = allBlocks.filter { !$0.isUnblock }
        if blocks.isEmpty {
            let goal = max(goalSeconds ?? 0, 0)
            self.goalSeconds = goal
            segments = Self.noPlanSegments(goal: goal, dayStart: dayStart, dayEnd: dayEnd, calendar: calendar)
            return
        }

        let planned = blocks.filter(\.category.countsAsFocus).reduce(0) { $0 + $1.minutes * 60 }
        let goal = max(goalSeconds ?? planned, planned)
        self.goalSeconds = goal
        var segments = blocks.filter(\.category.countsAsFocus).map { PaceSegment(start: $0.start, end: $0.end, rate: 1, fromPlan: true) }

        var extra = Double(goal - planned)
        if extra > 0 {
            let awake = Self.awake(sleep: sleep, dayStart: dayStart, dayEnd: dayEnd)
            let rangeStart = awake.wake ?? blocks[0].start
            let lastPlanned = blocks.map(\.end).max() ?? rangeStart
            let rangeEnd = max(awake.bed ?? Self.time(hour: Self.noPlanEndHour, dayStart: dayStart, calendar: calendar), lastPlanned)
            // ブロック（ゲーム・SNS の時間も）と、寝ている間には足さない
            let busy = (allBlocks.map { DateInterval(start: $0.start, end: $0.end) } + (awake.bed == nil ? [] : sleep))
                .sorted { $0.start < $1.start }
            var gaps: [(Date, Date)] = []
            var cursor = rangeStart
            for interval in busy where interval.end > cursor && interval.start < rangeEnd {
                if interval.start > cursor { gaps.append((cursor, interval.start)) }
                cursor = max(cursor, interval.end)
            }
            if cursor < rangeEnd { gaps.append((cursor, rangeEnd)) }
            let totalGap = gaps.reduce(0) { $0 + $1.1.timeIntervalSince($1.0) }
            let rate = totalGap > 0 ? min(extra / totalGap, 1) : 0
            if rate > 0 {
                segments += gaps.map { PaceSegment(start: $0.0, end: $0.1, rate: rate) }
                extra -= totalGap * rate
            }
            // 起きる前には入れない（起きた時刻が 20:00 より後で、寝る時刻が分からない日）
            let overflowStart = max(rangeEnd, rangeStart)
            if extra > 0.5, overflowStart < dayEnd {
                segments.append(PaceSegment(start: overflowStart, end: min(overflowStart.addingTimeInterval(extra), dayEnd), rate: 1))
            }
        }
        self.segments = segments
    }

    private static func noPlanSegments(goal: Int, dayStart: Date, dayEnd: Date, calendar: Calendar) -> [PaceSegment] {
        guard goal > 0 else { return [] }
        let start = time(hour: noPlanStartHour, dayStart: dayStart, calendar: calendar)
        let end = time(hour: noPlanEndHour, dayStart: dayStart, calendar: calendar)
        let window = end.timeIntervalSince(start)
        if Double(goal) <= window {
            return [PaceSegment(start: start, end: end, rate: Double(goal) / window)]
        }
        // 前後に同じだけ広げる。日の端にかかったら、はみ出した分を反対側に足す
        let length = min(Double(goal), dayEnd.timeIntervalSince(dayStart))
        var from = start.addingTimeInterval(-(Double(goal) - window) / 2)
        if from < dayStart { from = dayStart }
        if from.addingTimeInterval(length) > dayEnd { from = dayEnd.addingTimeInterval(-length) }
        return [PaceSegment(start: from, end: from.addingTimeInterval(length), rate: 1)]
    }

    /// その日の hour 時（4:00〜翌3:59 のどこか）
    private static func time(hour: Int, dayStart: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .hour, value: hour - DayBoundary.hour, to: dayStart) ?? dayStart
    }

    /// その朝に起きた時刻と、その夜に寝る時刻（その日の中に収める）。寝る時刻が起きた時刻より前なら、どちらも分からない扱い
    private static func awake(sleep: [DateInterval], dayStart: Date, dayEnd: Date) -> (wake: Date?, bed: Date?) {
        let wake = sleep.first.map { min(max($0.end, dayStart), dayEnd) }
        let bed = sleep.dropFirst().first.map { min(max($0.start, dayStart), dayEnd) }
        if let wake, let bed, bed <= wake { return (nil, nil) }
        return (wake, bed)
    }

    func focusSeconds(at date: Date) -> Int {
        Int(segments.reduce(0) { $0 + $1.seconds(until: date) }.rounded(.down))
    }

    var wholeDayFocusSeconds: Int { focusSeconds(at: .distantFuture) }

    /// 目標のゴーストが開ける2つの時刻（0分だけ開ける、GHO-10）：起きている時間（その朝に起きた時刻〜その夜に寝る時刻）を3等分したところ。
    /// `sleep` は [その朝に終わった睡眠, その夜の睡眠] の順。起きている時間が求められなければ 4:00〜翌4:00 を3等分する（Q32）
    static func openTimes(sleep: [DateInterval], dayStart: Date, dayEnd: Date) -> [Date] {
        let awake = awake(sleep: sleep, dayStart: dayStart, dayEnd: dayEnd)
        var wake = awake.wake ?? dayStart, bed = awake.bed ?? dayEnd
        if bed <= wake { (wake, bed) = (dayStart, dayEnd) }
        let third = bed.timeIntervalSince(wake) / 3
        return [wake.addingTimeInterval(third), wake.addingTimeInterval(2 * third)]
    }

    /// 目標が0なら nil（相手にしない）
    var nonEmpty: GoalGhost? { goalSeconds > 0 ? self : nil }
}
