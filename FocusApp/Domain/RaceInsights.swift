import Foundation

/// ラップ（GHO-06、docs/product/features/ghost-race.md「ラップ」）。4:00 から2時間ごとの区間で、相手との集中の差を出す。
struct Lap: Identifiable, Hashable {
    var interval: DateInterval
    /// その区間に自分が集中した秒数（区間の途中は今まで）
    var mine: Int
    /// その区間に相手が集中した秒数（相手も同じ時刻まで）
    var opponent: Int
    /// 今の区間（まだ終わっていない）
    var isCurrent: Bool

    var diff: Int { mine - opponent }
    var id: Date { interval.start }
    /// 自分も相手も集中していない区間（一覧・帯で省く）
    var isEmpty: Bool { mine == 0 && opponent == 0 }
}

enum Laps {
    static let length: TimeInterval = 2 * 3600
    static let count = 12

    /// その日の12区間（4:00–6:00 … 翌2:00–翌4:00）
    static func sections(dayStart: Date) -> [DateInterval] {
        (0..<count).map { DateInterval(start: dayStart.addingTimeInterval(Double($0) * length), duration: length) }
    }

    /// `now` までに始まった区間のラップ。`opponent` は相手のその時刻までの集中（秒）
    static func make(mine: [TimeSegment], opponent: (Date) -> Int, dayStart: Date, now: Date) -> [Lap] {
        sections(dayStart: dayStart).filter { $0.start < now }.map { section in
            let end = min(section.end, now)
            return Lap(interval: section,
                       mine: mine.focusSeconds(until: end) - mine.focusSeconds(until: section.start),
                       opponent: max(0, opponent(end) - opponent(section.start)),
                       isCurrent: now < section.end)
        }
    }

    /// 自分の集中が `target` 秒に届いた時刻（中間地点）。`now` までに届いていなければ nil
    static func reachTime(_ target: Int, mine: [TimeSegment], now: Date) -> Date? {
        guard target > 0 else { return nil }
        var total = 0
        for segment in mine.filter(\.countsAsFocus).sorted(by: { $0.start < $1.start }) {
            let end = min(segment.end, now)
            guard end > segment.start else { continue }
            let length = Int(end.timeIntervalSince(segment.start))
            if total + length >= target { return segment.start.addingTimeInterval(Double(target - total)) }
            total += length
        }
        return nil
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
    /// 記録の区間を朝4:00で区切って、日（その日の 4:00）ごとの集中の秒に分ける。4:00 をまたいだ分は次の日に入れる
    static func byDay(_ segments: [TimeSegment], calendar: Calendar) -> [Date: Int] {
        var result: [Date: Int] = [:]
        for segment in segments where segment.countsAsFocus && segment.end > segment.start {
            var cursor = segment.start
            while cursor < segment.end {
                let dayStart = DayBoundary.dayStart(containing: cursor, calendar: calendar)
                let next = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86400)
                let end = min(segment.end, next)
                result[dayStart, default: 0] += Int(end.timeIntervalSince(cursor))
                cursor = end
            }
        }
        return result
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
    /// [曜日 0=月 … 6=日][区間 0=4:00–6:00 … 11=翌2:00–翌4:00]
    var averages: [[Int]]

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

    /// 直近4週（`today` の前の日まで）。記録のある日（何か集中した日）だけで平均する
    static func make(_ segments: [TimeSegment], today: Date, calendar: Calendar) -> TimeMap {
        let from = calendar.date(byAdding: .day, value: -weeks * 7, to: today) ?? today
        var totals = Array(repeating: Array(repeating: 0, count: Laps.count), count: 7)
        var days: [Int: Set<Date>] = [:]
        for segment in segments where segment.countsAsFocus {
            var cursor = max(segment.start, from)
            let end = min(segment.end, today)
            while cursor < end {
                let dayStart = DayBoundary.dayStart(containing: cursor, calendar: calendar)
                let section = min(Int(cursor.timeIntervalSince(dayStart) / Laps.length), Laps.count - 1)
                let sectionEnd = min(end, dayStart.addingTimeInterval(Double(section + 1) * Laps.length))
                let weekday = (calendar.component(.weekday, from: dayStart) + 5) % 7
                totals[weekday][section] += Int(sectionEnd.timeIntervalSince(cursor))
                days[weekday, default: []].insert(dayStart)
                cursor = sectionEnd
            }
        }
        return TimeMap(averages: totals.enumerated().map { weekday, row in
            let count = days[weekday]?.count ?? 0
            return row.map { count > 0 ? $0 / count : 0 }
        })
    }
}

/// グラフに出すカテゴリのアイコン（GHO-15）。名前とグループから自動で決める（選べない）
enum CategoryIcon {
    static func symbol(for category: CategoryOption) -> String {
        if category.isUnblock { return "gamecontroller.fill" }
        switch category.name {
        case "勉強": return "pencil"
        case "仕事": return "briefcase.fill"
        case "読書": return "book.fill"
        case "家事": return "house.fill"
        case "運動": return "figure.run"
        case "休み": return "moon.fill"
        default: return category.countsAsFocus ? "star.fill" : "leaf.fill"
        }
    }
}
