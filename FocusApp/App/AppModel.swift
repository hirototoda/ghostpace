import Foundation
import Observation

/// 朝の計画を出すときの値。開いた時点の日を持ち続ける（編集中に4:00を過ぎても、その日の計画として保存する）。
struct MorningPlan: Identifiable, Hashable {
    var dayKey: String
    var dayStart: Date
    var draft: PlanDraft
    var id: String { dayKey }
}

/// 止め忘れの疑いがあるときに「いつやめましたか？」を聞くための値。
struct EndTimeCheck: Identifiable, Hashable {
    var id: UUID
    var startAt: Date
    var askedAt: Date
    /// 初期値：予定の終了時刻（なければ今）
    var initialEnd: Date
    /// 開始と今で日付が変わっていれば、日付も選ぶ
    var showsDate: Bool

    /// 選べる範囲：開始の1分後〜聞いた時刻
    var range: ClosedRange<Date> { min(startAt.addingTimeInterval(60), askedAt)...askedAt }
}

/// 画面が使う状態と操作。記録の読み書きは Repository（RecordStore）を経由する。
@MainActor
@Observable
final class AppModel {
    static let discardedNotice = "1分未満なので記録しませんでした"
    static let saveErrorMessage = "保存できませんでした"
    static let cannotEditMessage = "この記録は直せません（直せるのは今日と昨日の記録だけです）"
    static let emptyNameMessage = "名前を入れてください"
    static let duplicateNameMessage = "同じ名前がすでにあります"
    static let lastCategoryMessage = "最後のカテゴリはアーカイブできません"
    static let tooManyTemplatesMessage = "テンプレートは7つまでです。使わないものを消してから保存してください"
    static let emptySelectionMessage = "何も選ばれていません"
    static let notStartedMessage = "ブロックをまだ始めていないので開けません。設定の「アプリのブロック」から始めてください"
    static let unreadableSelectionMessage = "ブロックするアプリを読めませんでした。設定でもう一度選んでください"

    private(set) var snapshot: HomeSnapshot
    private(set) var running: RunningTimer?
    /// 今日の計画。nil なら計画なし日
    private(set) var plan: PlanDraft?
    /// 今日の計画を確定したか（確定後はヘルスケアの睡眠を置き換えない、DTX-02）
    private(set) var isPlanConfirmed = false
    /// 確定したときの睡眠の読み直し（テストで待つ）
    private(set) var confirmSleepTask: Task<Void, Never>?
    /// 今日の確定した計画のゲーム・SNS の時間（BLK-10）。下書き・計画なし日は空
    private(set) var confirmedUnblocks: [PlanBlockDraft] = []
    /// この起動でゲーム・SNS の時間のスケジュールを iPhone に登録したか（登録に失敗した・消えたときに備え、起動のたびに登録し直す）
    var registeredUnblockSchedules = false
    var morningPlan: MorningPlan?
    private(set) var categories: [CategoryOption] = []
    private(set) var projects: [ProjectOption] = []
    /// 計画のテンプレート（PLN-07）
    private(set) var templates: [PlanTemplate] = []
    var endTimeCheck: EndTimeCheck?
    /// 短い知らせ（ホームの上に2秒出す）
    var notice: String?
    var errorMessage: String?
    /// ホームの円で比べる相手（GHO-10）。端末の設定に覚えておく
    private(set) var opponent: Opponent
    /// 振り返りの通知の時刻（0:00 からの分、REV-02）
    private(set) var reviewMinutes: Int
    private(set) var plannedEndNotifications: Bool
    /// 計画ブロックの前の通知（TMR-12）。何分前か（0 はちょうど、nil はオフ）
    private(set) var blockNoticeMinutes: Int?
    /// 計画ブロックの前の通知の材料：確定した今日の計画のブロックと、もう始めたブロック
    private var noticeBlocks: [PlanBlockSummary] = []
    private var startedBlockIds: Set<UUID> = []
    /// 通知の許可（設定の画面で「オンにする」を出すため）
    private(set) var notificationStatus: NotificationAuthorization = .notDetermined
    /// 初めて朝の計画を確定した直後の、通知の説明（TMR-05）
    var showsNotificationIntro = false
    /// 振り返りの通知を押して開いたとき
    var showsReview = false
    /// アプリのブロック（BLK-01・BLK-05〜09）。拡張と共有する状態の写し
    /// 書くのは AppModel+Blocking だけ
    var blockState = BlockState()
    var blockingAuthorization: BlockingAuthorization = .notDetermined
    /// 許可が「未確認」と最初に読めた時刻（BLK-11）。起動直後などに一瞬そう返ることがあるので、1分続くまでは「外れた」と書かない
    var authorizationDoubtSince: Date?
    /// 長押しの画面を出しているとき
    var holdRequest: HoldRequest?
    /// この機能が入った版を最初に開いたときの説明（BLK-01）
    var showsBlockingIntro = false

