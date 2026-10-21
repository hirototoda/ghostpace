import Foundation

/// 手動の記録（TMR-13、docs/product/features/focus-timer.md「手動の記録」）。記録できるかを決める。
/// 記録する時間は「アプリを使っていない時間」だけ：ブロックが効いていて、開けていない・ゲーム・SNS の時間でない・
/// ほかの記録や睡眠と重ならない。端が触れるだけは重なりにしない。
/// 保存の印は今までの「押し忘れの申告」と同じ `FocusSession.isDeclared`（保存データの形は変えない）
enum ManualRecord {
    enum Problem: Hashable {
        /// 終わりが開始の1分後より前
        case tooShort
        /// 今より後に終わる
        case notEnded
        /// 始めた日が今日・昨日（朝4:00区切り）でない
        case outOfRange
        /// ブロックが効いていない（DTX-03 の表の一番上の行：始める前・選択が読めない・許可が外れた）
        case notBlocking
        /// 長押しで開けていた・ゲーム・SNS の時間を過ぎても開いていた（DTX-05 の開けた時間）
        case opened
        /// ゲーム・SNS の時間（予定の中、BLK-10）
        case gameTime
        /// ほかの記録（実行中のタイマーも）と重なる
        case overlapsRecord
        /// 寝ている時間（その日の睡眠。設定の時刻で仮に数えている間も）と重なる
        case overlapsSleep

        var message: String {
            switch self {
            case .tooShort: String(localized: "終わりは開始の1分以上あとにしてください")
            case .notEnded: String(localized: "終わりは今より前にしてください")
            case .outOfRange: String(localized: "記録できるのは今日と昨日の分だけです")
            case .notBlocking: String(localized: "この時間はブロックが効いていなかったので記録できません")
            case .opened: String(localized: "この時間に開けていたので記録できません")
            case .gameTime: String(localized: "ゲーム・SNS の時間は記録できません")
            case .overlapsRecord: String(localized: "ほかの記録と重なっています")
            case .overlapsSleep: String(localized: "寝ていた時間と重なっています（睡眠の時刻を直すと記録できます）")
            }
        }
    }

    /// タイマーの画面の「前の分を足す」を出すのは、ブロックの開始からこれ以上たって始めたときだけ
    static let lateStartMinimum: TimeInterval = 5 * 60

    /// 判定の材料（AppModel が今日と昨日の分を集める）
    struct Context {
        var now: Date
        /// 記録できる日（今日と昨日の dayKey）
        var dayKeys: Set<String>
        var calendar: Calendar
        /// ブロックの記録（すべて）
        var events: [BlockEvent]
        /// 確定した計画のゲーム・SNS の時間（予定）
        var gameWindows: [DateInterval]
        /// ほかの記録（実行中のタイマーも）
        var sessions: [FocusSession]
        /// 寝ている時間（昨日・今日の朝の睡眠と、今夜の睡眠）
        var sleep: [DateInterval]
    }

    /// `start`〜`end` を手動で記録できないときの理由。できるなら nil。
    /// `excluding` は直している記録（自分とは比べない）
    static func problem(start: Date, end: Date, excluding id: UUID? = nil, context: Context) -> Problem? {
        if end.timeIntervalSince(start) < FocusSession.minimumSeconds { return .tooShort }
        if end > context.now { return .notEnded }
        if !context.dayKeys.contains(DayBoundary.dayKey(containing: start, calendar: context.calendar)) { return .outOfRange }
        if let problem = blockProblem(start: start, end: end, context: context) { return problem }
        let others = context.sessions.filter { $0.id != id }
        if others.contains(where: { overlaps(start, end, $0.startAt, $0.endAt ?? .distantFuture) }) { return .overlapsRecord }
        if context.sleep.contains(where: { overlaps(start, end, $0.start, $0.end) }) { return .overlapsSleep }
        return nil
    }

    /// ブロックの状態（BlockTimeline。デトックスの区間 DetoxDay と同じ判定）で、効いていない・開けていた・ゲーム・SNS の時間か
    private static func blockProblem(start: Date, end: Date, context: Context) -> Problem? {
        let state = BlockTimeline(events: context.events)
        var bounds: Set<Date> = [start, end]
        for interval in state.boundaries + context.gameWindows {
            for date in [interval.start, interval.end] where date > start && date < end { bounds.insert(date) }
        }
        let sorted = bounds.sorted()
        var found: Set<Problem> = []
        for (from, to) in zip(sorted, sorted.dropFirst()) where to > from {
            let mid = from.addingTimeInterval(to.timeIntervalSince(from) / 2)
            if !state.isCounted(at: mid, plannedGame: context.gameWindows) {
                found.insert(state.isOpenedByUser(at: mid, plannedGame: context.gameWindows) ? .opened : .notBlocking)
            } else if context.gameWindows.contains(where: { $0.start <= mid && mid < $0.end }) {
                found.insert(.gameTime)
            }
        }
        return [Problem.notBlocking, .opened, .gameTime].first(where: found.contains)
    }

    /// 重なるか（端が触れるだけは重ならない）
    private static func overlaps(_ a: Date, _ b: Date, _ c: Date, _ d: Date) -> Bool {
        a < d && c < b
    }

    /// 計画のタブの初めの時刻：ブロックの時刻のうち記録のない一番長い部分（記録がなければブロックの時刻そのまま）。
    /// ほかのブロック・計画外の記録も「記録のある部分」。秒は内側へ1分に丸め、1分に満たなければ nil
    static func longestGap(in block: DateInterval, sessions: [FocusSession], now: Date) -> DateInterval? {
        let taken = sessions.map { DateInterval(start: $0.startAt, end: max($0.startAt, $0.endAt ?? now)) }
            .filter { $0.start < block.end && block.start < $0.end }
            .sorted { $0.start < $1.start }
        var gaps: [DateInterval] = []
        var cursor = block.start
        for interval in taken {
            if interval.start > cursor { gaps.append(DateInterval(start: cursor, end: interval.start)) }
            cursor = max(cursor, interval.end)
        }
        if block.end > cursor { gaps.append(DateInterval(start: cursor, end: block.end)) }
        return gaps.compactMap { gap -> DateInterval? in
            let start = ceilToMinute(gap.start), end = floorToMinute(gap.end)
            return end.timeIntervalSince(start) >= FocusSession.minimumSeconds ? DateInterval(start: start, end: end) : nil
        }
        // 同じ長さなら早いほう
        .max { $0.duration < $1.duration || ($0.duration == $1.duration && $0.start > $1.start) }
    }

    /// タイマーの画面の「前の分を足す」で足せる区間（ブロックの開始〜タイマーを始めた時刻）。出さないときは nil。
    /// 今のブロックを、ブロックの開始から5分以上たって始めたとき（前倒し・終わってから始めた・ゲーム・SNS の時間は出さない）で、
    /// その区間を手動で記録できるときだけ
    static func previousPart(blockStart: Date, blockEnd: Date, isGameTime: Bool, timerStart: Date, context: Context) -> DateInterval? {
        guard !isGameTime, timerStart < blockEnd, timerStart.timeIntervalSince(blockStart) >= lateStartMinimum,
              problem(start: blockStart, end: timerStart, context: context) == nil else { return nil }
        return DateInterval(start: blockStart, end: timerStart)
    }

    /// 分に切り捨てる（画面で選ぶ時刻は1分きざみ）
    static func floorToMinute(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
    }

    static func ceilToMinute(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded(.up) * 60)
    }
}
