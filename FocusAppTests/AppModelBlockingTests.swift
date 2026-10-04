import Foundation
import Testing
@testable import FocusApp

/// iOS の Screen Time を呼ぶ代わりに、呼ばれた操作を覚えておく。
@MainActor
final class FakeBlocking: BlockingControlling {
    var isAvailable = true
    var status: BlockingAuthorization = .approved
    var answer: BlockingAuthorization = .approved
    /// 選択の中身の数（本物は FamilyActivitySelection を読んで数える）
    var count = 2
    private(set) var calls: [String] = []
    private(set) var schedules: [ReblockSchedule] = []

    func authorization() -> BlockingAuthorization { status }
    func requestAuthorization() async -> BlockingAuthorization {
        calls.append("request")
        status = answer
        return answer
    }
    func selectionCount(_ selection: Data) -> Int { count }
    func shield(selection: Data) { calls.append("shield") }
    func unshield() { calls.append("unshield") }
    /// 集中中の全部ブロックに渡した「使うアプリ」
    private(set) var focusAllows: [Data?] = []
    func shieldFocus(allow: Data?) {
        calls.append("focus")
        focusAllows.append(allow)
    }
    func unshieldFocus() { calls.append("unfocus") }
    func startReblockSchedule(_ schedule: ReblockSchedule) throws {
        calls.append("schedule")
        schedules.append(schedule)
    }
    func stopReblockSchedule() { calls.append("stop") }
    /// 登録したゲーム・SNS の時間のスケジュール（最後の分）
    private(set) var unblockSchedules: [ReblockSchedule]?
    func replaceUnblockSchedules(_ schedules: [ReblockSchedule]) { unblockSchedules = schedules }
    func shieldSummary() -> String { "" }
    func clearCalls() { calls = [] }
}

/// アプリのブロック（app-blocking.md、BLK-01・BLK-05〜09）。
@MainActor
struct AppModelBlockingTests {
    private let selection = Data("selection".utf8)

    private struct Fixture {
        let t: TestStore
        let blocking: FakeBlocking
        let blockStore: MemoryBlockStore
        let log: MemoryBlockEventLog
        let settings: MemorySettings
        let model: AppModel
    }

    /// 始めた状態（対象を選んでブロック中）の AppModel
    private func fixture(now: String = "2026-10-19T11:20", enabled: Bool = true,
                         state: BlockState? = nil, didShowIntro: Bool = true) throws -> Fixture {
        let t = try TestStore(now: jst(now))
        try t.seeded()
        let blocking = FakeBlocking()
        let blockStore = MemoryBlockStore()
        blockStore.state = state ?? BlockState(isEnabled: enabled)
        if enabled { blockStore.selection = selection }
        let log = MemoryBlockEventLog()
        let settings = MemorySettings()
        settings.didShowBlockingIntro = didShowIntro
        // 「始めた」はもう記録済みの端末（この版で初めて開いたときの記録は FocusBlockTests で確かめる）
        settings.didLogBlockStart = true
        let model = AppModel(store: t.store, clock: t.clock, timeZone: { tokyo }, settings: settings,
                             blocking: blocking, blockStore: blockStore, blockLog: log)
        return Fixture(t: t, blocking: blocking, blockStore: blockStore, log: log, settings: settings, model: model)
    }

    private func kinds(_ log: MemoryBlockEventLog) throws -> [BlockEvent.Kind] {
        try log.all().map(\.kind)
    }

    // MARK: 開く（BLK-07・BLK-08）

    @Test func unlockLiftsShieldForChosenMinutesAndRecords() throws {
        let f = try fixture()
        f.blocking.clearCalls()
        f.model.openHold()
        #expect(f.model.unlock(minutes: 15))

        let until = jst("2026-10-19T11:35")
        #expect(f.blockStore.state.unlockedUntil == until)
        #expect(f.model.blockState.unlockedUntil == until)
        // 前のスケジュールを止めてから、外して、戻すスケジュールを始める
        #expect(f.blocking.calls == ["stop", "unshield", "unfocus", "schedule"])
        #expect(f.blocking.schedules.last?.fireAt == until)
        let event = try #require(f.log.all().last)
        #expect(event.kind == .unlocked)
        #expect(event.unlockMinutes == 15)
        #expect(event.activeSessionId == nil)
        #expect(event.timeZoneId == "Asia/Tokyo")
        #expect(event.occurredAt == jst("2026-10-19T11:20"))
    }

