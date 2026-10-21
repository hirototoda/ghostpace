import Foundation

/// ラップ（GHO-06、docs/product/features/ghost-race.md「ラップ」）。一日の始まり（前の日の区切り）から2時間ごとの区間で、相手との差を出す。
/// 2026-10-12 から差は集中した時間ではなくポイント（旗・帯・一覧のすべて）。帯を出すかどうかだけは今までどおり集中で決める
struct Lap: Identifiable, Hashable {
    var interval: DateInterval
    /// その区間に自分が集中した秒数（区間の途中は今まで）
    var mine: Int
    /// その区間に相手が集中した秒数（相手も同じ時刻まで）
    var opponent: Int
    /// 今の区間（まだ終わっていない）
    var isCurrent: Bool
    /// その区間で増えた自分のポイント（区間の途中は今まで）。自己ベストのラップ表と同じ数え方で、開けた区間はマイナスもある
    var minePoints: Double
    /// その区間で増えた相手のポイント（相手も同じ時刻まで）
    var opponentPoints: Double

    var diff: Int { mine - opponent }
    var id: Date { interval.start }
    /// 自分も相手も集中していない区間。帯（区切りの演出）を出さない判定にだけ使う（Q39。一覧は hasNoPoints で省く）
    var hasNoFocus: Bool { mine == 0 && opponent == 0 }
    /// ポイントの差（自分−相手）。画面に出す2つの値（0.1pt）の引き算（自己ベストのラップ表と同じ）
    var pointsGap: Double { BestLaps.shownGap(minePoints, opponentPoints) }
    /// 自分も相手も区間のポイントが表示で 0.0（一覧で省く、2026-10-12）
    var hasNoPoints: Bool { BestLaps.shown(minePoints) == 0 && BestLaps.shown(opponentPoints) == 0 }
}

enum Laps {
    static let length: TimeInterval = 2 * 3600
    static let count = 12

    /// その日の区間（一日の始まりから2時間ごと。区切り 22:00 なら 22:00–0:00 … 20:00–22:00 の12区間）。
    /// 一日が24時間でない日（区切りを変えた次の日）は、最後の区間を区切りまでの残りにする（25時間なら12区間＋最後の1時間）
    static func sections(dayStart: Date, dayEnd: Date? = nil) -> [DateInterval] {
        let end = dayEnd ?? dayStart.addingTimeInterval(Double(count) * length)
        var result: [DateInterval] = []
        var cursor = dayStart
        while cursor < end {
            let next = min(cursor.addingTimeInterval(length), end)
            result.append(DateInterval(start: cursor, end: next))
            cursor = next
        }
        return result
    }

    /// `now` までに始まった区間のラップ。`opponent` は相手のその時刻までの集中（秒）、
    /// `minePoints`・`opponentPoints` はその時刻までにたまった自分・相手のポイント（区間のポイントは終わり−始まり）
    static func make(mine: [TimeSegment], opponent: (Date) -> Int, minePoints: (Date) -> Double,
                     opponentPoints: (Date) -> Double, dayStart: Date, dayEnd: Date? = nil, now: Date) -> [Lap] {
        sections(dayStart: dayStart, dayEnd: dayEnd).filter { $0.start < now }.map { section in
            let end = min(section.end, now)
            return Lap(interval: section,
                       mine: mine.focusSeconds(until: end) - mine.focusSeconds(until: section.start),
                       opponent: max(0, opponent(end) - opponent(section.start)),
                       isCurrent: now < section.end,
                       minePoints: minePoints(end) - minePoints(section.start),
                       opponentPoints: opponentPoints(end) - opponentPoints(section.start))
        }
    }

