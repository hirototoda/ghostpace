import Foundation

/// 長押しの画面を出しているとき。
struct HoldRequest: Identifiable, Equatable {
    var id = UUID()
    /// 開けている間に開いた（残り時間と「今すぐ戻す」だけを出す。閉じても「やめた」にしない）
    var startedUnlocked: Bool
    var didUnlock = false
}

/// アプリのブロック（docs/product/features/app-blocking.md、BLK-01・BLK-02・BLK-04〜09・BLK-11）。
extension AppModel {
    var isBlockingStarted: Bool { blockState.isEnabled }
    var hasBlockSelection: Bool { blockStore.selection != nil }
    /// 選んでいる対象（FamilyActivitySelection を JSON にしたもの）
    var blockSelection: Data? { blockStore.selection }

    /// 開けている期限。過ぎていれば nil
    var unlockedUntil: Date? {
        BlockPolicy.isUnlocked(blockState, now: clock.now()) ? blockState.unlockedUntil : nil
    }

    /// 読み直すたびに呼ぶ：集中中の全部ブロックをタイマーに合わせる、期限切れなら戻す、シールドの差の材料を書く、
    /// 最初の説明を出すか決める、デトックスの材料（始めた・許可）を記録する
    func refreshBlocking(now: Date) {
        blockState = blockStore.state
        syncUnblockWindows(now: now)
        syncFocusBlock(now: now)
        recordBlockingFacts(now: now)
        if BlockPolicy.isExpired(blockState, now: now) {
            restoreShield(now: now, reason: .appForeground)
        }
        blockStore.raceSnapshot = shieldRaceSnapshot()
        if blocking.isAvailable, !blockSettingsDidShowIntro, !blockState.isEnabled {
            showsBlockingIntro = true
        }
    }

    // MARK: 長押しの画面（BLK-08）

    func openHold() {
        holdRequest = HoldRequest(startedUnlocked: BlockPolicy.isUnlocked(blockState, now: clock.now()))
    }

    /// 長押しの画面を閉じる。開けずに閉じたら「やめた」を記録する
    func closeHold() {
        guard let request = holdRequest else { return }
        if !request.startedUnlocked, !request.didUnlock {
            record(.holdCancelled)
        }
        holdRequest = nil
    }

    /// 前面に来たとき：シールドの「開く」から2分以内なら長押しの画面を出す
    func checkUnlockRequest() {
        var state = blockStore.state
        guard state.unlockRequestedAt != nil else { return }
        let wants = BlockPolicy.wantsHoldScreen(state, now: clock.now())
        state.unlockRequestedAt = nil
        save(state)
        if wants, holdRequest == nil { openHold() }
    }

    // MARK: 開く・戻す（BLK-07）

    /// 3秒の長押しと5秒の数えが終わった。選んだ長さだけ外す。開けなければ false
    @discardableResult
    func unlock(minutes: Int) -> Bool {
        let now = clock.now()
        var state = blockStore.state
        BlockDebugTrace.add("unlock(\(minutes)) enabled=\(state.isEnabled) until=\(String(describing: state.unlockedUntil))", now: now)
        guard state.isEnabled else {
            errorMessage = Self.notStartedMessage
            return false
        }
        guard !BlockPolicy.isUnlocked(state, now: now),
              let until = BlockPolicy.unlockedUntil(now: now, minutes: minutes),
              let schedule = BlockPolicy.reblockSchedule(now: now, minutes: minutes) else {
            BlockDebugTrace.add("unlock: already unlocked or bad minutes", now: now)
            return false
        }
        // 対象を読めないと、外したあとにかけ直せない。外さずに選び直してもらう
        guard let selection = blockStore.selection, blocking.selectionCount(selection) > 0 else {
            BlockDebugTrace.add("unlock: selection unreadable", now: now)
            blockStore.selection = nil
            errorMessage = Self.unreadableSelectionMessage
            return false
        }
        blocking.stopReblockSchedule()
        state.unlockedUntil = until
        state.unlockRequestedAt = nil
        save(state)
        applyShields(now: now)
        BlockDebugTrace.add("after unshield: \(blocking.shieldSummary())", now: now)
        // スケジュールを始められなくても、GhostPace を開いたときに期限を見て戻す
        do {
            try blocking.startReblockSchedule(schedule)
            BlockDebugTrace.add("schedule ok \(schedule.start)…\(schedule.end) warn=\(String(describing: schedule.warningMinutes))", now: now)
        } catch {
            BlockDebugTrace.add("schedule failed: \(error)", now: now)
        }
        record(.unlocked, minutes: minutes, session: running?.id)
        holdRequest?.didUnlock = true
        return true
    }

