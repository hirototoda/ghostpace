import Foundation

/// その日（4:00〜翌4:00）のデジタルデトックス（DTX-01・DTX-03、docs/product/features/digital-detox.md）。
/// いつものブロックが実際に効いていた時間を、記録から区間に分けて数える。保存はせず、毎回計算する。
struct DetoxDay: Hashable {
    /// 区間の種類。上ほど優先（digital-detox.md「ポイント」の表）
    enum Kind: Hashable {
        /// 自分で開けた（長押しで開けた・ゲーム・SNS の時間を過ぎても開いていた）。「開けた時間」に数える（DTX-05）。
        /// 集中中でもこちら（デトックスの点は0。集中の点はタイマーどおり）
        case opened
        /// ほかの理由でブロックが効いていない（始める前・選択が読めない・許可が外れた）
        case open
        /// 集中のタイマー中（一時停止を除く）。デトックスには数えない（集中として数える）
        case focus
        /// デトックスのカテゴリのタイマー中（グループの1日の上限まで1.5倍）
        case detoxTimer
        /// 寝ている（寝てから7時間まで1.5倍、8時間まで1倍、超えたら0）
        case asleep
        /// それ以外のブロック中（予定どおりのゲーム・SNS の時間を含む）
        case blocked
    }

    struct Piece: Hashable {
        var start: Date
        var end: Date
        var kind: Kind
        /// タイマーのグループ（detoxTimer のとき。nil なら上乗せなし）
        var group: DetoxGroup? = nil
        /// 押し忘れの申告（detoxTimer のとき、TMR-13）。上乗せは0.8倍（ブロック中より下げない）
        var isDeclared = false
        /// 寝た時刻（asleep のとき）。寝てからの時間で点を変える
        var sleepStart: Date? = nil
        /// 手で直す前より長くした所（asleep のとき）。0.5pt と睡眠の点の低いほうで数える
        var sleepCapped = false
        /// この区間のうち集中に回した割合（目標のゴーストの空き時間。残りだけデトックスに数える）
        var focusShare: Double = 0
    }

    /// ブロック中（10分0.5pt）
    static let detoxPerSecond = 0.5 / 600
    /// 家事・運動・休みのタイマー中（10分0.75pt、上限まで）
    static let timerPerSecond = 0.75 / 600
    /// 寝ている：寝てから7時間まで10分0.75pt、8時間まで0.5pt、超えたら0
    static let sleepTiers: [(until: TimeInterval, perSecond: Double)] = [(7 * 3600, 0.75 / 600), (8 * 3600, 0.5 / 600)]
    /// n 回目に開けたときに引く点は n × これ
    static let openPenaltyStep = 1.0

    var pieces: [Piece]
    /// 丸1日分の記録があるか（その日の 4:00 にはもうブロックを始めていた）。false の日は「先週のデトックスはなし」
    var isComplete: Bool
    /// 長押しで開けた時刻（この日の 4:00〜数えた時刻まで）。開けた回数に使う（DTX-05）
    var unlockStarts: [Date] = []

    /// `date` までのデトックスの時間（秒）
    func detoxSeconds(until date: Date) -> Int {
        Int(pieces.filter { !$0.kind.isUnblocked && $0.kind != .focus }.reduce(0) { $0 + Self.seconds($1, until: date) })
    }

    /// `date` までに開けていた時間（秒、DTX-05）
    func openedSeconds(until date: Date) -> Int {
        Int(pieces.filter { $0.kind == .opened }.reduce(0) { $0 + Self.seconds($1, until: date) })
    }

    /// 開けていた区間（DTX-05 の開けた時間）。集中中に開けた時間を0点にするのに使う（GHO-14）
    var openedIntervals: [DateInterval] {
        pieces.filter { $0.kind == .opened }.map { DateInterval(start: $0.start, end: $0.end) }
    }