    /// ポイントが `target` に初めて届いた時刻（中間地点、2026-10-12 からポイントで）。`start`〜`end` を1分ごとに見て、
    /// 届いた1分の中を秒まで詰める。届いていない・`target` が0以下なら nil。届いたあと開けて下がっても、初めて届いた所
    static func reachTime(points target: Double, of points: (Date) -> Double, from start: Date, until end: Date) -> Date? {
        guard target > 0, end > start else { return nil }
        func reached(_ offset: Int) -> Bool { points(start.addingTimeInterval(Double(offset))) >= target - 1e-9 }
        let total = Int(end.timeIntervalSince(start))
        var hi = 0
        while hi < total {
            hi = min(hi + 60, total)
            if reached(hi) { break }
        }
        guard reached(hi) else { return nil }
        var lo = max(hi - 60, 0)
        if reached(lo) { return start.addingTimeInterval(Double(lo)) }
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if reached(mid) { hi = mid } else { lo = mid }
        }
        return start.addingTimeInterval(Double(hi))
    }


    /// 線の先 `head` が通過した最後の区間の境目（一日の始まりから。境目ちょうども通過に数える）。その日の一日分の外には出ない。
    /// ［▶］で流している間、一覧を変えるのは境目を過ぎたときだけにするため（GHO-06、2026-10-12）
    static func passedBoundary(dayStart: Date, dayEnd: Date? = nil, head: Date) -> Date {
        let ends = sections(dayStart: dayStart, dayEnd: dayEnd).map(\.end)
        return ends.last { $0 <= head } ?? dayStart
    }

    /// ラップの一覧に出す行（GHO-06、2026-10-12）。自分も相手も区間のポイントが 0.0 の区間は省く。
    /// 流していない（`replayHead` が nil）ときは今の一覧（今の区間の「途中」まで）。
    /// ［▶］で流している間は、線の先が区切りを過ぎた（ちょうども）区間だけを、区間を最後まで数えた値で出す。今の区間は出さない
    static func listed(_ laps: [Lap], replayHead: Date?) -> [Lap] {
        laps.filter { lap in
            guard !lap.hasNoPoints else { return false }
            guard let replayHead else { return true }
            return !lap.isCurrent && lap.interval.end <= replayHead
        }
    }
}

/// 予想ゴール・追いつく・自己ベストまで（GHO-15）
enum RacePace {
    /// 計画どおりなら今日の集中（今までの集中＋これからの計画の集中。今のブロックは今から終わりまで）
    static func plannedFinish(focusNow: Int, blocks: [PlanBlockSummary], now: Date) -> Int {
        focusNow + blocks.filter(\.countsAsFocus).reduce(0) { total, block in
            total + max(0, Int(block.end.timeIntervalSince(max(block.start, now))))
        }
    }

    /// 計画なし日：起きてから今までの集中の割合で、寝る時刻まで続けたときの集中。起きる前・割合が出せないときは nil
    static func paceFinish(focusNow: Int, wake: Date, bed: Date, now: Date) -> Int? {
        let elapsed = now.timeIntervalSince(wake)
        let whole = bed.timeIntervalSince(wake)
        guard elapsed >= 30 * 60, whole > 0 else { return nil }
        if now >= bed { return focusNow }
        return Int(Double(focusNow) * whole / elapsed)
    }

    /// 今から休まず集中したとき、相手に並ぶまでの分。リードしている・その日のうちに追いつけないときは nil
    static func catchUpMinutes(focusNow: Int, opponent: (Date) -> Int, now: Date, dayEnd: Date) -> Int? {
        guard opponent(now) > focusNow else { return nil }
        let limit = Int(dayEnd.timeIntervalSince(now) / 60)
        guard limit > 0 else { return nil }
        for minutes in 1...limit where focusNow + minutes * 60 >= opponent(now.addingTimeInterval(Double(minutes * 60))) {
            return minutes
        }
        return nil
    }
}

/// 自己ベスト（ANA-06）と、ホームの「あと30分で自己ベスト」
struct PersonalBest: Hashable {
    /// 1日の集中の最大（秒）と、その日の 4:00
    var focusSeconds: Int
    var focusDay: Date

    /// ホームに出す近さ（これより離れていれば出さない）
    static let nearSeconds = 60 * 60

    /// 今日の集中との関係。近いときだけ「あと◯分」、超えたら更新
    enum Status: Equatable {
        case near(minutes: Int)
        case beaten
    }

    func status(todayFocus: Int) -> Status? {
        guard focusSeconds > 0 else { return nil }
        if todayFocus > focusSeconds { return .beaten }
        let left = focusSeconds - todayFocus
        guard left > 0, left <= Self.nearSeconds else { return nil }
        return .near(minutes: Int((Double(left) / 60).rounded(.up)))
    }
}

enum DailyFocus {
    /// 記録の区間をその日の区切りで区切って、日（その日の始まり）ごとの集中の秒に分ける。区切りをまたいだ分は次の日に入れる
    static func byDay(_ segments: [TimeSegment], boundary: DayBoundary) -> [Date: Int] {
        var result: [Date: Int] = [:]
        for segment in segments where segment.countsAsFocus && segment.end > segment.start {
            var cursor = segment.start
            while cursor < segment.end {
                let day = boundary.day(containing: cursor)
                let end = min(segment.end, day.end)
                result[day.start, default: 0] += Int(end.timeIntervalSince(cursor))
                cursor = end
            }
        }
        return result
    }

