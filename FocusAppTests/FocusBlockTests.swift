import Foundation
import Testing
@testable import FocusApp

/// 集中中の全部ブロック（app-blocking.md「集中中は全部ブロック」、BLK-02・BLK-04）と、
/// デトックスの材料になる記録（BLK-11）。
@MainActor
struct FocusBlockTests {
    private let selection = Data("selection".utf8)
    private let allow = Data("kindle".utf8)

    private struct Fixture {
        let t: TestStore
        let blocking: FakeBlocking
        let blockStore: MemoryBlockStore
        let log: MemoryBlockEventLog
        let settings: MemorySettings
        let model: AppModel
        /// 勉強（集中）
        @MainActor var focus: CategoryOption { model.categories[0] }
        /// 休み（デトックス）
        @MainActor var detox: CategoryOption { model.categories[4] }
    }

    private func fixture(now: String = "2026-10-19T11:20", enabled: Bool = true, state: BlockState? = nil,
                         allowSelection: Data? = nil, didLogStart: Bool = true,
                         lastAuthorized: Bool? = true) throws -> Fixture {
        let t = try TestStore(now: jst(now))
        try t.seeded()
        let blocking = FakeBlocking()
        let blockStore = MemoryBlockStore()
        blockStore.state = state ?? BlockState(isEnabled: enabled)
        if enabled { blockStore.selection = selection }
        blockStore.focusAllowSelection = allowSelection
        let log = MemoryBlockEventLog()
        let settings = MemorySettings()
        settings.didShowBlockingIntro = true
        settings.didLogBlockStart = didLogStart
        settings.lastBlockingAuthorized = lastAuthorized
        let model = AppModel(store: t.store, clock: t.clock, timeZone: { tokyo }, settings: settings,
                             blocking: blocking, blockStore: blockStore, blockLog: log)
        return Fixture(t: t, blocking: blocking, blockStore: blockStore, log: log, settings: settings, model: model)
    }

    // MARK: いつかける（BLK-04）

    @Test func focusTimerShieldsEverythingExceptAllowList() throws {
        let f = try fixture(allowSelection: allow)
        f.blocking.clearCalls()
        f.model.startUnplanned(category: f.focus, minutes: 25)

        #expect(f.blocking.calls == ["shield", "focus"])
        #expect(f.blocking.focusAllows == [allow])
        #expect(f.blockStore.state.isFocusBlocking)
        #expect(f.model.blockState.isFocusBlocking)
    }

    @Test func emptyAllowListShieldsEverything() throws {
        let f = try fixture(allowSelection: nil)
        f.model.startUnplanned(category: f.focus, minutes: nil)
        #expect(f.blocking.focusAllows == [nil])
    }

    @Test func detoxTimerKeepsOnlyUsualBlock() throws {
        let f = try fixture()
        f.blocking.clearCalls()
        f.model.startUnplanned(category: f.detox, minutes: 25)
        #expect(!f.blocking.calls.contains("focus"))
        #expect(!f.blockStore.state.isFocusBlocking)
    }

    @Test func notStartedBlockingNeverShieldsFocus() throws {
        let f = try fixture(enabled: false)
        f.model.startUnplanned(category: f.focus, minutes: 25)
        #expect(!f.blocking.calls.contains("focus"))
    }

    /// ブロックを始めていない間に集中を始め、タイマー中に始めた → すぐ全部ブロックもかかる
    @Test func startingBlockingDuringFocusShieldsFocusToo() throws {
        let f = try fixture(enabled: false)
        f.model.startUnplanned(category: f.focus, minutes: 25)
        f.blocking.clearCalls()
        #expect(f.model.saveBlockSelection(selection))
        #expect(f.blocking.calls == ["shield", "focus"])
    }

    @Test func pauseLiftsAndResumeRestores() throws {
        let f = try fixture()
        f.model.startUnplanned(category: f.focus, minutes: 25)
        f.blocking.clearCalls()

        f.t.clock.advance(10 * 60)
        f.model.pause()
        #expect(f.blocking.calls == ["shield", "unfocus"])
        #expect(!f.blockStore.state.isFocusBlocking)

        f.blocking.clearCalls()
        f.t.clock.advance(5 * 60)
        f.model.resume()
        #expect(f.blocking.calls == ["shield", "focus"])
        #expect(f.blockStore.state.isFocusBlocking)
    }