    private let store: any RecordStore
    let clock: any AppClock
    private let timeZone: () -> TimeZone
    private let settings: any AppSettings
    private let notifications: any NotificationScheduling
    /// ロック画面と画面上部のタイマー（TMR-06）
    private let liveActivity: any LiveActivityControlling
    let blocking: any BlockingControlling
    let blockStore: any BlockStoring
    let blockLog: any BlockEventLogging
    let sleepSource: any SleepSource
    /// その日の朝に終わった睡眠（DTX-02）。読み直すたびに保存したものを読む
    var sleep: (dayKey: String, line: SleepLine)?
    /// 設定の睡眠の時刻（0:00 からの分）
    var sleepSettings: (start: Int, end: Int)
    /// ヘルスケアの許可をまだ聞いていない（朝の計画の睡眠の行と設定に「ヘルスケアから読む」を出す）
    var healthNeedsRequest = false

    init(store: any RecordStore, clock: any AppClock, timeZone: @escaping () -> TimeZone = { .current },
         settings: any AppSettings = MemorySettings(), notifications: any NotificationScheduling = NoNotifications(),
         blocking: any BlockingControlling = NoBlocking(), blockStore: any BlockStoring = MemoryBlockStore(),
         blockLog: any BlockEventLogging = MemoryBlockEventLog(),
         liveActivity: any LiveActivityControlling = NoLiveActivity(), sleepSource: any SleepSource = NoSleepSource()) {
        self.store = store
        self.sleepSource = sleepSource
        self.clock = clock
        self.timeZone = timeZone
        self.settings = settings
        self.notifications = notifications
        self.liveActivity = liveActivity
        self.blocking = blocking
        self.blockStore = blockStore
        self.blockLog = blockLog
        blockingAuthorization = blocking.authorization()
        opponent = settings.opponent
        reviewMinutes = settings.reviewMinutes
        sleepSettings = (settings.sleepStartMinutes, settings.sleepEndMinutes)
        plannedEndNotifications = settings.plannedEndNotifications
        blockNoticeMinutes = settings.blockNoticeMinutes
        let now = clock.now()
        snapshot = HomeSnapshot.make(now: now, calendar: .app(timeZone: timeZone()), todaySessions: [], plan: PlanDraft(),
                                     lastWeekSessions: [])
        perform { try store.seedDefaultsIfNeeded() }
        // 掃除・料理・瞑想を家事・休みのブロック名に1回だけ組み替える（CAT-01、settings.md「カテゴリの組み替え」）。
        // 失敗したら覚えず、次の起動でやり直す
        if !settings.didRegroupDetoxCategories, perform({ _ = try store.regroupDetoxCategories() }) {
            settings.didRegroupDetoxCategories = true
        }
        // 「理想の休日」を1回だけ入れる（PLN-07。消したあとに入れ直さない）
        if !settings.didSeedTemplates, perform({ _ = try store.seedTemplatesIfNeeded() }) {
            settings.didSeedTemplates = true
        }
        reload()
        // 終了していた状態から開いたときも、シールドの「開く」から2分以内なら長押しの画面を出す（BLK-08）
        checkUnlockRequest()
    }

    var calendar: Calendar { .app(timeZone: timeZone()) }

    /// 睡眠の記録（AppModel+Sleep から使う）
    var sleepStore: any SleepRepository { store }

    /// 設定の睡眠の時刻を端末の設定に書く（AppModel+Sleep から使う）
    func storeSleepSettings() {
        settings.sleepStartMinutes = sleepSettings.start
        settings.sleepEndMinutes = sleepSettings.end
    }

    /// アプリのブロックの説明を出したか（AppModel+Blocking から使う）
    var blockSettingsDidShowIntro: Bool {
        get { settings.didShowBlockingIntro }
        set { settings.didShowBlockingIntro = newValue }
    }

    /// ブロックの「始めた」を記録したか（BLK-11、AppModel+Blocking から使う）
    var blockSettingsDidLogStart: Bool {
        get { settings.didLogBlockStart }
        set { settings.didLogBlockStart = newValue }
    }

    /// 最後に見た Screen Time の許可（BLK-11、AppModel+Blocking から使う）
    var blockSettingsLastAuthorized: Bool? {
        get { settings.lastBlockingAuthorized }
        set { settings.lastBlockingAuthorized = newValue }
    }

    /// 最後に許可があると確かめた時刻（BLK-11、AppModel+Blocking から使う）
    var blockSettingsLastAuthorizedAt: Date? {
        get { settings.lastBlockingAuthorizedAt }
        set { settings.lastBlockingAuthorizedAt = newValue }
    }

