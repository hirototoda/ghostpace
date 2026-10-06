import Foundation

/// 一時停止の区間（TMR-03）。end が nil なら停止中。
struct PauseInterval: Codable, Hashable {
    var start: Date
    var end: Date?

    static func encode(_ pauses: [PauseInterval]) -> Data {
        (try? JSONEncoder().encode(pauses)) ?? Data("[]".utf8)
    }

    /// 読めなければ空（記録そのものは読めるようにする）。
    static func decode(_ data: Data) -> [PauseInterval] {
        (try? JSONDecoder().decode([PauseInterval].self, from: data)) ?? []
    }
}

enum SessionError: Error, Equatable {
    /// 終了時刻が開始以前、または今より後
    case invalidEnd
}

/// タイマーの記録1件（docs/product/features/focus-timer.md）。
struct FocusSession: Identifiable, Hashable {
    /// 一時停止を除いてこれより短いセッションは記録しない（2026-09-30 決定）
    static let minimumSeconds: TimeInterval = 60
    /// 止め忘れの疑い：予定をこれ以上超過
    static let forgotOvertime: TimeInterval = 30 * 60
    /// 止め忘れの疑い：ストップウォッチでこれより長い
    static let forgotStopwatch: TimeInterval = 3 * 3600

    var id: UUID
    /// 開始した日（4:00 をまたいでも開始した日のまま）
    var dayKey: String
    var category: CategoryOption
    var project: ProjectOption?
    var planBlockId: UUID?
    var startAt: Date
    /// nil なら実行中
    var endAt: Date?
    /// 計画ブロックから開始：ブロックの終了時刻。一時停止しても動かない
    var plannedEndAt: Date?
    /// 計画外で長さを決めた：長さ。一時停止した分だけ終わりが後ろにずれる
    var plannedDurationSec: Int?
    var pauses: [PauseInterval] = []
    var originalEndAt: Date?
    /// 押し忘れの申告（TMR-13）。点は0.8倍
    var isDeclared = false

    var title: String { project?.name ?? category.name }
    var isCountdown: Bool { plannedEndAt != nil || plannedDurationSec != nil }
    var isRunning: Bool { endAt == nil }
    var isPaused: Bool { isRunning && pauses.last.map { $0.end == nil } == true }
    var pauseCount: Int { pauses.count }

    /// 区間の終わり（終了していれば終了時刻、なければ now）。
    private func end(at now: Date) -> Date { endAt ?? now }

    /// `until` までに一時停止していた秒数。
    private func pausedDuration(until date: Date) -> TimeInterval {
        pauses.reduce(0) { total, pause in
            let from = max(pause.start, startAt)
            let to = min(pause.end ?? date, date)
            return total + max(0, to.timeIntervalSince(from))
        }
    }

    /// 一時停止を除いた長さ（秒、小数あり）。
    func activeDuration(at now: Date) -> TimeInterval {
        let end = end(at: now)
        guard end > startAt else { return 0 }
        return max(0, end.timeIntervalSince(startAt) - pausedDuration(until: end))
    }

    func activeSeconds(at now: Date) -> Int { Int(activeDuration(at: now)) }

    /// 一時停止で区切った区間。ホームの集計と対戦の曲線に使う。
    func activeSegments(now: Date) -> [TimeSegment] {
        let end = end(at: now)
        var segments: [TimeSegment] = []
        var cursor = startAt
        let group = DetoxGroup.of(category)
        func append(until segmentEnd: Date) {
            segments.append(TimeSegment(start: cursor, end: segmentEnd, countsAsFocus: category.countsAsFocus,
                                        detoxGroup: group, isDeclared: isDeclared))
        }
        for pause in pauses.sorted(by: { $0.start < $1.start }) {
            let pauseStart = min(max(pause.start, cursor), end)
            if pauseStart > cursor { append(until: pauseStart) }
            cursor = max(cursor, min(pause.end ?? end, end))
        }
        if end > cursor { append(until: end) }
        return segments
    }

    /// 予定の終了時刻。ストップウォッチは nil。
    func plannedEnd(at now: Date) -> Date? {
        if let plannedEndAt { return plannedEndAt }
        guard let plannedDurationSec else { return nil }
        return startAt.addingTimeInterval(Double(plannedDurationSec) + pausedDuration(until: end(at: now)))
    }

    /// カウントダウンの残り。マイナスなら超過。
    func remainingSeconds(at now: Date) -> Int? {
        plannedEnd(at: now).map { Int($0.timeIntervalSince(now).rounded(.up)) }
    }