    @Test func endLiftsFocusBlock() throws {
        let f = try fixture()
        f.model.startUnplanned(category: f.focus, minutes: 25)
        f.blocking.clearCalls()
        f.t.clock.advance(30 * 60)
        f.model.end(reportedEnd: nil)
        #expect(f.blocking.calls == ["shield", "unfocus"])
        #expect(!f.blockStore.state.isFocusBlocking)
    }

    @Test func overtimeKeepsFocusBlock() throws {
        let f = try fixture()
        f.model.startUnplanned(category: f.focus, minutes: 25)
        f.blocking.clearCalls()
        // カウントダウンが0を過ぎて超過を数えている
        f.t.clock.advance(40 * 60)
        f.model.reload()
        #expect(f.blocking.calls.isEmpty)
        #expect(f.blockStore.state.isFocusBlocking)
    }

    @Test func reloadWithoutChangeDoesNotReapply() throws {
        let f = try fixture()
        f.model.startUnplanned(category: f.focus, minutes: 25)
        f.blocking.clearCalls()
        f.t.clock.advance(1 * 60)
        f.model.reload(quietly: true)
        #expect(f.blocking.calls.isEmpty)
    }

    /// 前の起動で集中のブロックをかけたまま落ち、タイマーの記録はもう終わっている → 開いたときに外す
    @Test func staleFocusBlockIsLiftedOnLaunch() throws {
        let f = try fixture(state: BlockState(isEnabled: true, isFocusBlocking: true))
        #expect(f.blocking.calls.contains("unfocus"))
        #expect(!f.blockStore.state.isFocusBlocking)
    }

    /// 落ちたあと、タイマーは動いたまま → 開いたときにかけ直す
    @Test func runningFocusTimerIsShieldedOnLaunch() throws {
        let t = try TestStore(now: jst("2026-10-19T11:20"))
        let categories = try t.seeded()
        _ = try t.store.start(StartRequest(category: categories[0], project: nil, planBlockId: nil, plannedEndAt: nil,
                                           plannedDurationSec: nil, timeZone: tokyo))
        let blocking = FakeBlocking()
        let blockStore = MemoryBlockStore()
        blockStore.state = BlockState(isEnabled: true)
        blockStore.selection = selection
        let settings = MemorySettings()
        settings.didShowBlockingIntro = true
        settings.didLogBlockStart = true
        settings.lastBlockingAuthorized = true
        _ = AppModel(store: t.store, clock: t.clock, timeZone: { tokyo }, settings: settings,
                     blocking: blocking, blockStore: blockStore, blockLog: MemoryBlockEventLog())
        #expect(blocking.calls.contains("focus"))
        #expect(blockStore.state.isFocusBlocking)
    }

    // MARK: 開けている間（BLK-07 と組み合わせ）

    @Test func unlockDuringFocusLiftsBothAndReblockRestoresBoth() throws {
        let f = try fixture()
        f.model.startUnplanned(category: f.focus, minutes: 60)
        f.blocking.clearCalls()

        f.model.openHold()
        #expect(f.model.unlock(minutes: 15))
        #expect(f.blocking.calls == ["stop", "unshield", "unfocus", "schedule"])
        // かけたい状態は覚えたまま（戻すときに使う）
        #expect(f.blockStore.state.isFocusBlocking)

        f.blocking.clearCalls()
        f.model.reblockNow()
        #expect(f.blocking.calls == ["stop", "shield", "focus"])
    }

    @Test func startingFocusWhileUnlockedWaitsForReblock() throws {
        let f = try fixture()
        f.model.openHold()
        #expect(f.model.unlock(minutes: 15))
        f.blocking.clearCalls()

        f.model.startUnplanned(category: f.focus, minutes: 25)
        #expect(!f.blocking.calls.contains("focus"))
        #expect(f.blockStore.state.isFocusBlocking)

        // 期限が過ぎて GhostPace を開いた → いつもの分と全部ブロックの両方をかけ直す
        f.blocking.clearCalls()
        f.t.clock.advance(16 * 60)
        f.model.reload()
        #expect(f.blocking.calls == ["stop", "shield", "focus"])
    }