    @Test(arguments: [5, 60])
    func unlockAcceptsEnds(minutes: Int) throws {
        let f = try fixture()
        #expect(f.model.unlock(minutes: minutes))
        #expect(f.blockStore.state.unlockedUntil == jst("2026-10-19T11:20").addingTimeInterval(Double(minutes) * 60))
    }

    @Test(arguments: [0, 7, 65])
    func unlockRejectsOtherMinutes(minutes: Int) throws {
        let f = try fixture()
        f.blocking.clearCalls()
        #expect(!f.model.unlock(minutes: minutes))
        #expect(f.blockStore.state.unlockedUntil == nil)
        #expect(f.blocking.calls.isEmpty)
        #expect(try f.log.all().isEmpty)
    }

    @Test func unlockRecordsRunningTimerEvenWhenPaused() throws {
        let f = try fixture()
        f.model.startUnplanned(category: try f.t.category("勉強"), minutes: 25)
        let id = try #require(f.model.running?.id)
        f.model.pause()
        #expect(f.model.unlock(minutes: 10))
        #expect(try f.log.all().last?.activeSessionId == id)
    }

    @Test func cannotUnlockAgainWhileUnlocked() throws {
        let f = try fixture()
        #expect(f.model.unlock(minutes: 15))
        f.t.clock.advance(5 * 60)
        f.blocking.clearCalls()
        #expect(!f.model.unlock(minutes: 30))
        #expect(f.blockStore.state.unlockedUntil == jst("2026-10-19T11:35"))
        #expect(f.blocking.calls.isEmpty)
        #expect(try kinds(f.log) == [.unlocked])
    }

    @Test func cannotUnlockBeforeStarting() throws {
        let f = try fixture(enabled: false)
        #expect(!f.model.unlock(minutes: 15))
        #expect(f.model.errorMessage == AppModel.notStartedMessage)
        #expect(try f.log.all().isEmpty)
    }

    // MARK: 戻す（BLK-07）

    @Test func reblockNowRestoresShieldAndRecordsManual() throws {
        let f = try fixture()
        f.model.unlock(minutes: 30)
        f.t.clock.advance(3 * 60)
        f.blocking.clearCalls()
        f.model.reblockNow()
        #expect(f.blockStore.state.unlockedUntil == nil)
        #expect(f.blocking.calls == ["stop", "shield", "unfocus"])
        let event = try #require(f.log.all().last)
        #expect(event.kind == .reblocked)
        #expect(event.reblockReason == .manual)
        // もう一度押しても二重に書かない
        f.model.reblockNow()
        #expect(try kinds(f.log) == [.unlocked, .reblocked])
    }

    @Test func expiredUnlockIsRestoredWhenAppComesBack() throws {
        let f = try fixture()
        f.model.unlock(minutes: 15)
        // 期限の1秒前はまだ開けたまま
        f.t.clock.set(jst("2026-10-19T11:34:59"))
        f.model.reload(quietly: true)
        #expect(f.blockStore.state.unlockedUntil != nil)
        // 期限ちょうどで戻す
        f.t.clock.set(jst("2026-10-19T11:35"))
        f.blocking.clearCalls()
        f.model.reload(quietly: true)
        #expect(f.blockStore.state.unlockedUntil == nil)
        #expect(f.blocking.calls == ["stop", "shield", "unfocus"])
        #expect(try f.log.all().last?.reblockReason == .appForeground)
    }

    @Test func alreadyRestoredByMonitorIsNotRecordedAgain() throws {
        let f = try fixture()
        f.model.unlock(minutes: 15)
        // 自動で戻すしくみが先に戻した（期限を消して記録した）
        f.blockStore.state.unlockedUntil = nil
        try f.log.append(BlockEvent(occurredAt: jst("2026-10-19T11:35"), timeZoneId: "Asia/Tokyo", kind: .reblocked,
                                    reblockReason: .expired))
        f.t.clock.set(jst("2026-10-20T08:00"))  // 翌朝
        f.model.reload(quietly: true)
        #expect(try kinds(f.log) == [.unlocked, .reblocked])
    }

