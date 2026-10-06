import Foundation

/// ウィジェット（WID-01、docs/product/features/home.md「ウィジェット」）に渡すその日の材料。
/// 本体がアプリを開いたとき・記録や計画を変えたときに App Group に書き、ウィジェットは先の時刻の表示をここから作る。
struct WidgetSnapshot: Codable, Equatable {
    struct Block: Codable, Equatable {
        var title: String
        var start: Date
        var end: Date
        var isGameTime: Bool
    }

    static let key = "widgetSnapshot"
    /// 本体とウィジェットで共有する場所（BlockShared.appGroup と同じ）
    static let appGroup = "group.com.hirototoda.focusapp"
    /// 先週の集中の進み方の刻み（秒）
    static let curveStep: TimeInterval = 10 * 60

    var generatedAt: Date
    var dayStart: Date
    var dayEnd: Date
    var blocks: [Block]
    /// 作った時刻までの今日の集中（秒）
    var focusSeconds: Int
    /// 動いている集中のタイマーの数え始め（一時停止中・タイマーなしは nil）と、予定の終わり（なければ nil）
    var runningStart: Date?
    var runningEnd: Date?
    /// 先週の自分の集中の累計（秒）。dayStart から curveStep ごと。先週の記録がなければ空
    var ghostCurve: [Int]

    /// ウィジェットの1コマの表示
    struct Entry: Equatable {
        enum Line: Equatable {
            /// 今のブロックの最中（〜終わり）
            case now(Block)
            /// 次のブロック
            case next(Block)
            case none
        }

        var line: Line
        /// 今日の集中と先週のこの時刻の集中（先週の記録がなければ nil）
        var focusSeconds: Int
        var ghostSeconds: Int?
        /// 渡した日が終わった（アプリを開くと今日の予定が出る）
        var isStale: Bool

        var diffSeconds: Int? { ghostSeconds.map { focusSeconds - $0 } }
    }

    /// `date` の時点の表示
    func entry(at date: Date) -> Entry {
        guard date < dayEnd else { return Entry(line: .none, focusSeconds: 0, ghostSeconds: nil, isStale: true) }
        let line: Entry.Line
        if let current = blocks.first(where: { $0.start <= date && date < $0.end }) {
            line = .now(current)
        } else if let next = blocks.filter({ $0.start > date }).min(by: { $0.start < $1.start }) {
            line = .next(next)
        } else {
            line = .none
        }
        return Entry(line: line, focusSeconds: focus(at: date), ghostSeconds: ghost(at: date), isStale: false)
    }

    /// タイマーが動いていれば、その分も進めて数える（予定の終わりまで）
    func focus(at date: Date) -> Int {
        guard let runningStart, date > generatedAt else { return focusSeconds }
        let until = min(date, runningEnd ?? date)
        return focusSeconds + max(0, Int(until.timeIntervalSince(max(runningStart, generatedAt))))
    }

    /// 先週のこの時刻までの集中。刻みの間はならす
    func ghost(at date: Date) -> Int? {
        guard !ghostCurve.isEmpty else { return nil }
        let position = max(0, date.timeIntervalSince(dayStart)) / Self.curveStep
        let index = Int(position)
        guard index + 1 < ghostCurve.count else { return ghostCurve.last }
        let fraction = position - Double(index)
        return ghostCurve[index] + Int(Double(ghostCurve[index + 1] - ghostCurve[index]) * fraction)
    }

    /// ウィジェットのコマの時刻：今から15分ごと（6時間先まで）と、ブロックの始まり・終わり。日の終わりも入れる
    func entryDates(from now: Date) -> [Date] {
        let limit = min(dayEnd, now.addingTimeInterval(6 * 3600))
        var dates: Set<Date> = [now]
        var cursor = now
        while true {
            cursor = cursor.addingTimeInterval(15 * 60)
            guard cursor < limit else { break }
            dates.insert(cursor)
        }
        for block in blocks {
            for date in [block.start, block.end] where date > now && date < limit { dates.insert(date) }
        }
        if dayEnd > now && dayEnd <= now.addingTimeInterval(6 * 3600) { dates.insert(dayEnd) }
        return dates.sorted()
    }

    /// App Group から読む。なければ・読めなければ nil
    static func load(from defaults: UserDefaults?) -> WidgetSnapshot? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}