    @Test func pausingWhileUnlockedReblocksOnlyUsual() throws {
        let f = try fixture()
        f.model.startUnplanned(category: f.focus, minutes: 60)
        f.model.openHold()
        #expect(f.model.unlock(minutes: 15))
        f.model.pause()
        #expect(!f.blockStore.state.isFocusBlocking)

        f.blocking.clearCalls()
        f.model.reblockNow()
        #expect(f.blocking.calls == ["stop", "shield", "unfocus"])
    }

    // MARK: 集中中も使うアプリ（BLK-02）

    @Test func savesAllowListIncludingEmpty() throws {
        let f = try fixture()
        f.model.saveFocusAllowSelection(allow)
        #expect(f.blockStore.focusAllowSelection == allow)
        #expect(f.model.focusAllowCount == 2)

        // 空でも保存できる（空なら全部ブロック）
        f.blocking.count = 0
        f.model.saveFocusAllowSelection(Data("empty".utf8))
        #expect(f.blockStore.focusAllowSelection == nil)
        #expect(f.model.focusAllowCount == 0)
        #expect(f.model.errorMessage == nil)
    }

    // MARK: 許可を取り戻したとき

    @Test func regainedAuthorizationRestoresFocusBlockToo() throws {
        let f = try fixture()
        f.model.startUnplanned(category: f.focus, minutes: 25)
        f.blocking.status = .denied
        f.model.refreshBlockingAuthorization()
        f.blocking.clearCalls()

        f.blocking.status = .approved
        f.model.refreshBlockingAuthorization()
        #expect(f.blocking.calls == ["shield", "focus"])
    }

    // MARK: デトックスの材料の記録（BLK-11）

    @Test func firstSelectionRecordsStarted() throws {
        let f = try fixture(enabled: false, didLogStart: false)
        #expect(f.model.saveBlockSelection(selection))
        #expect(try f.log.all().map(\.kind) == [.started])
        #expect(f.settings.didLogBlockStart)

        // 選び直しでは書かない
        #expect(f.model.saveBlockSelection(selection))
        #expect(try f.log.all().map(\.kind) == [.started])
    }

    /// この版を最初に開いたとき、もう始めていれば「始めた」を1回だけ書く（そこからデトックスを数える）
    @Test func alreadyEnabledRecordsStartedOnceOnLaunch() throws {
        let f = try fixture(didLogStart: false)
        #expect(try f.log.all().map(\.kind) == [.started])
        #expect(try f.log.all().first?.occurredAt == jst("2026-10-19T11:20"))
        f.model.reload()
        #expect(try f.log.all().map(\.kind) == [.started])
    }

    @Test func notEnabledDoesNotRecordStartedOnLaunch() throws {
        let f = try fixture(enabled: false, didLogStart: false)
        #expect(try f.log.all().isEmpty)
        #expect(!f.settings.didLogBlockStart)
    }

    @Test func recordsAuthorizationLostAndRestored() throws {
        let f = try fixture()
        f.blocking.status = .denied
        f.t.clock.advance(5 * 60)
        f.model.refreshBlockingAuthorization()
        f.model.refreshBlockingAuthorization()  // 2回目は書かない
        f.blocking.status = .approved
        f.t.clock.advance(5 * 60)
        f.model.refreshBlockingAuthorization()

        let events = try f.log.all()
        #expect(events.map(\.kind) == [.authorizationLost, .authorizationRestored])
        #expect(events.map(\.occurredAt) == [jst("2026-10-19T11:25"), jst("2026-10-19T11:30")])
        // 外れた時刻は分からないので、前に許可を確かめた時刻（開いたとき）から外れていたとみなす
        #expect(events.map(\.sinceAt) == [jst("2026-10-19T11:20"), nil])
        #expect(f.settings.lastBlockingAuthorized == true)
        #expect(f.settings.lastBlockingAuthorizedAt == jst("2026-10-19T11:30"))
    }