    @Test func unlockSurvivesAcrossDayBoundary() throws {
        let f = try fixture(now: "2026-10-20T03:55")
        f.model.unlock(minutes: 15)
        f.t.clock.set(jst("2026-10-20T04:05"))
        f.model.reload(quietly: true)
        #expect(f.blockStore.state.unlockedUntil == jst("2026-10-20T04:10"))
        f.t.clock.set(jst("2026-10-20T04:10"))
        f.model.reload(quietly: true)
        #expect(f.blockStore.state.unlockedUntil == nil)
    }

    // MARK: 長押しの画面（BLK-08）

    @Test func closingHoldWithoutUnlockRecordsCancel() throws {
        let f = try fixture()
        f.model.openHold()
        #expect(f.model.holdRequest != nil)
        f.model.closeHold()
        #expect(f.model.holdRequest == nil)
        #expect(try kinds(f.log) == [.holdCancelled])
    }

    @Test func closingHoldAfterUnlockIsNotCancel() throws {
        let f = try fixture()
        f.model.openHold()
        f.model.unlock(minutes: 15)
        f.model.closeHold()
        // 開けている間に開き直して閉じても、やめたことにはしない
        f.model.openHold()
        f.model.closeHold()
        #expect(try kinds(f.log) == [.unlocked])
    }

    @Test func holdScreenOpensWithinTwoMinutesOfShieldRequest() throws {
        let f = try fixture()
        f.blockStore.state.unlockRequestedAt = jst("2026-10-19T11:18:30")
        f.model.checkUnlockRequest()
        #expect(f.model.holdRequest != nil)
        // 1回出したら消す（次に開いたときは出さない）
        #expect(f.blockStore.state.unlockRequestedAt == nil)
        f.model.closeHold()
        f.model.checkUnlockRequest()
        #expect(f.model.holdRequest == nil)
    }

    @Test func holdScreenNotOpenedAfterTwoMinutes() throws {
        let f = try fixture()
        f.blockStore.state.unlockRequestedAt = jst("2026-10-19T11:17:59")
        f.model.checkUnlockRequest()
        #expect(f.model.holdRequest == nil)
    }

    // MARK: 始める・最初の説明（BLK-01・BLK-09）

    @Test func introShownOnceWhenNotStarted() throws {
        let f = try fixture(enabled: false, didShowIntro: false)
        #expect(f.model.showsBlockingIntro)
        f.model.postponeBlocking()
        #expect(!f.model.showsBlockingIntro)
        #expect(f.settings.didShowBlockingIntro)
        f.model.reload()
        #expect(!f.model.showsBlockingIntro)
    }

    @Test func introNotShownWhenUnavailableOrStarted() throws {
        let started = try fixture(enabled: true, didShowIntro: false)
        #expect(!started.model.showsBlockingIntro)

        let t = try TestStore()
        try t.seeded()
        let blocking = FakeBlocking()
        blocking.isAvailable = false
        let settings = MemorySettings()
        let model = AppModel(store: t.store, clock: t.clock, timeZone: { tokyo }, settings: settings,
                             blocking: blocking, blockStore: MemoryBlockStore(), blockLog: MemoryBlockEventLog())
        #expect(!model.showsBlockingIntro)
    }

    @Test func startBlockingAsksPermissionThenShields() async throws {
        let f = try fixture(enabled: false, didShowIntro: false)
        f.blocking.status = .notDetermined
        #expect(await f.model.requestBlockingAuthorization() == .approved)
        #expect(f.settings.didShowBlockingIntro)
        f.blocking.clearCalls()
        #expect(f.model.saveBlockSelection(selection))
        #expect(f.blockStore.state.isEnabled)
        #expect(f.blockStore.selection == selection)
        #expect(f.blocking.calls == ["shield", "unfocus"])
    }

    @Test func emptySelectionDoesNotStart() throws {
        let f = try fixture(enabled: false)
        f.blocking.count = 0
        #expect(!f.model.saveBlockSelection(selection))
        #expect(!f.blockStore.state.isEnabled)
        #expect(f.model.errorMessage == AppModel.emptySelectionMessage)
    }

