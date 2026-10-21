import Foundation
import SwiftData
import Synchronization
import Testing
@testable import FocusApp

let tokyo = TimeZone(identifier: "Asia/Tokyo")!

/// 東京の時刻。例 `jst("2026-10-19T09:10")`、`jst("2026-10-19T09:10:30")`
func jst(_ text: String) -> Date { LaunchOptions.parseDate(text, timeZone: tokyo)! }

var tokyoCalendar: Calendar { Calendar.app(timeZone: tokyo) }

/// 区切りの履歴がないとき（朝4:00区切り、2026-10-21 の版より前の日の数え方）の日。今までのテストの見本の記録に使う
extension DayBoundary {
    static func dayKey(containing date: Date, calendar: Calendar) -> String { DayBoundary(calendar: calendar).dayKey(containing: date) }
    static func dayStart(containing date: Date, calendar: Calendar) -> Date { DayBoundary(calendar: calendar).dayStart(containing: date) }
}

// MARK: 区切りの履歴がない日（朝4:00区切り）で数える、今までのテスト用の形
// 本番のコードは区切りの履歴（DayBoundary）を必ず渡す。履歴を渡し忘れて朝4:00区切りに落ちないよう、この形はテストにだけ置く

extension BestPeriods {
    static func start(_ period: BestPeriod, today: Date, calendar: Calendar) -> Date? {
        start(period, today: today, boundary: DayBoundary(calendar: calendar))
    }

    static func range(_ period: BestPeriod, today: Date, calendar: Calendar, recordDays: [Date]) -> BestRange {
        range(period, today: today, boundary: DayBoundary(calendar: calendar), recordDays: recordDays)
    }
}

extension DailyFocus {
    static func byDay(_ segments: [TimeSegment], calendar: Calendar) -> [Date: Int] {
        byDay(segments, boundary: DayBoundary(calendar: calendar))
    }
}

extension TimeMap {
    /// `today` は今日の 4:00
    static func make(_ segments: [TimeSegment], today: Date, calendar: Calendar) -> TimeMap {
        let boundary = DayBoundary(calendar: calendar)
        return make(segments, today: boundary.day(containing: today), boundary: boundary)
    }
}

extension LapTargets {
    static func sleepSections(startMinutes: Int, endMinutes: Int, dayStart: Date, calendar: Calendar) -> Set<Int> {
        sleepSections(startMinutes: startMinutes, endMinutes: endMinutes,
                      day: DayBoundary(calendar: calendar).day(containing: dayStart), calendar: calendar)
    }
}

extension GhostSummary {
    /// 区切りが同じ週：日の始まりからの経過で揃え、24時間を超える部分は切る
    init?(lastWeek sessions: [FocusSession], lastWeekStart: Date, todayStart: Date) {
        self.init(lastWeek: sessions, lastWeekDay: DateInterval(start: lastWeekStart, duration: 24 * 3600),
                  shift: todayStart.timeIntervalSince(lastWeekStart))
    }
}

extension HomeSnapshot {
    /// 区切りの履歴がないときの日（`dayStart`、なければ `now` の日）と、その7日前で作る
    static func make(now: Date, calendar: Calendar, todaySessions: [FocusSession], plan: PlanDraft?,
                     lastWeekSessions: [FocusSession], noPlanGoalSeconds: Int? = nil, detox: DetoxDay? = nil,
                     lastWeekDetox: DetoxDay? = nil, sleep: [DateInterval] = [], sleepCaps: [DateInterval] = [],
                     awakeSleep: [DateInterval]? = nil, dayStart: Date? = nil,
                     onPlan: OnPlanContext = OnPlanContext()) -> HomeSnapshot {
        let legacy = DayBoundary(calendar: calendar)
        let day = legacy.day(containing: dayStart ?? now)
        return make(now: now, calendar: calendar, todaySessions: todaySessions, plan: plan, lastWeekSessions: lastWeekSessions,
                    noPlanGoalSeconds: noPlanGoalSeconds, detox: detox, lastWeekDetox: lastWeekDetox, sleep: sleep,
                    sleepCaps: sleepCaps, awakeSleep: awakeSleep, day: day, lastWeekDay: legacy.day(-7, from: day), onPlan: onPlan)
    }
}