    /// 記録を読み直す。起動、前面に戻ったとき、各操作の後、ホーム表示中は1分ごとに呼ぶ。
    /// 1分ごと・前面に戻ったときは `quietly` にする（読み出しの失敗で毎分アラートを出さない）。
    func reload(quietly: Bool = false) {
        perform(reportsError: !quietly) {
            let now = clock.now()
            let calendar = self.calendar
            let dayStart = DayBoundary.dayStart(containing: now, calendar: calendar)
            let dayKey = DayBoundary.dayKey(containing: now, calendar: calendar)
            categories = try store.categories()
            projects = try store.projects()
            templates = try store.templates()

            let stored = try store.plan(dayKey: dayKey)
            plan = stored?.status == .skipped ? nil : (stored?.draft ?? PlanDraft())
            let isConfirmed = stored?.status == .confirmed || stored?.status == .unknown
            isPlanConfirmed = isConfirmed
            confirmedUnblocks = isConfirmed ? (stored?.draft.blocks.filter(\.isUnblock) ?? []) : []
            let todaySessions = try store.sessions(dayKey: dayKey)
            noticeBlocks = isConfirmed ? (plan?.summaries ?? []) : []
            startedBlockIds = Set(todaySessions.compactMap(\.planBlockId))

            let detox = try detoxDays(now: now, dayStart: dayStart, calendar: calendar)
            snapshot = HomeSnapshot.make(now: now, calendar: calendar,
                                         todaySessions: todaySessions + (try carriedOver(into: dayStart, calendar: calendar)),
                                         plan: plan, lastWeekSessions: try lastWeekSessions(of: dayStart, calendar: calendar),
                                         reviewMinutes: reviewMinutes, noPlanGoalSeconds: stored?.draft.goalSeconds,
                                         detox: detox.today, lastWeekDetox: detox.lastWeek, sleep: detox.sleep, sleepCaps: detox.sleepCaps)

            if let session = try store.runningSession() {
                running = try runningTimer(session, calendar: calendar)
            } else {
                running = nil
                endTimeCheck = nil
            }
            // ロック画面と画面上部のタイマー（TMR-06）。開き直したときも、実行中なら出し直す
            liveActivity.show(running.map { TimerActivity.make($0.session, now: now, timeZone: calendar.timeZone) })
            refreshNotifications()
            refreshBlocking(now: now)
            // 睡眠は付随の機能なので、読み書きに失敗しても朝の計画などは続ける
            do { try ensureSleep(dayStart: dayStart, calendar: calendar) } catch { sleep = nil }

            // 実行中のタイマーがあればタイマーを優先し、終了後に出す。開いている朝の計画は置き換えない
            let needsPlan = stored == nil || stored?.status == .draft
            if running == nil, needsPlan, morningPlan == nil {
                let draft = try stored?.draft ?? carriedDraft(dayStart: dayStart, calendar: calendar)
                morningPlan = MorningPlan(dayKey: dayKey, dayStart: dayStart, draft: draft)
            }
        }
    }

    private func runningTimer(_ session: FocusSession, calendar: Calendar) throws -> RunningTimer {
        let sameDay = try store.sessions(dayKey: session.dayKey).filter { $0.id != session.id }
        let dayStart = DayBoundary.dayStart(containing: session.startAt, calendar: calendar)
        let stored = try store.plan(dayKey: session.dayKey)
        let plan = stored?.status == .skipped ? nil : stored?.draft
        return RunningTimer(
            session: session,
            focusSecondsBefore: sameDay.flatMap { $0.activeSegments(now: session.startAt) }.focusSeconds(until: session.startAt),
            ghost: GhostSummary(lastWeek: try lastWeekSessions(of: dayStart, calendar: calendar),
                                lastWeekStart: DayBoundary.sameDayLastWeek(dayStart, calendar: calendar), todayStart: dayStart),
            goal: GoalGhost(plan: plan, goalSeconds: stored?.draft.goalSeconds,
                            sleep: try sleepLines(dayStart: dayStart, calendar: calendar).map(\.interval),
                            dayStart: dayStart, calendar: calendar).nonEmpty,
            // 切り替え・計画の時刻の通知は確定した計画だけ（下書きのブロックでは知らせない）
            planBlocks: stored?.status == .confirmed || stored?.status == .unknown ? (plan?.summaries ?? []) : [])
    }

    // MARK: 対戦相手（GHO-10）

    func selectOpponent(_ opponent: Opponent) {
        self.opponent = opponent
        settings.opponent = opponent
    }

    // MARK: 夜の振り返り（REV-01）

    /// 今日（朝4:00区切り）の振り返り。読めなければ nil
    func reviewContent() -> ReviewContent? {
        // 日付・合計・相手の値を同じ時刻から作る（ホームの表示は最大1分古いことがある）
        let now = clock.now()
        let calendar = self.calendar
        let dayStart = DayBoundary.dayStart(containing: now, calendar: calendar)
        let dayKey = DayBoundary.dayKey(containing: now, calendar: calendar)
        var content: ReviewContent?
        perform(reportsError: false) {
            let stored = try store.plan(dayKey: dayKey)
            let sessions = try store.sessions(dayKey: dayKey)
            let detox = try detoxDays(now: now, dayStart: dayStart, calendar: calendar)
            let home = HomeSnapshot.make(now: now, calendar: calendar,
                                         todaySessions: sessions + (try carriedOver(into: dayStart, calendar: calendar)),
                                         plan: stored?.status == .skipped ? nil : (stored?.draft ?? PlanDraft()),
                                         lastWeekSessions: try lastWeekSessions(of: dayStart, calendar: calendar),
                                         reviewMinutes: reviewMinutes, noPlanGoalSeconds: stored?.draft.goalSeconds,
                                         detox: detox.today, lastWeekDetox: detox.lastWeek, sleep: detox.sleep, sleepCaps: detox.sleepCaps)
            // 確定した日だけ朝の計画と比べる。下書きのまま・計画なし日は計画なしとして扱う
            let confirmed = stored?.status == .confirmed || stored?.status == .unknown
            content = ReviewContent.make(home: home, sessions: sessions,
                                         snapshot: confirmed ? (try store.snapshot(dayKey: dayKey) ?? []) : nil)
        }
        return content
    }