    /// 「今すぐ戻す」
    func reblockNow() {
        guard blockStore.state.unlockedUntil != nil else { return }
        restoreShield(now: clock.now(), reason: .manual)
    }

    // MARK: 始める（BLK-01・BLK-09）

    /// 最初の説明の「あとで」。二度と自動では出さない
    func postponeBlocking() {
        blockSettingsDidShowIntro = true
        showsBlockingIntro = false
    }

    /// Screen Time の許可を聞く（最初の説明の「続ける」、設定の「始める」）
    func requestBlockingAuthorization() async -> BlockingAuthorization {
        postponeBlocking()
        blockingAuthorization = await blocking.requestAuthorization()
        return blockingAuthorization
    }

    /// 選択画面で選んだ対象を保存して始める。1つも選んでいなければ始めない
    @discardableResult
    func saveBlockSelection(_ selection: Data) -> Bool {
        guard blocking.selectionCount(selection) > 0 else {
            errorMessage = Self.emptySelectionMessage
            return false
        }
        // 対象がない状態から選んだら「始めた」（初めて・読めなくなって選び直した）
        let isStart = !blockStore.state.isEnabled || blockStore.selection == nil
        blockStore.selection = selection
        var state = blockStore.state
        state.isEnabled = true
        state.isFocusBlocking = isFocusTimerRunning
        save(state)
        if isStart {
            record(.started)
            blockSettingsDidLogStart = true
            noteAuthorization(blocking.authorization(), now: clock.now(), recordsChange: false)
            // 許可がなかった間に登録できなかったゲーム・SNS の時間を登録し直す（かけるのは下でまとめて）
            registeredUnblockSchedules = false
            updateUnblockWindows(now: clock.now())
        }
        // 開けている間はかけない（戻すときに新しい選択でかける）
        applyShields(now: clock.now())
        return true
    }

    #if DEBUG
    /// 実機で流れを確かめるための、新しい順のブロックの記録（Debug の版の設定にだけ出す）
    func recentBlockEvents(limit: Int = 8) -> [BlockEvent] {
        Array(((try? blockLog.all()) ?? []).suffix(limit).reversed())
    }
    #endif

    /// 選んでいる数（設定に出す）
    var blockSelectionCount: Int {
        blockStore.selection.map { blocking.selectionCount($0) } ?? 0
    }

    // MARK: 集中中の全部ブロック（BLK-02・BLK-04）

    /// 集中中も使うアプリ（FamilyActivitySelection を JSON にしたもの）
    var focusAllowSelection: Data? { blockStore.focusAllowSelection }

    /// 集中中も使うアプリの数（設定に出す）
    var focusAllowCount: Int {
        blockStore.focusAllowSelection.map { blocking.selectionCount($0) } ?? 0
    }

    /// 集中中も使うアプリを保存する。空でもよい（空なら全部ブロック）。全部ブロック中ならかけ直す
    func saveFocusAllowSelection(_ selection: Data) {
        blockStore.focusAllowSelection = blocking.selectionCount(selection) > 0 ? selection : nil
        if blockStore.state.isFocusBlocking { applyShields(now: clock.now()) }
    }

    /// 集中のタイマーが動いていて一時停止していない
    private var isFocusTimerRunning: Bool {
        running.map { $0.countsAsFocus && !$0.session.isPaused } ?? false
    }