    /// iPhone が起動直後などに一瞬「未確認」と返しても「外れた」と書かない（2026-10-03、ポイントが止まる原因）
    @Test func briefNotDeterminedIsNotRecorded() throws {
        let f = try fixture()
        f.blocking.status = .notDetermined
        f.t.clock.advance(5 * 60)
        f.model.refreshBlockingAuthorization()
        f.blocking.status = .approved
        f.t.clock.advance(1)
        f.model.refreshBlockingAuthorization()
        #expect(try f.log.all().filter { $0.kind == .authorizationLost || $0.kind == .authorizationRestored }.isEmpty)
        #expect(f.settings.lastBlockingAuthorized == true)
    }

    /// 「未確認」が1分以上続いたら、前に確かめた時刻から外れていたと書く
    @Test func notDeterminedForAMinuteIsRecorded() throws {
        let f = try fixture()
        f.blocking.status = .notDetermined
        f.t.clock.advance(5 * 60)
        f.model.refreshBlockingAuthorization()
        f.t.clock.advance(59)
        f.model.refreshBlockingAuthorization()
        #expect(try f.log.all().filter { $0.kind == .authorizationLost }.isEmpty)
        f.t.clock.advance(1)
        f.model.refreshBlockingAuthorization()
        let lost = try f.log.all().filter { $0.kind == .authorizationLost }
        #expect(lost.map(\.occurredAt) == [jst("2026-10-19T11:26")])
        #expect(lost.map(\.sinceAt) == [jst("2026-10-19T11:20")])
    }

    /// 閉じている間に許可が外れていた → 開いたときに気づいて書く
    @Test func lostWhileClosedIsRecordedOnLaunch() throws {
        let t = try TestStore(now: jst("2026-10-19T11:20"))
        try t.seeded()
        let blocking = FakeBlocking()
        blocking.status = .denied
        let blockStore = MemoryBlockStore()
        blockStore.state = BlockState(isEnabled: true)
        blockStore.selection = selection
        let log = MemoryBlockEventLog()
        let settings = MemorySettings()
        settings.didShowBlockingIntro = true
        settings.didLogBlockStart = true
        settings.lastBlockingAuthorized = true
        settings.lastBlockingAuthorizedAt = jst("2026-10-18T22:10")
        _ = AppModel(store: t.store, clock: t.clock, timeZone: { tokyo }, settings: settings,
                     blocking: blocking, blockStore: blockStore, blockLog: log)
        let events = try log.all()
        #expect(events.map(\.kind) == [.authorizationLost])
        #expect(events.first?.sinceAt == jst("2026-10-18T22:10"))
        #expect(settings.lastBlockingAuthorized == false)
        #expect(settings.lastBlockingAuthorizedAt == jst("2026-10-18T22:10"))
    }

    /// 開けた時間が終わって戻すときに選択を読めなかった → 選び直すまでブロックがないので記録する
    @Test func unreadableSelectionOnReblockRecordsSelectionLost() throws {
        let f = try fixture()
        f.model.openHold()
        #expect(f.model.unlock(minutes: 15))
        f.blocking.count = 0
        f.model.reblockNow()
        #expect(f.blockStore.selection == nil)
        #expect(try f.log.all().map(\.kind).suffix(2) == [.selectionLost, .reblocked])

        // 選び直すと「始めた」
        f.blocking.count = 2
        #expect(f.model.saveBlockSelection(selection))
        #expect(try f.log.all().map(\.kind).last == .started)
    }

    /// 開こうとして選択が読めなかったときは外さない（ブロックは残る）ので、読めなくなったとは書かない
    @Test func unreadableSelectionOnUnlockDoesNotRecordSelectionLost() throws {
        let f = try fixture()
        f.blocking.count = 0
        #expect(!f.model.unlock(minutes: 15))
        #expect(!(try f.log.all().map(\.kind).contains(.selectionLost)))
    }