    /// `date` までに長押しで開けた回数（DTX-05）
    func openedCount(until date: Date) -> Int {
        unlockStarts.filter { $0 < date }.count
    }

    /// `date` までに、ブロックが一度でも効いていたか。一度も効いていない日は開けた時間を出さない（DTX-05）
    func wasBlocking(until date: Date) -> Bool {
        pieces.contains { !$0.kind.isUnblocked && $0.start < date }
    }

    /// `date` までに開けた時間と回数。ブロックが一度も効いていなければ nil（出さない）。
    /// ホーム・夜の振り返り（DTX-05）とタイムライン（TML-05）で同じものを使う
    func opened(until date: Date) -> OpenedTime? {
        guard wasBlocking(until: date) else { return nil }
        return OpenedTime(seconds: openedSeconds(until: date), count: openedCount(until: date))
    }

    /// `date` までのデトックスのポイント（DTX-03）。開けた回数の分を引くので、マイナスになることがある
    func points(until date: Date) -> Double {
        var total = 0.0
        var used: [DetoxGroup: TimeInterval] = [:]
        for piece in pieces {
            let seconds = Self.seconds(piece, until: date)
            guard seconds > 0 else { continue }
            let earned: Double
            switch piece.kind {
            case .focus, .open, .opened: earned = 0
            case .blocked: earned = Self.detoxPerSecond * seconds
            case .detoxTimer:
                // グループの上限まで1.5倍、超えた分はブロック中と同じ（その日の早い時刻から使う）
                if let group = piece.group {
                    let boosted = min(seconds, max(0, group.dailyCap - used[group, default: 0]))
                    used[group, default: 0] += boosted
                    // 申告した分は0.8倍。ブロック中の0.5pt より下げない（TMR-13）
                    let rate = piece.isDeclared ? max(Self.timerPerSecond * FocusPoints.declaredFactor, Self.detoxPerSecond) : Self.timerPerSecond
                    earned = rate * boosted + Self.detoxPerSecond * (seconds - boosted)
                } else {
                    earned = Self.detoxPerSecond * seconds
                }
            case .asleep:
                let from = piece.sleepStart.map { piece.start.timeIntervalSince($0) } ?? 0
                earned = Self.sleepPoints(from: from, to: from + seconds, capped: piece.sleepCapped)
            }
            total += earned * (1 - piece.focusShare)
        }
        let opens = unlockStarts.filter { $0 < date }.count
        return total - Self.openPenaltyStep * Double(opens * (opens + 1) / 2)
    }

    /// 寝てから `from`〜`to` 秒の点。`capped` なら各段を0.5pt（ブロック中）までにする（手で長く直した所）
    static func sleepPoints(from: TimeInterval, to: TimeInterval, capped: Bool = false) -> Double {
        var total = 0.0
        var lower: TimeInterval = 0
        for tier in sleepTiers {
            let a = max(from, lower), b = min(to, tier.until)
            if b > a { total += (capped ? min(tier.perSecond, detoxPerSecond) : tier.perSecond) * (b - a) }
            lower = tier.until
        }
        return total
    }

    /// 日付境界からの経過時間で、別の日（先週の自分を今日に）に揃える
    func shifted(by offset: TimeInterval) -> DetoxDay {
        DetoxDay(pieces: pieces.map {
            Piece(start: $0.start.addingTimeInterval(offset), end: $0.end.addingTimeInterval(offset), kind: $0.kind,
                  group: $0.group, sleepStart: $0.sleepStart?.addingTimeInterval(offset), sleepCapped: $0.sleepCapped,
                  focusShare: $0.focusShare)
        }, isComplete: isComplete, unlockStarts: unlockStarts.map { $0.addingTimeInterval(offset) })
    }

    private static func seconds(_ piece: Piece, until date: Date) -> TimeInterval {
        max(0, min(piece.end, date).timeIntervalSince(piece.start))
    }
}