/// 区切りの履歴（`[(fromDayKey, endMinutes)]`）からの区切り
func boundary(_ rows: [(String, Int)]) -> DayBoundary {
    DayBoundary(calendar: tokyoCalendar, changes: rows.map { DayBoundaryChange(fromDayKey: $0.0, endMinutes: $0.1) })
}

/// 途中で進められる時計。
final class MutableClock: AppClock {
    private let date: Mutex<Date>

    init(_ date: Date) { self.date = Mutex(date) }

    func now() -> Date { date.withLock { $0 } }
    func set(_ newDate: Date) { date.withLock { $0 = newDate } }
    func advance(_ seconds: TimeInterval) { date.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

/// 呼ぶたびに少し進む時計（本物の時計のように、2回続けて読むと値が違う）。
final class TickingClock: AppClock {
    private let date: Mutex<Date>
    private let step: TimeInterval

    init(_ date: Date, step: TimeInterval = 0.001) {
        self.date = Mutex(date)
        self.step = step
    }

    func now() -> Date { date.withLock { $0 = $0.addingTimeInterval(step); return $0 } }
    func advance(_ seconds: TimeInterval) { date.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

/// メモリ内のストア。コンテナが先に解放されないよう、ストアと一緒に持つ。
@MainActor
struct TestStore {
    let container: ModelContainer
    let store: SwiftDataStore
    let clock: MutableClock

    init(now: Date = jst("2026-10-19T09:00"), url: URL? = nil) throws {
        container = try AppStore.makeContainer(url: url)
        clock = MutableClock(now)
        store = SwiftDataStore(container: container, clock: clock)
    }

    var context: ModelContext { store.context }

    /// 8つのカテゴリを入れて返す。
    @discardableResult
    func seeded() throws -> [CategoryOption] {
        try store.seedDefaultsIfNeeded()
        return try store.categories()
    }

    func category(_ name: String) throws -> CategoryOption {
        try #require(try store.allCategories().first { $0.name == name })
    }
}

/// UUID 入りの一時ファイルの場所。使い終わったら `removeStoreFiles` で消す。
func temporaryStoreURL() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "focusapp-test-\(UUID().uuidString).store")
}

func removeStoreFiles(_ url: URL) {
    for suffix in ["", "-shm", "-wal"] {
        try? FileManager.default.removeItem(at: URL(filePath: url.path(percentEncoded: false) + suffix))
    }
}

func session(_ start: String, _ end: String?, category: CategoryOption = DefaultCategories.all[0],
             pauses: [(String, String?)] = [], plannedEnd: String? = nil, plannedMinutes: Int? = nil) -> FocusSession {
    FocusSession(
        id: UUID(), dayKey: DayBoundary.dayKey(containing: jst(start), calendar: tokyoCalendar),
        category: category, project: nil, planBlockId: nil,
        startAt: jst(start), endAt: end.map(jst),
        plannedEndAt: plannedEnd.map(jst), plannedDurationSec: plannedMinutes.map { $0 * 60 },
        pauses: pauses.map { PauseInterval(start: jst($0.0), end: $0.1.map(jst)) },
        originalEndAt: nil)
}

/// ブロックを 2026-10-01 から使っている本体（先週のデトックスがあり、先週の自分のポイントとラップが出る）。
/// 2026-10-12 からラップはポイントで出すので、相手のポイントがない日はラップも帯も出ない
@MainActor
func raceModelWithBlocking(_ t: TestStore, settings: MemorySettings = MemorySettings()) throws -> AppModel {
    let log = MemoryBlockEventLog()
    try log.append(BlockEvent(occurredAt: jst("2026-10-01T04:00"), timeZoneId: "Asia/Tokyo", kind: .started))
    settings.didShowBlockingIntro = true
    settings.didLogBlockStart = true
    settings.lastBlockingAuthorized = true
    let blockStore = MemoryBlockStore()
    blockStore.state = BlockState(isEnabled: true)
    blockStore.selection = Data("sel".utf8)
    return AppModel(store: t.store, clock: t.clock, timeZone: { tokyo }, settings: settings,
                    blocking: FakeBlocking(), blockStore: blockStore, blockLog: log)
}
