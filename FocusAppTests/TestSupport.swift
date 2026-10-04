import Foundation
import SwiftData
import Synchronization
import Testing
@testable import FocusApp

let tokyo = TimeZone(identifier: "Asia/Tokyo")!

/// 東京の時刻。例 `jst("2026-10-19T09:10")`、`jst("2026-10-19T09:10:30")`
func jst(_ text: String) -> Date { LaunchOptions.parseDate(text, timeZone: tokyo)! }

var tokyoCalendar: Calendar { Calendar.app(timeZone: tokyo) }

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