extension DetoxDay {
    /// 計算の材料。
    struct Inputs {
        var dayStart: Date
        var dayEnd: Date
        /// ここまで数える（今日なら今。過ぎた日なら dayEnd）
        var until: Date
        /// ブロックの記録（すべて。古い順でなくてもよい）
        var events: [BlockEvent]
        /// 集中のタイマーの区間（一時停止を除く）
        var focus: [DateInterval]
        /// デトックスのカテゴリのタイマーの区間（一時停止を除く）
        var detoxTimers: [DetoxTimer]
        /// 寝ていた区間（その日の朝の睡眠と、その夜の睡眠）。寝た時刻から数えるので、4:00 で切らずに渡す
        var sleep: [DateInterval]
        /// 確定した計画のゲーム・SNS の時間（予定）
        var gameWindows: [DateInterval]
        /// 目標のゴーストが空き時間に少しずつ集中する区間
        var partialFocus: [PartialFocus] = []
        /// 手で直す前より長くした睡眠の所（SleepLine.extendedPart）
        var sleepCaps: [DateInterval] = []
    }

    static func make(_ inputs: Inputs) -> DetoxDay {
        let limit = min(inputs.until, inputs.dayEnd)
        guard limit > inputs.dayStart else { return DetoxDay(pieces: [], isComplete: false) }
        let state = BlockTimeline(events: inputs.events)

        var bounds: Set<Date> = [inputs.dayStart, limit]
        let intervals = inputs.focus + inputs.detoxTimers.map(\.interval) + inputs.sleep + inputs.gameWindows
            + inputs.partialFocus.map(\.interval) + inputs.sleepCaps + state.boundaries
        for interval in intervals {
            for date in [interval.start, interval.end] where date > inputs.dayStart && date < limit { bounds.insert(date) }
        }
        let sorted = bounds.sorted()

        var pieces: [Piece] = []
        for (start, end) in zip(sorted, sorted.dropFirst()) where end > start {
            let mid = start.addingTimeInterval(end.timeIntervalSince(start) / 2)
            var piece = Piece(start: start, end: end, kind: .blocked)
            if !state.isCounted(at: mid, plannedGame: inputs.gameWindows) {
                piece.kind = state.isOpenedByUser(at: mid, plannedGame: inputs.gameWindows) ? .opened : .open
            } else if inputs.focus.contains(where: { $0.contains(mid) }) {
                piece.kind = .focus
            } else if let timer = inputs.detoxTimers.first(where: { $0.interval.contains(mid) }) {
                piece.kind = .detoxTimer
                piece.group = timer.group
                piece.isDeclared = timer.isDeclared
            } else if let sleep = inputs.sleep.first(where: { $0.contains(mid) }) {
                piece.kind = .asleep
                piece.sleepStart = sleep.start
                piece.sleepCapped = inputs.sleepCaps.contains { $0.contains(mid) }
            }
            piece.focusShare = inputs.partialFocus.first { $0.interval.contains(mid) }?.share ?? 0
            pieces.append(piece)
        }
        let unlockStarts = state.unlocked.map(\.start).filter { $0 >= inputs.dayStart && $0 < limit }
        return DetoxDay(pieces: pieces, isComplete: state.isEnabled(at: inputs.dayStart), unlockStarts: unlockStarts)
    }
}

extension DetoxDay.Kind {
    /// ブロックが効いていない（自分で開けた・ほかの理由）
    var isUnblocked: Bool { self == .open || self == .opened }
}

/// デトックスのカテゴリのタイマーの区間（一時停止を除く）
struct DetoxTimer: Hashable {
    var interval: DateInterval
    var group: DetoxGroup?
    /// 押し忘れの申告（TMR-13）
    var isDeclared = false
}

/// 目標のゴーストが空き時間に少しずつ集中する区間。`share` はその間の集中の割合（0〜1）。
/// 残りの割合だけデトックスとして数える（二重に数えない、GHO-10）
struct PartialFocus: Hashable {
    var interval: DateInterval
    var share: Double
}