    @Test func authorizationChangesBeforeStartingAreNotRecorded() throws {
        let f = try fixture(enabled: false, didLogStart: false, lastAuthorized: nil)
        f.blocking.status = .denied
        f.model.refreshBlockingAuthorization()
        #expect(try f.log.all().isEmpty)
    }

    // MARK: ほかの始め方・終え方（レビューで足した）

    private func block(_ start: String, _ minutes: Int, _ category: CategoryOption) -> PlanBlockDraft {
        PlanBlockDraft(start: jst(start), minutes: minutes, category: category)
    }

    /// 朝の計画の勉強のブロックから始めても全部ブロック、休みのブロックからならかけない
    @Test(arguments: [(0, true), (4, false)])
    func plannedBlockFollowsCategory(categoryIndex: Int, shields: Bool) throws {
        let f = try fixture(now: "2026-10-19T09:00")
        f.model.confirmPlan(PlanDraft(blocks: [block("2026-10-19T09:00", 60, f.model.categories[categoryIndex])]))
        f.t.clock.set(jst("2026-10-19T09:10"))
        f.model.reload()
        let current = try #require(f.model.snapshot.currentBlock)
        f.blocking.clearCalls()
        f.model.startPlanned(block: current)
        #expect(f.blocking.calls.contains("focus") == shields)
        #expect(f.blockStore.state.isFocusBlocking == shields)
    }

    /// 止め忘れの確認が出ている間は全部ブロックのまま。終了時刻を答えると外れる
    @Test func forgottenStopKeepsBlockUntilAnswered() throws {
        let f = try fixture()
        f.model.startUnplanned(category: f.focus, minutes: 25)
        f.t.clock.advance(3 * 3600)
        f.model.reload()
        f.blocking.clearCalls()
        f.model.requestEnd()
        #expect(f.model.endTimeCheck != nil)
        #expect(f.blockStore.state.isFocusBlocking)
        #expect(!f.blocking.calls.contains("unfocus"))

        f.model.end(reportedEnd: jst("2026-10-19T11:50"))
        #expect(f.model.running == nil)
        #expect(!f.blockStore.state.isFocusBlocking)
        #expect(f.blocking.calls.last == "unfocus")
    }

    /// 1分未満で記録しなかったときも外れる
    @Test func discardedShortSessionLiftsBlock() throws {
        let f = try fixture()
        f.model.startUnplanned(category: f.focus, minutes: 25)
        f.t.clock.advance(30)
        f.model.end(reportedEnd: nil)
        #expect(f.model.notice == AppModel.discardedNotice)
        #expect(!f.blockStore.state.isFocusBlocking)
        #expect(f.blocking.calls.last == "unfocus")
    }

    /// 朝4:00 をまたいでもタイマーが動いていればかけたまま、終えると外れる
    @Test func focusBlockSurvivesFourAm() throws {
        let f = try fixture(now: "2026-10-20T03:50")
        f.model.startUnplanned(category: f.focus, minutes: nil)
        f.blocking.clearCalls()
        for time in ["2026-10-20T03:59", "2026-10-20T04:00", "2026-10-20T04:01"] {
            f.t.clock.set(jst(time))
            f.model.reload(quietly: true)
            #expect(f.model.running != nil)
            #expect(f.blockStore.state.isFocusBlocking)
        }
        #expect(!f.blocking.calls.contains("unfocus"))
        f.model.end(reportedEnd: nil)
        #expect(!f.blockStore.state.isFocusBlocking)
    }

    /// 一時停止中に開け、開けている間に再開 → 戻すときに全部ブロックもかかる
    @Test func resumingWhileUnlockedRestoresFocusOnReblock() throws {
        let f = try fixture()
        f.model.startUnplanned(category: f.focus, minutes: 60)
        f.model.pause()
        f.model.openHold()
        #expect(f.model.unlock(minutes: 15))
        f.model.resume()
        #expect(f.blockStore.state.isFocusBlocking)
        f.blocking.clearCalls()
        f.model.reblockNow()
        #expect(f.blocking.calls == ["stop", "shield", "focus"])
    }