    /// タイマーが変わっていたら覚え直して、決定表でかけ直す（変わっていなければ何もしない）
    private func syncFocusBlock(now: Date) {
        var state = blockStore.state
        let wants = isFocusTimerRunning
        guard wants != state.isFocusBlocking else { return }
        state.isFocusBlocking = wants
        save(state)
        applyShields(now: now)
    }

    /// 決定表（BlockPolicy.shields）のとおりに、いつものブロックと集中中の全部ブロックをかける・外す。
    /// かける・外すのはここだけ（拡張は BlockReblock・ShieldControl.applyForUnblockSignal）。
    /// ゲーム・SNS の時間で外した・戻したが変われば記録する（BLK-11）
    private func applyShields(now: Date) {
        let selection = blockStore.selection
        let authorized = blocking.authorization() == .approved
        UnblockLog.note(store: blockStore, log: blockLog, authorized: authorized, now: now, timeZone: calendar.timeZone)
        blockState = blockStore.state
        let plan = BlockPolicy.shields(blockStore.state, hasSelection: selection != nil, authorized: authorized, now: now)
        if plan.usual, let selection { blocking.shield(selection: selection) } else { blocking.unshield() }
        if plan.focus { blocking.shieldFocus(allow: blockStore.focusAllowSelection) } else { blocking.unshieldFocus() }
    }

    // MARK: ゲーム・SNS の時間（BLK-10）

    /// 今日の確定した計画のゲーム・SNS の時間を、拡張と共有する置き場に書き、iPhone のスケジュールを登録し直す。
    /// 変わっていなくても、時間の始まり・終わりをまたいでいたら（合図が届かなかったとき）決定表でかけ直す
    private func syncUnblockWindows(now: Date) {
        let state = blockStore.state
        if updateUnblockWindows(now: now)
            || BlockPolicy.isUnblocking(state, hasSelection: blockStore.selection != nil,
                                        authorized: blocking.authorization() == .approved, now: now) != state.isUnblocking {
            applyShields(now: now)
        }
    }

    /// 窓を書き、変わったか、この起動でまだ登録していなければ iPhone のスケジュールを登録し直す。窓が変わったら true
    @discardableResult
    private func updateUnblockWindows(now: Date) -> Bool {
        var state = blockStore.state
        let windows = BlockPolicy.mergedWindows(confirmedUnblocks.map { UnblockWindow(start: $0.start, end: $0.end) })
        let changed = windows != state.unblockWindows
        if changed {
            state.unblockWindows = windows
            save(state)
        }
        if changed || !registeredUnblockSchedules {
            blocking.replaceUnblockSchedules(BlockPolicy.unblockSchedules(windows, now: now))
            registeredUnblockSchedules = true
        }
        return changed
    }

    /// 今ゲーム・SNS の時間で開いているなら、その終わり（長押しの画面に出す。集中中・開けている間は nil）
    var unblockedUntil: Date? {
        let now = clock.now()
        let state = blockStore.state
        guard BlockPolicy.isUnblocking(state, hasSelection: blockStore.selection != nil,
                                       authorized: blocking.authorization() == .approved, now: now) else { return nil }
        return BlockPolicy.unblockWindowEnd(state, now: now)
    }

    // MARK: デトックスの材料（BLK-11）

    /// 始めていれば「始めた」を1回だけ書く（この版より前から始めていた端末のため）。
    /// 許可が前に見たときと変わっていれば、気づいた今の時刻で「外れた／戻った」を書く
    private func recordBlockingFacts(now: Date) {
        // 画面に出している許可（blockingAuthorization）は前面に来たときに読み直すので、ここでは今の許可を直接読む
        // （古い値で「確かめた」としてしまうと、外れた時刻が実際より新しくなる）
        let authorization = blocking.authorization()
        guard blockState.isEnabled, authorization != .unavailable else { return }
        if !blockSettingsDidLogStart {
            record(.started)
            blockSettingsDidLogStart = true
        }
        noteAuthorization(authorization, now: now, recordsChange: true)
    }