    /// 止め忘れの疑い。予定を30分以上超過／ストップウォッチで3時間超／開始した日の翌日4:00を過ぎた。
    func needsEndTimeCheck(at now: Date, calendar: Calendar) -> Bool {
        if let plannedEnd = plannedEnd(at: now), now.timeIntervalSince(plannedEnd) >= Self.forgotOvertime {
            return true
        }
        if !isCountdown, activeDuration(at: now) > Self.forgotStopwatch {
            return true
        }
        let dayStart = DayBoundary.dayStart(containing: startAt, calendar: calendar)
        let nextDayStart = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86400)
        return now >= nextDayStart
    }

    /// 終了した値を作る（TMR-08）。`reportedEnd` が now より前なら元の終了時刻（now）を残す。
    /// セッションは一時停止の途中では終わらない：終わりが停止の中なら、その停止の開始を終了にし、その停止は捨てる。
    func ending(at now: Date, reportedEnd: Date) throws -> FocusSession {
        guard reportedEnd > startAt, reportedEnd <= now else { throw SessionError.invalidEnd }
        var ended = self
        let end = endAvoidingPause(reportedEnd, openPauseEnd: now)
        ended.pauses = pauses.filter { $0.start < end }
        ended.endAt = end
        if reportedEnd < now {
            ended.originalEndAt = originalEndAt ?? now
        }
        return ended
    }

    /// セッションは一時停止の途中では終わらない：`end` が一時停止の中なら、その停止の開始を返す。
    /// `openPauseEnd` は終わっていない一時停止の終わりとして扱う時刻。
    private func endAvoidingPause(_ end: Date, openPauseEnd: Date) -> Date {
        guard let pause = pauses.first(where: { $0.start <= end && end <= ($0.end ?? openPauseEnd) }) else { return end }
        return max(pause.start, startAt)
    }

    /// 早めた終わり（一時停止の途中なら、その停止の開始）。
    func endIfShortened(to newEnd: Date) -> Date {
        endAvoidingPause(newEnd, openPauseEnd: endAt ?? newEnd)
    }

    /// 終わった記録の終了時刻を早める（タイムライン、TMR-08・TML-04）。延ばせない。
    /// 元の終了時刻は、最初に直す前のものを残す。1分未満になっても記録は残す。
    func shortened(to newEnd: Date) throws -> FocusSession {
        guard let endAt, newEnd > startAt, newEnd < endAt else { throw SessionError.invalidEnd }
        let end = endIfShortened(to: newEnd)
        guard end > startAt else { throw SessionError.invalidEnd }
        var shortened = self
        shortened.pauses = pauses.filter { $0.start < end }
        shortened.endAt = end
        shortened.originalEndAt = originalEndAt ?? endAt
        return shortened
    }
}

/// 実行中のタイマーの表示内容。
struct RunningTimer: Identifiable, Hashable {
    var session: FocusSession
    /// このセッションより前の、同じ日の集中時間
    var focusSecondsBefore: Int
    var ghost: GhostSummary?
    /// 目標のゴースト（GHO-10）
    var goal: GoalGhost? = nil
    /// その日の計画ブロック（計画の時刻での切り替え、TMR-11）。計画なし日は空
    var planBlocks: [PlanBlockSummary] = []

    var id: UUID { session.id }
    var title: String { session.title }
    var categoryName: String { session.category.name }
    var countsAsFocus: Bool { session.category.countsAsFocus }

    func elapsedSeconds(at date: Date) -> Int { session.activeSeconds(at: date) }

    /// カウントダウンの残り。マイナスなら超過。nil ならストップウォッチ（TMR-07）。
    func remainingSeconds(at date: Date) -> Int? { session.remainingSeconds(at: date) }

    func ghostDiffSeconds(at date: Date) -> Int? {
        opponentDiffSeconds(.lastWeek, at: date)
    }

    /// 選んだ相手との差。相手がいなければ nil
    func opponentDiffSeconds(_ opponent: Opponent, at date: Date) -> Int? {
        let mine = focusSecondsBefore + (countsAsFocus ? elapsedSeconds(at: date) : 0)
        switch opponent {
        case .lastWeek: return ghost.map { mine - $0.focusSeconds(at: date) }
        case .goal: return goal.map { mine - $0.focusSeconds(at: date) }
        }
    }

    /// 計画外のタイマー中に始まった、今の計画ブロック（TMR-11）。あればタイマー画面に「〜に切り替える」を出す。
    /// 計画外を始めた時点ですでに始まっていたブロック（わざと計画外にした）と、ゲーム・SNS の時間（BLK-10）は出さない
    /// 2026-10-06 から計画ブロックのタイマーも：遅れて始めて終わりをずらした間に次のブロックの時刻が来たとき（TMR-15）
    func switchableBlock(at now: Date) -> PlanBlockSummary? {
        planBlocks.first {
            $0.id != session.planBlockId && $0.start > session.startAt && $0.start <= now && now < $0.end && !$0.category.isUnblock
        }
    }

    /// 円に出す相手：選んだ相手がいればそれ、いなければいる方（home.md）
    func effectiveOpponent(_ preferred: Opponent) -> Opponent? {
        let available = Opponent.allCases.filter { opponentDiffSeconds($0, at: session.startAt) != nil }
        return available.contains(preferred) ? preferred : available.first
    }
}