    /// 「明日の計画を立てる」で開く計画。明日（朝4:00区切りで今日の次の日）の下書きがあれば続きから
    func tomorrowPlan() -> MorningPlan {
        let today = DayBoundary.dayStart(containing: clock.now(), calendar: calendar)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86400)
        let dayKey = DayBoundary.dayKey(containing: tomorrow, calendar: calendar)
        var draft = PlanDraft()
        perform(reportsError: false) {
            if let stored = try store.plan(dayKey: dayKey) {
                if stored.status == .draft { draft = stored.draft }
            } else {
                draft = try carriedDraft(dayStart: tomorrow, calendar: calendar)
            }
        }
        return MorningPlan(dayKey: dayKey, dayStart: tomorrow, draft: draft)
    }

    /// 新しく作る下書き。前の日のゲーム・SNS の時間（日中に直したあとの形）を引き継ぐ（BLK-10、2026-10-02 オーナー決定）。
    /// 前の日に確定した計画がなければ、7日前までさかのぼって最後に確定した日から。その日に1つもなければ、なし
    private func carriedDraft(dayStart: Date, calendar: Calendar) throws -> PlanDraft {
        for offset in 1...7 {
            guard let previousStart = calendar.date(byAdding: .day, value: -offset, to: dayStart) else { break }
            let stored = try store.plan(dayKey: DayBoundary.dayKey(containing: previousStart, calendar: calendar))
            guard let stored, stored.status == .confirmed || stored.status == .unknown else { continue }
            return PlanDraft(blocks: PlanDraft.carriedUnblocks(stored.draft.blocks, previousDayStart: previousStart,
                                                               dayStart: dayStart, calendar: calendar))
        }
        return PlanDraft()
    }

    /// 明日の計画の下書きを保存する。翌朝の朝の計画に出る
    @discardableResult
    func saveTomorrowDraft(_ draft: PlanDraft, for plan: MorningPlan) -> Bool {
        perform { try store.saveDraft(draft, dayKey: plan.dayKey, timeZone: timeZone()) }
    }

    // MARK: 通知（TMR-05、REV-02）

    /// 予約をいまの状態にそろえる（予定の時間・計画ブロックの前・振り返り）。許可がなければ何もしない
    func refreshNotifications() {
        let plan = NotificationPlan.make(running: running?.session, now: clock.now(),
                                         plannedEndEnabled: plannedEndNotifications, reviewMinutes: reviewMinutes,
                                         calendar: calendar, planBlocks: running?.planBlocks ?? [],
                                         blockNotice: BlockNotice(leadMinutes: blockNoticeMinutes, blocks: noticeBlocks,
                                                                  startedBlockIds: startedBlockIds))
        notifications.replaceAll(with: notificationStatus == .authorized ? plan : [])
    }

    /// iPhone の許可の状態を読み直す（起動時・前面に戻ったとき・設定を開いたとき）
    func refreshNotificationStatus() async {
        notificationStatus = await notifications.authorization()
        refreshNotifications()
    }

    /// 「通知をオンにする」：iPhone の許可を聞く
    func enableNotifications() async {
        settings.didShowNotificationIntro = true
        showsNotificationIntro = false
        _ = await notifications.requestAuthorization()
        await refreshNotificationStatus()
    }

    /// 通知の説明の「あとで」
    func postponeNotifications() {
        settings.didShowNotificationIntro = true
        showsNotificationIntro = false
    }

    func setPlannedEndNotifications(_ enabled: Bool) {
        plannedEndNotifications = enabled
        settings.plannedEndNotifications = enabled
        refreshNotifications()
    }

    /// 計画ブロックの前の通知を何分前にするか（TMR-12）。nil はオフ
    func setBlockNoticeMinutes(_ minutes: Int?) {
        blockNoticeMinutes = minutes
        settings.blockNoticeMinutes = minutes
        refreshNotifications()
    }

    func setReviewMinutes(_ minutes: Int) {
        reviewMinutes = ((minutes % 1440) + 1440) % 1440
        settings.reviewMinutes = reviewMinutes
        reload(quietly: true)
    }

    // MARK: 目標・テンプレート（GHO-10、PLN-07）

    /// 計画なし日の目標（GHO-10、Q13）。nil で目標なし
    @discardableResult
    func setNoPlanGoal(_ seconds: Int?) -> Bool {
        let dayKey = DayBoundary.dayKey(containing: clock.now(), calendar: calendar)
        let saved = perform { try store.setGoal(seconds.flatMap { $0 > 0 ? $0 : nil }, dayKey: dayKey) }
        reload()
        return saved
    }

    /// 計画なし日の目標（読み出し）
    var noPlanGoalSeconds: Int? {
        snapshot.isNoPlanDay ? snapshot.goal?.goalSeconds : nil
    }

    /// 今の計画をテンプレートとして保存する（「この計画をテンプレートとして保存」）
    @discardableResult
    func saveAsTemplate(name: String, plan: PlanDraft) -> Bool {
        saveTemplate(PlanTemplate(name: name, plan: plan, calendar: calendar))
    }

    @discardableResult
    func saveTemplate(_ template: PlanTemplate) -> Bool {
        editTemplates { try store.saveTemplate(template) }
    }

    @discardableResult
    func deleteTemplate(_ template: PlanTemplate) -> Bool {
        editTemplates { try store.deleteTemplate(id: template.id) }
    }

    private func editTemplates(_ work: () throws -> Void) -> Bool {
        do {
            try work()
            reload()
            return true
        } catch RecordError.tooManyTemplates {
            errorMessage = Self.tooManyTemplatesMessage
        } catch RecordError.emptyName {
            errorMessage = Self.emptyNameMessage
        } catch {
            errorMessage = Self.saveErrorMessage
        }
        return false
    }

    // MARK: 設定のカテゴリ（CAT-02〜04）

    func archivedCategories() -> [CategoryOption] {
        var result: [CategoryOption] = []
        perform(reportsError: false) { result = try store.archivedCategories() }
        return result
    }

    func archivedProjects() -> [ProjectOption] {
        var result: [ProjectOption] = []
        perform(reportsError: false) { result = try store.archivedProjects() }
        return result
    }

    func createCategory(name: String, countsAsFocus: Bool, detoxGroup: DetoxGroup? = nil) -> CategoryOption? {
        var category: CategoryOption?
        editCategories { category = try store.createCategory(name: name, countsAsFocus: countsAsFocus, detoxGroup: detoxGroup) }
        if category == nil, errorMessage == nil { errorMessage = Self.emptyNameMessage }
        return category
    }

    @discardableResult
    func updateCategory(_ category: CategoryOption, name: String, countsAsFocus: Bool) -> Bool {
        editCategories { try store.updateCategory(id: category.id, name: name, countsAsFocus: countsAsFocus,
                                                  detoxGroup: countsAsFocus ? nil : category.detoxGroup) }
    }

    /// デトックスのグループを変える（CAT-04、DTX-03）。過去の点も新しいグループで数え直す
    @discardableResult
    func setCategoryGroup(_ category: CategoryOption, _ group: DetoxGroup?) -> Bool {
        editCategories { try store.updateCategory(id: category.id, name: category.name, countsAsFocus: category.countsAsFocus,
                                                  detoxGroup: group) }
    }

    @discardableResult
    func setCategoryArchived(_ category: CategoryOption, _ archived: Bool) -> Bool {
        editCategories { try store.setCategoryArchived(id: category.id, archived) }
    }

    @discardableResult
    func renameProject(_ project: ProjectOption, to name: String) -> Bool {
        editCategories { try store.renameProject(id: project.id, name: name) }
    }

    @discardableResult
    func setProjectArchived(_ project: ProjectOption, _ archived: Bool) -> Bool {
        editCategories { try store.setProjectArchived(id: project.id, archived) }
    }

    /// カテゴリ・ブロック名を変えて読み直す。失敗の理由を出す
    @discardableResult
    private func editCategories(_ work: () throws -> Void) -> Bool {
        do {
            try work()
            reload()
            return true
        } catch RecordError.emptyName {
            errorMessage = Self.emptyNameMessage
        } catch RecordError.duplicateName {
            errorMessage = Self.duplicateNameMessage
        } catch RecordError.lastCategory {
            errorMessage = Self.lastCategoryMessage
        } catch {
            errorMessage = Self.saveErrorMessage
        }
        return false
    }

    // MARK: デジタルデトックス（DTX-01・03）

    /// 今日（今まで）と、先週の同じ曜日（1日分）のデトックスと、今日の睡眠と手で長くした所（目標のゴーストに使う）
    private func detoxDays(now: Date, dayStart: Date, calendar: Calendar) throws
        -> (today: DetoxDay, lastWeek: DetoxDay, sleep: [DateInterval], sleepCaps: [DateInterval]) {
        // 記録のファイルが読めなくても、ほかの表示は続ける（デトックスが0になるだけ）
        let events = (try? blockLog.all()) ?? []
        let lastWeekStart = DayBoundary.sameDayLastWeek(dayStart, calendar: calendar)
        let sleep = try sleepLines(dayStart: dayStart, calendar: calendar)
        return (try detoxDay(dayStart: dayStart, until: now, events: events, calendar: calendar),
                try detoxDay(dayStart: lastWeekStart, until: .distantFuture, events: events, calendar: calendar),
                sleep.map(\.interval), sleep.compactMap(\.extendedPart))
    }

    /// 1日分の材料を集めて数える（digital-detox.md「数え方」）
    private func detoxDay(dayStart: Date, until: Date, events: [BlockEvent], calendar: Calendar) throws -> DetoxDay {
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86400)
        let previousStart = calendar.date(byAdding: .day, value: -1, to: dayStart) ?? dayStart.addingTimeInterval(-86400)
        let key = DayBoundary.dayKey(containing: dayStart, calendar: calendar)
        // 前の日に始めて4:00をまたいだタイマーも入れる
        let sessions = try store.sessions(dayKey: key)
            + store.sessions(dayKey: DayBoundary.dayKey(containing: previousStart, calendar: calendar))
        let segments = sessions.flatMap { $0.activeSegments(now: min(until, clock.now())) }
        let plan = try store.plan(dayKey: key)
        let confirmed = plan?.status == .confirmed || plan?.status == .unknown
        let sleep = try sleepLines(dayStart: dayStart, calendar: calendar)
        return DetoxDay.make(DetoxDay.Inputs(
            dayStart: dayStart, dayEnd: dayEnd, until: until, events: events,
            focus: segments.filter(\.countsAsFocus).map { DateInterval(start: $0.start, end: max($0.start, $0.end)) },
            detoxTimers: segments.filter { !$0.countsAsFocus }.map {
                DetoxTimer(interval: DateInterval(start: $0.start, end: max($0.start, $0.end)), group: $0.detoxGroup)
            },
            // その日の朝に終わった睡眠と、その夜の睡眠（翌朝決まるまでは設定の時刻で仮に数える）
            sleep: sleep.map(\.interval),
            gameWindows: confirmed ? (plan?.draft.blocks.filter(\.isUnblock).map { DateInterval(start: $0.start, end: $0.end) } ?? []) : [],
            // 手で直す前より長くした所は、0.5pt と睡眠の点の低いほう（DTX-03）
            sleepCaps: sleep.compactMap(\.extendedPart)))
    }

    /// その日の朝に終わった睡眠と、その夜の睡眠（翌朝決まるまでは設定の時刻で仮に数える）
    private func sleepLines(dayStart: Date, calendar: Calendar) throws -> [SleepLine] {
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86400)
        return try [dayStart, dayEnd].map { try sleepLine(dayStart: $0, calendar: calendar) }
    }

    /// その日の朝に終わった睡眠。保存していなければ設定の時刻
    private func sleepLine(dayStart: Date, calendar: Calendar) throws -> SleepLine {
        try store.sleep(dayKey: DayBoundary.dayKey(containing: dayStart, calendar: calendar))
            ?? .fromSetting(startMinutes: sleepSettings.start, endMinutes: sleepSettings.end, dayStart: dayStart, calendar: calendar)
    }

    /// 先週の同じ曜日のセッション（GHO-02）。前の日に始めて4:00をまたいだものも入れる
    private func lastWeekSessions(of dayStart: Date, calendar: Calendar) throws -> [FocusSession] {
        let lastWeekStart = DayBoundary.sameDayLastWeek(dayStart, calendar: calendar)
        return try store.sessions(dayKey: DayBoundary.dayKey(containing: lastWeekStart, calendar: calendar))
            + (try carriedOver(into: lastWeekStart, calendar: calendar))
    }

    /// 前の日に始めて `dayStart`（4:00）をまたいだセッション。4:00より後の分はその日の集中に入れる（GHO-14、2026-10-03）
    private func carriedOver(into dayStart: Date, calendar: Calendar) throws -> [FocusSession] {
        let previousStart = calendar.date(byAdding: .day, value: -1, to: dayStart) ?? dayStart.addingTimeInterval(-86400)
        let now = clock.now()
        return try store.sessions(dayKey: DayBoundary.dayKey(containing: previousStart, calendar: calendar))
            .filter { ($0.endAt ?? now) > dayStart }
    }

    // MARK: 分析（ANA-04・05）：過去の日のポイント。ホームと同じ計算をその日の記録でやり直す

    /// `daysAgo` 日前（今日は0）の1日分の数字。今日は今まで、過ぎた日は翌4:00まで。未来・読めないときは nil
    func daySnapshot(daysAgo: Int) -> HomeSnapshot? {
        let now = clock.now()
        let calendar = self.calendar
        let today = DayBoundary.dayStart(containing: now, calendar: calendar)
        guard daysAgo >= 0, let dayStart = calendar.date(byAdding: .day, value: -daysAgo, to: today) else { return nil }
        var snapshot: HomeSnapshot?
        perform(reportsError: false) {
            snapshot = try daySnapshot(dayStart: dayStart, now: now, events: (try? blockLog.all()) ?? [], calendar: calendar)
        }
        return snapshot
    }

    /// 直近 `days` 日（今日を含む、古い日が先）のポイントと、先週の同じ曜日のポイント
    func pointsHistory(days: Int) -> [DayPoints] {
        let now = clock.now()
        let calendar = self.calendar
        let today = DayBoundary.dayStart(containing: now, calendar: calendar)
        // ブロックの記録は1回だけ読む
        let events = (try? blockLog.all()) ?? []
        var result: [DayPoints] = []
        perform(reportsError: false) {
            for daysAgo in (0..<max(days, 0)).reversed() {
                guard let dayStart = calendar.date(byAdding: .day, value: -daysAgo, to: today) else { continue }
                let isToday = daysAgo == 0
                let recorded = try isToday || hasRecord(dayStart: dayStart, calendar: calendar)
                guard recorded else {
                    result.append(DayPoints(dayStart: dayStart, points: nil, lastWeek: nil, isToday: false))
                    continue
                }
                let snapshot = try daySnapshot(dayStart: dayStart, now: now, events: events, calendar: calendar)
                result.append(DayPoints(dayStart: dayStart, points: snapshot.points,
                                        lastWeek: snapshot.opponentPoints(.lastWeek, at: snapshot.now), isToday: isToday))
            }
        }
        return result
    }

    /// その日に何か記録があるか：タイマーの記録・計画（下書き・確定・計画なし）・保存した睡眠のどれか。
    /// ない日は使い始める前などで、設定の睡眠の時刻だけで点が付いてしまうので数えない
    private func hasRecord(dayStart: Date, calendar: Calendar) throws -> Bool {
        let key = DayBoundary.dayKey(containing: dayStart, calendar: calendar)
        return try !store.sessions(dayKey: key).isEmpty || store.plan(dayKey: key) != nil || store.sleep(dayKey: key) != nil
    }

    /// その日の4:00から（今日は今まで、過ぎた日は翌4:00まで）の、ホームと同じ数字
    private func daySnapshot(dayStart: Date, now: Date, events: [BlockEvent], calendar: Calendar) throws -> HomeSnapshot {
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86400)
        let until = min(now, dayEnd)
        let key = DayBoundary.dayKey(containing: dayStart, calendar: calendar)
        let stored = try store.plan(dayKey: key)
        let sleep = try sleepLines(dayStart: dayStart, calendar: calendar)
        return HomeSnapshot.make(
            now: until, calendar: calendar,
            todaySessions: try store.sessions(dayKey: key) + carriedOver(into: dayStart, calendar: calendar),
            plan: stored?.status == .skipped ? nil : (stored?.draft ?? PlanDraft()),
            lastWeekSessions: try lastWeekSessions(of: dayStart, calendar: calendar),
            reviewMinutes: reviewMinutes, noPlanGoalSeconds: stored?.draft.goalSeconds,
            detox: try detoxDay(dayStart: dayStart, until: until, events: events, calendar: calendar),
            lastWeekDetox: try detoxDay(dayStart: DayBoundary.sameDayLastWeek(dayStart, calendar: calendar),
                                        until: .distantFuture, events: events, calendar: calendar),
            sleep: sleep.map(\.interval), sleepCaps: sleep.compactMap(\.extendedPart), dayStart: dayStart)
    }

    // MARK: タイムライン

    /// タイムラインの1日分。`daysAgo` は今日を0として何日前か（未来は見られない、TML-02）。
    func timelineDay(daysAgo: Int) -> TimelineDay? {
        let now = clock.now()
        let calendar = self.calendar
        let today = DayBoundary.dayStart(containing: now, calendar: calendar)
        guard daysAgo >= 0, let dayStart = calendar.date(byAdding: .day, value: -daysAgo, to: today) else { return nil }
        let dayKey = DayBoundary.dayKey(containing: dayStart, calendar: calendar)
        var day: TimelineDay?
        perform(reportsError: false) {
            let stored = try store.plan(dayKey: dayKey)
            // 開けた時間（TML-05）：今日は今まで、過ぎた日は1日分。数えられなくても、ほかの表示は続ける（開けた時間を出さないだけ）
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86400)
            let until = min(now, dayEnd)
            let detox = try? detoxDay(dayStart: dayStart, until: until, events: (try? blockLog.all()) ?? [], calendar: calendar)
            day = TimelineDay(
                dayKey: dayKey, dayStart: dayStart, now: now, isToday: daysAgo == 0,
                planBlocks: stored?.status == .skipped ? [] : (stored?.draft.summaries ?? []),
                isNoPlanDay: stored == nil || stored?.status == .skipped,
                sessions: try store.sessions(dayKey: dayKey),
                editableDayKeys: editableDayKeys(now: now, calendar: calendar),
                opened: detox?.opened(until: until))
        }
        return day
    }

    /// 終了時刻を直せる日（今日と昨日、朝4:00区切り）
    private func editableDayKeys(now: Date, calendar: Calendar) -> Set<String> {
        let today = DayBoundary.dayStart(containing: now, calendar: calendar)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        return [DayBoundary.dayKey(containing: today, calendar: calendar), DayBoundary.dayKey(containing: yesterday, calendar: calendar)]
    }

    /// 開始と終了で日付（暦の日）が変わるか。時刻の選択で日付も出すかを決める
    func crossesDate(from start: Date, to end: Date) -> Bool {
        !calendar.isDate(start, inSameDayAs: end)
    }

    /// 終わった記録の終了時刻を早める（TML-04）。保存する瞬間にも「今日・昨日の記録か」を確かめる。成功なら true
    @discardableResult
    func shortenEnd(_ session: FocusSession, to newEnd: Date) -> Bool {
        guard TimelineDay.canEdit(session, editableDayKeys: editableDayKeys(now: clock.now(), calendar: calendar)) else {
            errorMessage = Self.cannotEditMessage
            return false
        }
        let saved = perform { try store.shortenEnd(id: session.id, to: newEnd) }
        reload()
        return saved
    }

    // MARK: タイマー

    func startPlanned(block: PlanBlockSummary) {
        // ゲーム・SNS の時間（BLK-10）からはタイマーを始めない
        guard !block.category.isUnblock else { return }
        start(StartRequest(category: block.category, project: block.project, planBlockId: block.id,
                           plannedEndAt: block.end, plannedDurationSec: nil, timeZone: timeZone()))
    }

    func startUnplanned(category: CategoryOption, project: ProjectOption? = nil, minutes: Int?) {
        start(StartRequest(category: category, project: project, planBlockId: nil, plannedEndAt: nil,
                           plannedDurationSec: minutes.map { $0 * 60 }, timeZone: timeZone()))
    }

    /// 計画外のタイマー中に始まった計画ブロックに切り替える（TMR-11）。計画外の記録を今で終え、そのブロックを始める。
    /// 本人が画面で押す操作なので、止め忘れの確認は出さない
    func switchToBlock(_ block: PlanBlockSummary) {
        guard let timer = running, timer.switchableBlock(at: clock.now()) == block else { return }
        var result: EndResult?
        guard perform({ result = try store.end(id: timer.id, reportedEnd: nil) }) else { return }
        if result == .discardedTooShort { notice = Self.discardedNotice }
        startPlanned(block: block)
    }

    private func start(_ request: StartRequest) {
        perform { _ = try store.start(request) }
        reload()
    }

    func pause() {
        guard let id = running?.id else { return }
        perform { try store.pause(id: id) }
        reload()
    }

    func resume() {
        guard let id = running?.id else { return }
        perform { try store.resume(id: id) }
        reload()
    }

    /// 終了ボタン。止め忘れの疑いがあれば終了時刻を聞き、なければすぐ終える。
    func requestEnd() {
        guard let session = running?.session else { return }
        let now = clock.now()
        if session.needsEndTimeCheck(at: now, calendar: calendar) {
            let planned = session.plannedEnd(at: now).map { min(max($0, session.startAt.addingTimeInterval(1)), now) }
            endTimeCheck = EndTimeCheck(id: session.id, startAt: session.startAt, askedAt: now, initialEnd: planned ?? now,
                                        showsDate: crossesDate(from: session.startAt, to: now))
        } else {
            end(reportedEnd: nil)
        }
    }

    /// 終える。reportedEnd が nil なら今（保存する瞬間の時刻）。今より前なら、元の終了時刻（今）を残す（TMR-08）。
    func end(reportedEnd: Date?) {
        guard let id = running?.id else { return }
        var result: EndResult?
        perform { result = try store.end(id: id, reportedEnd: reportedEnd.map { min($0, clock.now()) }) }
        if result != nil { endTimeCheck = nil }
        if result == .discardedTooShort { notice = Self.discardedNotice }
        reload()
    }

    // MARK: 計画

    /// 朝の計画の下書きを保存する（計画が変わるたびに呼ぶ）。
    func saveDraft(_ draft: PlanDraft) {
        guard var morningPlan else { return }
        perform { try store.saveDraft(draft, dayKey: morningPlan.dayKey, timeZone: timeZone()) }
        morningPlan.draft = draft
        self.morningPlan = morningPlan
    }

    func confirmPlan(_ draft: PlanDraft) {
        guard let morningPlan else { return }
        let confirmed = perform { try store.confirm(draft, dayKey: morningPlan.dayKey, timeZone: timeZone()) }
        if confirmed {
            self.morningPlan = nil
            // 初めて確定した直後に、通知の説明を1回だけ出す（TMR-05）
            if !settings.didShowNotificationIntro { showsNotificationIntro = true }
        }
        reload()
        // 起きて計画を確定した時点で、ゆうべの睡眠をヘルスケアから読み直して決める（DTX-02、2026-10-03）
        if confirmed { confirmSleepTask = Task { await refreshSleep(confirming: true) } }
    }

    /// 今日は計画しない。朝の計画で目標を決めていれば、計画なし日の目標として残す（GHO-10、Q13）
    func skipPlan(goalSeconds: Int? = nil) {
        let dayKey = morningPlan?.dayKey ?? DayBoundary.dayKey(containing: clock.now(), calendar: calendar)
        if perform({ try store.skip(dayKey: dayKey, timeZone: timeZone(), goalSeconds: goalSeconds) }) {
            morningPlan = nil
        }
        reload()
    }

    /// 計画なし日にあとから計画を作る（2026-09-30 決定）。朝の計画画面を開き、閉じれば計画なしのまま。
    func openPlanOnNoPlanDay() {
        let now = clock.now()
        let calendar = self.calendar
        let dayStart = DayBoundary.dayStart(containing: now, calendar: calendar)
        // 計画なし日に決めた目標は、作る計画に引き継ぐ（GHO-10）。ゲーム・SNS の時間は前の日から（BLK-10）
        var draft = PlanDraft()
        perform(reportsError: false) { draft = try carriedDraft(dayStart: dayStart, calendar: calendar) }
        draft.goalSeconds = noPlanGoalSeconds
        morningPlan = MorningPlan(dayKey: DayBoundary.dayKey(containing: now, calendar: calendar),
                                  dayStart: dayStart, draft: draft)
    }

    /// 日中の計画の変更（PLN-04）。朝のスナップショットは変わらない。
    @discardableResult
    func savePlanChanges(_ draft: PlanDraft) -> Bool {
        let dayKey = DayBoundary.dayKey(containing: clock.now(), calendar: calendar)
        let saved = perform { try store.saveChanges(draft, dayKey: dayKey) }
        reload()
        return saved
    }

    func createProject(name: String, category: CategoryOption) -> ProjectOption? {
        var project: ProjectOption?
        perform {
            project = try store.createProject(name: name, category: category)
            projects = try store.projects()
        }
        return project
    }

    /// 失敗したら「保存できませんでした」を出す。成功なら true。
    @discardableResult
    private func perform(reportsError: Bool = true, _ work: () throws -> Void) -> Bool {
        do {
            try work()
            return true
        } catch {
            if reportsError { errorMessage = Self.saveErrorMessage }
            return false
        }
    }
}
