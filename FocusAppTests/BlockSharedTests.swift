import Foundation
import Testing
@testable import FocusApp

/// 自動で戻す手順（BlockMonitor 拡張が使う）と、本体・拡張で共有する置き場（data-model.md）。
struct BlockSharedTests {
    private let until = jst("2026-10-19T11:35")

    private func unlockedStore(enabled: Bool = true, selection: Data? = Data("sel".utf8)) -> MemoryBlockStore {
        let store = MemoryBlockStore()
        store.state = BlockState(isEnabled: enabled, unlockedUntil: until)
        store.selection = selection
        return store
    }

    // MARK: BlockReblock

    @Test func restoresOnlyAfterDeadlineMinusTolerance() throws {
        let store = unlockedStore()
        let log = MemoryBlockEventLog()
        var shielded: [Data] = []
        // 期限の31秒前：30秒の余裕でも早すぎる
        #expect(!BlockReblock.run(store: store, log: log, now: until.addingTimeInterval(-31), tolerance: 30,
                                  timeZone: tokyo, reason: .expired) { shielded.append($0); return true })
        #expect(store.state.unlockedUntil == until)
        // 期限の29秒前：合図が少し早く届いたとみなして戻す
        #expect(BlockReblock.run(store: store, log: log, now: until.addingTimeInterval(-29), tolerance: 30,
                                 timeZone: tokyo, reason: .expired) { shielded.append($0); return true })
        #expect(store.state.unlockedUntil == nil)
        #expect(shielded == [Data("sel".utf8)])
        let event = try #require(log.all().first)
        #expect(event.kind == .reblocked)
        #expect(event.reblockReason == .expired)
        #expect(event.occurredAt == until.addingTimeInterval(-29))
    }

    @Test func secondCallDoesNothing() throws {
        let store = unlockedStore()
        let log = MemoryBlockEventLog()
        var count = 0
        #expect(BlockReblock.run(store: store, log: log, now: until, timeZone: tokyo, reason: .expired) { _ in count += 1; return true })
        // 15分のスケジュールの終わり（5分で開けたときの2回目の合図）
        #expect(!BlockReblock.run(store: store, log: log, now: until.addingTimeInterval(600), timeZone: tokyo,
                                  reason: .expired) { _ in count += 1; return true })
        #expect(count == 1)
        #expect(try log.all().count == 1)
    }

    @Test func notUnlockedMeansNothingToDo() throws {
        let store = MemoryBlockStore()
        store.state = BlockState(isEnabled: true)
        let log = MemoryBlockEventLog()
        #expect(!BlockReblock.run(store: store, log: log, now: until, timeZone: tokyo, reason: .expired) { _ in true })
        #expect(try log.all().isEmpty)
    }

    @Test(arguments: [(false, true), (true, false)])
    func clearsDeadlineButDoesNotShieldWithoutStartOrSelection(enabled: Bool, hasSelection: Bool) throws {
        let store = unlockedStore(enabled: enabled, selection: hasSelection ? Data("sel".utf8) : nil)
        var shielded = false
        #expect(BlockReblock.run(store: store, log: MemoryBlockEventLog(), now: until, timeZone: tokyo,
                                 reason: .expired) { _ in shielded = true; return true })
        #expect(store.state.unlockedUntil == nil)
        #expect(!shielded)
    }

    @Test func unreadableSelectionIsClearedSoOwnerPicksAgain() throws {
        let store = unlockedStore()
        let log = MemoryBlockEventLog()
        #expect(BlockReblock.run(store: store, log: log, now: until, timeZone: tokyo, reason: .expired) { _ in false })
        #expect(store.state.unlockedUntil == nil)
        #expect(store.selection == nil)
        // 選び直すまでブロックがないので、デトックスの材料として書く（BLK-11）
        #expect(try log.all().map(\.kind) == [.selectionLost, .reblocked])
    }

    // MARK: UserDefaultsBlockStore

    private func defaults() -> UserDefaults {
        let name = "block-test-\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    @Test func userDefaultsStoreRoundTrips() {
        let d = defaults()
        let store = UserDefaultsBlockStore(defaults: d)
        let state = BlockState(isEnabled: true, unlockedUntil: until, unlockRequestedAt: jst("2026-10-19T11:19"))
        let snapshot = ShieldRaceSnapshot(writtenAt: until, dayKey: "2026-10-19", dayStart: jst("2026-10-19T04:00"),
                                          focusSecAtWrite: 60, isFocusRunning: true, opponentPrefix: "目標より",
                                          opponentCurve: [0, 60])
        store.state = state
        store.selection = Data("sel".utf8)
        store.raceSnapshot = snapshot
        // 別のインスタンス（拡張から開いたとき）でも同じ値
        let other = UserDefaultsBlockStore(defaults: d)
        #expect(other.state == state)
        #expect(other.selection == Data("sel".utf8))
        #expect(other.raceSnapshot == snapshot)
        other.raceSnapshot = nil
        #expect(store.raceSnapshot == nil)
    }

    @Test func userDefaultsStoreDefaultsWhenEmptyOrBroken() {
        let d = defaults()
        let store = UserDefaultsBlockStore(defaults: d)
        #expect(store.state == BlockState())
        #expect(store.selection == nil)
        #expect(store.raceSnapshot == nil)
        d.set(Data("broken".utf8), forKey: "blockState")
        #expect(store.state == BlockState())
    }
}

/// 起動のしかたで、本物の Screen Time を使うかを分ける（UI テスト・見本では触れない）。
@MainActor
struct BlockingDependenciesTests {
    @Test func demoAndUITestsUseStartedMemoryBlocking() {
        for options in [LaunchOptions.parse(["-seedDemoData"]), LaunchOptions.parse(["-inMemoryStore"]),
                        LaunchOptions.parse(["-storeName", "ui"])] {
            let (blocking, store, log) = AppLauncher.blockingDependencies(options)
            #expect(blocking is NoBlocking)
            #expect(blocking.isAvailable)
            #expect(store is MemoryBlockStore)
            #expect(store.state.isEnabled)
            #expect(log is MemoryBlockEventLog)
        }
    }

    @Test func normalLaunchNeverUsesDemoState() {
        let (blocking, store, _) = AppLauncher.blockingDependencies(LaunchOptions())
        // シミュレーター（App Group が使えなければメモリ内の空）でも、始めた状態にはしない
        #expect(!(blocking is NoBlocking) || !blocking.isAvailable)
        #expect(!(store is MemoryBlockStore) || !store.state.isEnabled)
    }
}