    @Test func savingAllowListWhileUnlockedDoesNotShield() throws {
        let f = try fixture()
        f.model.startUnplanned(category: f.focus, minutes: 60)
        f.model.openHold()
        #expect(f.model.unlock(minutes: 15))
        f.blocking.clearCalls()
        f.model.saveFocusAllowSelection(allow)
        #expect(!f.blocking.calls.contains("focus"))
        #expect(!f.blocking.calls.contains("shield"))
    }

    @Test func savingAllowListWhileFocusingReappliesWithNewList() throws {
        let f = try fixture()
        f.model.startUnplanned(category: f.focus, minutes: 60)
        f.blocking.clearCalls()
        f.model.saveFocusAllowSelection(allow)
        #expect(f.blocking.calls == ["shield", "focus"])
        #expect(f.blocking.focusAllows.last == allow)
    }

    /// 前面に戻って読み直したとき（reload が先、許可の読み直しが後）も、外れた時刻は前に確かめた時刻のまま
    @Test func reloadBeforeAuthorizationRefreshKeepsSince() throws {
        let f = try fixture()
        f.blocking.status = .denied
        f.t.clock.advance(8 * 3600)
        f.model.reload(quietly: true)
        f.model.refreshBlockingAuthorization()
        let events = try f.log.all()
        #expect(events.map(\.kind) == [.authorizationLost])
        #expect(events.first?.sinceAt == jst("2026-10-19T11:20"))
    }

    /// シミュレーターなど許可が入っていない版では記録しない
    @Test func unavailableRecordsNothing() throws {
        let f = try fixture(didLogStart: false, lastAuthorized: nil)
        f.blocking.status = .unavailable
        f.model.reload()
        f.model.refreshBlockingAuthorization()
        // fixture の時点（許可あり）で「始めた」だけは書かれている
        #expect(try f.log.all().map(\.kind) == [.started])
    }

    /// 許可がないときはかけない（許可が戻ったらかける）
    @Test func notAuthorizedDoesNotShield() throws {
        let f = try fixture()
        f.blocking.status = .denied
        f.blocking.clearCalls()
        f.model.startUnplanned(category: f.focus, minutes: 25)
        #expect(!f.blocking.calls.contains("focus"))
        #expect(f.blockStore.state.isFocusBlocking)
    }
}

/// 本体と拡張で共有するもの（集中中の全部ブロック）。
struct FocusBlockSharedTests {
    private let until = jst("2026-10-19T11:35")