    /// 「未確認」がこれだけ続いたら許可が外れたとみなす（「拒否」はすぐ）
    static let authorizationDoubtLimit: TimeInterval = 60

    /// 許可を覚える。前に見たときと変わっていれば「外れた／戻った」を書く（外れたときは前に確かめた時刻も）。
    /// 許可があった後の「未確認」は、iPhone が一瞬そう返すことがあるので1分続くまで待つ（2026-10-03）
    private func noteAuthorization(_ authorization: BlockingAuthorization, now: Date, recordsChange: Bool) {
        if authorization == .notDetermined, blockSettingsLastAuthorized == true {
            let since = authorizationDoubtSince ?? now
            authorizationDoubtSince = since
            if now.timeIntervalSince(since) < Self.authorizationDoubtLimit { return }
        } else {
            authorizationDoubtSince = nil
        }
        let authorized = authorization == .approved
        if recordsChange, let last = blockSettingsLastAuthorized, last != authorized {
            record(authorized ? .authorizationRestored : .authorizationLost,
                   since: authorized ? nil : blockSettingsLastAuthorizedAt)
        }
        blockSettingsLastAuthorized = authorized
        if authorized { blockSettingsLastAuthorizedAt = now }
    }

    /// 前面に来たとき：許可の状態を読み直す。許可し直されたらブロックし直す
    func refreshBlockingAuthorization() {
        let previous = blockingAuthorization
        blockingAuthorization = blocking.authorization()
        if blockingAuthorization == .approved, previous != .approved {
            registeredUnblockSchedules = false
            updateUnblockWindows(now: clock.now())
            applyShields(now: clock.now())
        }
        recordBlockingFacts(now: clock.now())
    }

    // MARK: 内部

    private func restoreShield(now: Date, reason: BlockEvent.ReblockReason) {
        var state = blockStore.state
        guard state.unlockedUntil != nil else { return }
        BlockDebugTrace.add("app reblock (\(reason.rawValue))", now: now)
        blocking.stopReblockSchedule()
        if state.isEnabled, let selection = blockStore.selection, blocking.selectionCount(selection) == 0 {
            // 読めない選択は消して、設定で選び直してもらう
            blockStore.selection = nil
            record(.selectionLost)
        }
        state.unlockedUntil = nil
        save(state)
        applyShields(now: now)
        record(.reblocked, reason: reason)
    }

    private func save(_ state: BlockState) {
        blockStore.state = state
        blockState = state
    }

    private func record(_ kind: BlockEvent.Kind, minutes: Int? = nil, reason: BlockEvent.ReblockReason? = nil,
                        session: UUID? = nil, since: Date? = nil) {
        try? blockLog.append(BlockEvent(occurredAt: clock.now(), timeZoneId: calendar.timeZone.identifier, kind: kind,
                                        unlockMinutes: minutes, reblockReason: reason, activeSessionId: session,
                                        sinceAt: since))
    }

    /// シールドに出す差の材料（ホームの円と同じ相手。いなければいる方）
    private func shieldRaceSnapshot() -> ShieldRaceSnapshot {
        let home = snapshot
        let available = Opponent.allCases.filter { home.opponentFocusSeconds($0) != nil }
        let current = available.contains(opponent) ? opponent : available.first
        let curve: [Int] = (0...96).compactMap { index in
            let time = home.dayStart.addingTimeInterval(Double(index) * ShieldRaceSnapshot.step)
            switch current {
            case .lastWeek: return home.ghost?.focusSeconds(at: time)
            case .goal: return home.goal?.focusSeconds(at: time)
            case nil: return nil
            }
        }
        let isFocusRunning = running.map { !$0.session.isPaused && $0.countsAsFocus } ?? false
        return ShieldRaceSnapshot(writtenAt: home.now, dayKey: DayBoundary.dayKey(containing: home.now, calendar: calendar),
                                  dayStart: home.dayStart, focusSecAtWrite: home.focusSeconds, isFocusRunning: isFocusRunning,
                                  opponentPrefix: current?.diffPrefix ?? "", opponentCurve: curve)
    }
}