    @Test func changingSelectionWhileUnlockedWaitsUntilReblock() throws {
        let f = try fixture()
        f.model.unlock(minutes: 15)
        f.blocking.clearCalls()
        #expect(f.model.saveBlockSelection(Data("new".utf8)))
        #expect(f.blockStore.selection == Data("new".utf8))
        // 開けている間はかけない（戻すときに新しい選択でかける）
        #expect(!f.blocking.calls.contains("shield"))
    }

    @Test func reauthorizedBlockingIsShieldedAgain() throws {
        let f = try fixture()
        f.blocking.status = .denied
        f.model.refreshBlockingAuthorization()
        #expect(f.model.blockingAuthorization == .denied)
        #expect(f.blockStore.state.isEnabled)
        f.blocking.status = .approved
        f.blocking.clearCalls()
        f.model.refreshBlockingAuthorization()
        #expect(f.blocking.calls == ["shield", "unfocus"])
    }

    @Test func revokedAuthorizationIsReflectedWithoutTouchingShield() throws {
        let f = try fixture()
        f.blocking.clearCalls()
        f.blocking.status = .denied
        f.model.refreshBlockingAuthorization()
        #expect(f.model.blockingAuthorization == .denied)
        #expect(f.blocking.calls.isEmpty)
        #expect(f.blockStore.selection == selection)
    }

    @Test func reauthorizedWhileUnlockedWaitsUntilReblock() throws {
        let f = try fixture()
        f.model.unlock(minutes: 15)
        f.blocking.status = .denied
        f.model.refreshBlockingAuthorization()
        f.blocking.status = .approved
        f.blocking.clearCalls()
        f.model.refreshBlockingAuthorization()
        #expect(!f.blocking.calls.contains("shield"))
    }

    @Test func unreadableSelectionKeepsShieldAndAsksToPickAgain() throws {
        let f = try fixture()
        f.blocking.count = 0
        f.blocking.clearCalls()
        #expect(!f.model.unlock(minutes: 15))
        // 外していない（かけ直せないので）
        #expect(f.blocking.calls.isEmpty)
        #expect(f.blockStore.state.unlockedUntil == nil)
        #expect(f.blockStore.selection == nil)
        #expect(f.model.errorMessage == AppModel.unreadableSelectionMessage)
        #expect(!f.model.hasBlockSelection)
    }

    @Test func coldLaunchWithinTwoMinutesOpensHold() throws {
        let t = try TestStore(now: jst("2026-10-19T11:20"))
        try t.seeded()
        let blockStore = MemoryBlockStore()
        blockStore.state = BlockState(isEnabled: true, unlockRequestedAt: jst("2026-10-19T11:19"))
        blockStore.selection = selection
        let model = AppModel(store: t.store, clock: t.clock, timeZone: { tokyo }, settings: MemorySettings(),
                             blocking: FakeBlocking(), blockStore: blockStore, blockLog: MemoryBlockEventLog())
        #expect(model.holdRequest != nil)
        #expect(blockStore.state.unlockRequestedAt == nil)
    }

    @Test func holdScreenAtExactlyTwoMinutes() throws {
        let f = try fixture()
        f.blockStore.state.unlockRequestedAt = jst("2026-10-19T11:18")
        f.model.checkUnlockRequest()
        #expect(f.model.holdRequest != nil)
    }

    // MARK: シールドの差の材料（BLK-05）

    @Test func reloadWritesShieldSnapshotForToday() throws {
        let f = try fixture()
        let s = try #require(f.blockStore.raceSnapshot)
        #expect(s.dayKey == "2026-10-19")
        #expect(s.dayStart == jst("2026-10-19T04:00"))
        #expect(s.writtenAt == jst("2026-10-19T11:20"))
        #expect(!s.isFocusRunning)

        f.model.startUnplanned(category: try f.t.category("勉強"), minutes: nil)
        #expect(f.blockStore.raceSnapshot?.isFocusRunning == true)
        f.model.pause()
        #expect(f.blockStore.raceSnapshot?.isFocusRunning == false)
    }

    @Test func detoxTimerDoesNotCountOnShield() throws {
        let f = try fixture()
        f.model.startUnplanned(category: try f.t.category("休み"), minutes: nil)
        #expect(f.blockStore.raceSnapshot?.isFocusRunning == false)
    }
}