    /// 前の版で保存した状態（isFocusBlocking がない）も読める
    @Test func decodesStateWithoutFocusField() throws {
        let old = Data(#"{"isEnabled":true,"unlockedUntil":781583700}"#.utf8)
        let state = try JSONDecoder().decode(BlockState.self, from: old)
        #expect(state.isEnabled)
        #expect(!state.isFocusBlocking)
        #expect(state.unlockedUntil != nil)
    }

    @Test func reblockRestoresFocusShieldWhenFocusing() throws {
        let store = MemoryBlockStore()
        store.state = BlockState(isEnabled: true, unlockedUntil: until, isFocusBlocking: true)
        store.selection = Data("sel".utf8)
        store.focusAllowSelection = Data("kindle".utf8)
        var focused: [Data?] = []
        #expect(BlockReblock.run(store: store, log: MemoryBlockEventLog(), now: until, timeZone: tokyo, reason: .expired,
                                 focusShield: { focused.append($0) }) { _ in true })
        #expect(focused == [Data("kindle".utf8)])
    }

    @Test func reblockSkipsFocusShieldWhenNotFocusing() throws {
        let store = MemoryBlockStore()
        store.state = BlockState(isEnabled: true, unlockedUntil: until)
        store.selection = Data("sel".utf8)
        var focused = 0
        #expect(BlockReblock.run(store: store, log: MemoryBlockEventLog(), now: until, timeZone: tokyo, reason: .expired,
                                 focusShield: { _ in focused += 1 }) { _ in true })
        #expect(focused == 0)
    }

    @Test func shieldTitleDuringFocus() {
        let calendar = Calendar.app(timeZone: tokyo)
        #expect(ShieldText.make(snapshot: nil, now: until, calendar: calendar, isFocusBlocking: true).title == "集中中はブロック中")
        #expect(ShieldText.make(snapshot: nil, now: until, calendar: calendar, isFocusBlocking: false).title
                == "ゲームと SNS はブロック中")
    }

    // MARK: 決定表（BLK-12、app-blocking.md「今かかるブロック」）

    @Test(arguments: [
        // 始めた, 選択あり, 許可あり, 開けている, 集中中 → いつもの, 全部
        (false, true, true, false, true, false, false),
        (true, false, true, false, true, false, false),
        (true, true, false, false, true, false, false),
        (true, true, true, true, true, false, false),
        (true, true, true, false, true, true, true),
        (true, true, true, false, false, true, false),
    ])
    func decisionTable(enabled: Bool, hasSelection: Bool, authorized: Bool, unlocked: Bool, focusing: Bool,
                       usual: Bool, focus: Bool) {
        let state = BlockState(isEnabled: enabled, unlockedUntil: unlocked ? until : nil, isFocusBlocking: focusing)
        let plan = BlockPolicy.shields(state, hasSelection: hasSelection, authorized: authorized,
                                       now: until.addingTimeInterval(-60))
        #expect(plan == ShieldPlan(usual: usual, focus: focus))
    }

    @Test func decisionTableAtDeadlineBlocksAgain() {
        let state = BlockState(isEnabled: true, unlockedUntil: until, isFocusBlocking: true)
        #expect(BlockPolicy.shields(state, hasSelection: true, authorized: true, now: until) == ShieldPlan(usual: true, focus: true))
    }

    // MARK: 保存（拡張と共有する置き場・端末の設定）

    @Test func userDefaultsStoreKeepsFocusAllowSelection() throws {
        let suite = "block-test-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        let store = UserDefaultsBlockStore(defaults: d)
        store.selection = Data("sel".utf8)
        store.focusAllowSelection = Data("kindle".utf8)
        let other = UserDefaultsBlockStore(defaults: try #require(UserDefaults(suiteName: suite)))
        #expect(other.focusAllowSelection == Data("kindle".utf8))
        #expect(other.selection == Data("sel".utf8))
        other.focusAllowSelection = nil
        #expect(store.focusAllowSelection == nil)
        #expect(store.selection == Data("sel".utf8))
        d.removePersistentDomain(forName: suite)
    }

    @Test func stateRoundTripsFocusFlag() throws {
        let state = BlockState(isEnabled: true, isFocusBlocking: true)
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(BlockState.self, from: data) == state)
    }

    /// 前の版の記録（sinceAt がない行）も読める
    @Test func decodesOldEventWithoutSince() throws {
        let line = Data(#"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","occurredAt":781583700,"timeZoneId":"Asia/Tokyo","kind":"unlocked","unlockMinutes":15}"#.utf8)
        let event = try JSONDecoder().decode(BlockEvent.self, from: line)
        #expect(event.kind == .unlocked)
        #expect(event.sinceAt == nil)
    }

    @MainActor
    @Test func settingsKeepBlockingFacts() throws {
        let suite = "settings-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = UserDefaultsSettings(defaults: defaults)
        #expect(!settings.didLogBlockStart)
        #expect(settings.lastBlockingAuthorized == nil)
        #expect(settings.lastBlockingAuthorizedAt == nil)
        settings.didLogBlockStart = true
        settings.lastBlockingAuthorized = false
        settings.lastBlockingAuthorizedAt = until
        let reopened = UserDefaultsSettings(defaults: try #require(UserDefaults(suiteName: suite)))
        #expect(reopened.didLogBlockStart)
        // false と「まだ見ていない」（nil）を取り違えない
        #expect(reopened.lastBlockingAuthorized == false)
        #expect(reopened.lastBlockingAuthorizedAt == until)
        reopened.lastBlockingAuthorized = nil
        #expect(settings.lastBlockingAuthorized == nil)
        defaults.removePersistentDomain(forName: suite)
    }
}