    /// 区切りの履歴がないとき（朝4:00区切り）
    static func byDay(_ segments: [TimeSegment], calendar: Calendar) -> [Date: Int] {
        byDay(segments, boundary: DayBoundary(calendar: calendar))
    }

    /// 自己ベスト（今日より前の日だけ）。記録がなければ nil
    static func best(_ byDay: [Date: Int], before today: Date) -> PersonalBest? {
        guard let best = byDay.filter({ $0.key < today && $0.value > 0 }).max(by: { ($0.value, $1.key) < ($1.value, $0.key) }) else {
            return nil
        }
        return PersonalBest(focusSeconds: best.value, focusDay: best.key)
    }
}

/// 時間帯の地図（ANA-07）：曜日（月〜日）×2時間の区間ごとの、集中の平均（秒）
struct TimeMap: Hashable {
    /// [曜日 0=月 … 6=日][区間 0=今日の一日の始まりの時刻から2時間 … 11]
    var averages: [[Int]]
    /// 区間0の始まりの時刻（0:00 からの分。区切り 22:00 なら 1320）
    var originMinutes = DayBoundary.morningHour * 60

    /// 区間 `section` の始まりの時（0〜23）
    func sectionHour(_ section: Int) -> Int { (originMinutes / 60 + section * 2) % 24 }

    /// 区間 `section` の始まりの時刻（「22:00」「22:30」）
    func sectionLabel(_ section: Int) -> String {
        let minutes = (originMinutes + section * 120) % 1440
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    static let weeks = 4

    /// 一番濃いマス（曜日, 区間）。どこも0なら nil
    var peak: (weekday: Int, section: Int)? {
        var best: (Int, Int, Int)?
        for (weekday, row) in averages.enumerated() {
            for (section, value) in row.enumerated() where value > (best?.2 ?? 0) { best = (weekday, section, value) }
        }
        return best.map { ($0.0, $0.1) }
    }

    var maxValue: Int { averages.flatMap { $0 }.max() ?? 0 }

    /// 直近4週（`today` の前の日まで）。記録のある日（何か集中した日）だけで平均する。
    /// 区間は今日の一日の始まりの時刻から2時間ごとの12区間（`originMinutes`、0:00 からの分）。曜日は日の名前で決め、
    /// 区切りが違う日の集中も時刻で区間に入れる（2026-10-21、Claude 補足、Q48）
    static func make(_ segments: [TimeSegment], today: BoundaryDay, boundary: DayBoundary) -> TimeMap {
        let calendar = boundary.calendar
        let from = boundary.day(-weeks * 7, from: today).start
        let origin = originMinutes(of: today, calendar: calendar)
        var totals = Array(repeating: Array(repeating: 0, count: Laps.count), count: 7)
        var days: [Int: Set<String>] = [:]
        for segment in segments where segment.countsAsFocus {
            var cursor = max(segment.start, from)
            let end = min(segment.end, today.start)
            while cursor < end {
                let day = boundary.day(containing: cursor)
                let parts = calendar.dateComponents([.hour, .minute, .second], from: cursor)
                let seconds = (parts.hour ?? 0) * 3600 + (parts.minute ?? 0) * 60 + (parts.second ?? 0)
                let fromOrigin = ((seconds - origin * 60) % 86400 + 86400) % 86400
                let section = min(fromOrigin / Int(Laps.length), Laps.count - 1)
                let sectionEnd = min(end, day.end, cursor.addingTimeInterval(Double((section + 1) * Int(Laps.length) - fromOrigin)))
                let weekday = (calendar.component(.weekday, from: day.date) + 5) % 7
                totals[weekday][section] += Int(sectionEnd.timeIntervalSince(cursor))
                days[weekday, default: []].insert(day.key)
                cursor = sectionEnd
            }
        }
        return TimeMap(averages: totals.enumerated().map { weekday, row in
            let count = days[weekday]?.count ?? 0
            return row.map { count > 0 ? $0 / count : 0 }
        }, originMinutes: origin)
    }

    /// 区切りの履歴がないとき（朝4:00区切り）。`today` は今日の 4:00
    static func make(_ segments: [TimeSegment], today: Date, calendar: Calendar) -> TimeMap {
        let boundary = DayBoundary(calendar: calendar)
        return make(segments, today: boundary.day(containing: today), boundary: boundary)
    }

    /// 区間の始まりの時刻（0:00 からの分）：今日の一日の始まりの時刻
    static func originMinutes(of day: BoundaryDay, calendar: Calendar) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: day.start)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}
