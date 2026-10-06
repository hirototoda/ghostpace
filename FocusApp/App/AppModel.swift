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
    /// 習慣（PLN-08）。アーカイブしたカテゴリ・ブロック名のブロックは入れない
    private(set) var habits = PlanHabits()
    /// 初めて使う端末で、朝の計画の前に出す習慣の画面（PLN-08）
    private(set) var showsHabitIntro = false
    /// ラップ・中間地点の帯を出した回数（ホームで軽く振動させる合図、GHO-06）
    private(set) var raceNoticeCount = 0
    /// 自己ベストと休み明けの判定の材料（記録の数が変わったときだけ数え直す）
    private var historyCache: (revision: Int, today: Date, byDay: [Date: Int])?
    private var timeMapCache: (revision: Int, today: Date, map: TimeMap)?
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
    /// ウィジェット（WID-01）に材料を渡す
    let widgets: any WidgetPublishing
    /// 環境音を鳴らす（TMR-14）
    let ambient: any AmbientPlaying
    /// 選んだ環境音と音量（前回の音を覚えて、次から自動で流す）
    private(set) var ambientSound: AmbientSound = .none
    private(set) var ambientVolume = SettingsDefaults.ambientVolume
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
         liveActivity: any LiveActivityControlling = NoLiveActivity(), sleepSource: any SleepSource = NoSleepSource(),
         offersHabitIntro: Bool = false, widgets: any WidgetPublishing = MemoryWidgetPublisher(),
         ambient: any AmbientPlaying = SilentAmbientPlayer()) {
        self.widgets = widgets
        self.ambient = ambient
        ambientSound = AmbientSound(stored: settings.ambientSound)
        ambientVolume = settings.ambientVolume
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
        // カテゴリが1つもない＝初めて使う端末（習慣の最初の案内を出すか決める、PLN-08）
        let isFreshInstall = (try? store.allCategories().isEmpty) ?? false
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
        setUpHabits(isFreshInstall: isFreshInstall, offersIntro: offersHabitIntro)
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
            habits = storedHabits()

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
                                         detox: detox.today, lastWeekDetox: detox.lastWeek, sleep: detox.sleep, sleepCaps: detox.sleepCaps,
                                         onPlan: try onPlanContext(dayStart: dayStart, today: stored, calendar: calendar))

            try addHistory(to: &snapshot, calendar: calendar)
            snapshot.awake = awakeRange(dayStart: dayStart)

            if let session = try store.runningSession() {
                running = try runningTimer(session, calendar: calendar)
            } else {
                running = nil
                endTimeCheck = nil
            }
            widgets.publish(widgetSnapshot(now: now, isConfirmed: isConfirmed))
            syncAmbient()
            // ロック画面と画面上部のタイマー（TMR-06）。開き直したときも、実行中なら出し直す
            liveActivity.show(running.map { TimerActivity.make($0.session, now: now, timeZone: calendar.timeZone) })
            refreshNotifications()
            refreshBlocking(now: now)
            // 睡眠は付随の機能なので、読み書きに失敗しても朝の計画などは続ける
            do { try ensureSleep(dayStart: dayStart, calendar: calendar) } catch { sleep = nil }

            // 実行中のタイマーがあればタイマーを優先し、終了後に出す。開いている朝の計画は置き換えない
            let needsPlan = stored == nil || stored?.status == .draft
            // 初めて使う端末は、習慣を決めてから朝の計画を出す（PLN-08）
            if running == nil, needsPlan, morningPlan == nil, !showsHabitIntro {
                let draft = stored?.draft ?? newDraft(dayStart: dayStart)
                morningPlan = MorningPlan(dayKey: dayKey, dayStart: dayStart, draft: draft)
            }
            // 計画どおりの点はタイマー中も知らせる。ラップの帯はタイマー中は出さない
            if morningPlan == nil, !announcePlanPoint(dayKey: dayKey), running == nil { announceRace(dayKey: dayKey) }
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
            var home = HomeSnapshot.make(now: now, calendar: calendar,
                                         todaySessions: sessions + (try carriedOver(into: dayStart, calendar: calendar)),
                                         plan: stored?.status == .skipped ? nil : (stored?.draft ?? PlanDraft()),
                                         lastWeekSessions: try lastWeekSessions(of: dayStart, calendar: calendar),
                                         reviewMinutes: reviewMinutes, noPlanGoalSeconds: stored?.draft.goalSeconds,
                                         detox: detox.today, lastWeekDetox: detox.lastWeek, sleep: detox.sleep, sleepCaps: detox.sleepCaps,
                                         onPlan: try onPlanContext(dayStart: dayStart, today: stored, calendar: calendar))
            try addHistory(to: &home, calendar: calendar)
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
                draft = newDraft(dayStart: tomorrow)
            }
        }
        return MorningPlan(dayKey: dayKey, dayStart: tomorrow, draft: draft)
    }

    /// 新しく作る下書き。習慣のブロックが最初から入る（PLN-08、2026-10-05 に前の日からの引き継ぎから変更）
    private func newDraft(dayStart: Date) -> PlanDraft {
        habits.draft(dayStart: dayStart, calendar: calendar)
    }

    /// それまでの「前の日から引き継ぐ」ゲーム・SNS の時間（BLK-10、2026-10-02）。すでに使っている端末の最初の習慣に使う。
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
                DetoxTimer(interval: DateInterval(start: $0.start, end: max($0.start, $0.end)), group: $0.detoxGroup,
                           isDeclared: $0.isDeclared)
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
        return daySnapshot(of: dayStart)
    }

    /// `dayStart`（その日の 4:00）の1日分の数字。分析で押した日を、開いたまま4:00をまたいでも取り違えないよう日付で開く
    func daySnapshot(of dayStart: Date) -> HomeSnapshot? {
        let now = clock.now()
        let calendar = self.calendar
        guard dayStart <= DayBoundary.dayStart(containing: now, calendar: calendar) else { return nil }
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
        // 途中の1日が読めなくても全体は欠かさず、その日だけ記録なしにする
        return (0..<max(days, 0)).reversed().compactMap { daysAgo -> DayPoints? in
            guard let dayStart = calendar.date(byAdding: .day, value: -daysAgo, to: today) else { return nil }
            let isToday = daysAgo == 0
            guard let snapshot = try? daySnapshot(dayStart: dayStart, now: now, events: events, calendar: calendar),
                  let recorded = try? isToday || hasRecord(dayStart: dayStart, snapshot: snapshot, calendar: calendar), recorded else {
                return DayPoints(dayStart: dayStart, points: nil, lastWeek: nil, isToday: isToday)
            }
            return DayPoints(dayStart: dayStart, points: snapshot.points,
                             lastWeek: snapshot.opponentPoints(.lastWeek, at: snapshot.now), isToday: isToday)
        }
    }

    /// その日に何か記録があるか：タイマーの記録・計画（下書き・確定・計画なし）・ブロックが効いていた時間のどれか。
    /// ない日は使い始める前などで、設定の睡眠の時刻だけで点が付いてしまうので数えない。
    /// 睡眠は開くたびに直近7日分を保存するので、使っていた印にはならない
    private func hasRecord(dayStart: Date, snapshot: HomeSnapshot, calendar: Calendar) throws -> Bool {
        let key = DayBoundary.dayKey(containing: dayStart, calendar: calendar)
        // ブロックが一度も効いていない日は開けた時間が nil（DTX-05 の「出さない日」と同じ判定）
        return try !store.sessions(dayKey: key).isEmpty || store.plan(dayKey: key) != nil || snapshot.opened != nil
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
            sleep: sleep.map(\.interval), sleepCaps: sleep.compactMap(\.extendedPart), dayStart: dayStart,
            onPlan: try onPlanContext(dayStart: dayStart, today: stored, calendar: calendar))
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

    /// 計画ブロックから始める。遅れて始めたら終わりを計画の長さぶんずらす（TMR-15）。
    /// 長さは始めた時点のブロックの長さとして残す（計画どおりの点の基準、GHO-16）。
    /// `endsAtBlockEnd` は「開始から始めていた（申告）」のとき（開始からの分は申告済みなので、終わりはブロックの終わり）
    func startPlanned(block: PlanBlockSummary, endsAtBlockEnd: Bool = false) {
        // ゲーム・SNS の時間（BLK-10）からはタイマーを始めない
        guard !block.category.isUnblock else { return }
        let length = max(60, Int(block.end.timeIntervalSince(block.start)))
        let now = clock.now()
        let end = endsAtBlockEnd ? block.end : OnPlanPoints.plannedEnd(blockStart: block.start, blockEnd: block.end, startingAt: now)
        start(StartRequest(category: block.category, project: block.project, planBlockId: block.id,
                           plannedEndAt: end, plannedDurationSec: length, timeZone: timeZone()))
    }

    func startUnplanned(category: CategoryOption, project: ProjectOption? = nil, minutes: Int?) {
        start(StartRequest(category: category, project: project, planBlockId: nil, plannedEndAt: nil,
                           plannedDurationSec: minutes.map { $0 * 60 }, timeZone: timeZone()))
    }

    // MARK: 計画どおりの点（GHO-16）

    /// その日と先週の同じ曜日の、計画どおりの点の材料（確定した計画だけ）。その日の計画は読み済みのものを渡す
    private func onPlanContext(dayStart: Date, today stored: StoredPlan?, calendar: Calendar) throws -> OnPlanContext {
        func confirmed(_ start: Date, _ loaded: StoredPlan?? = nil) throws -> (plan: StoredPlan, morning: Set<UUID>)? {
            let key = DayBoundary.dayKey(containing: start, calendar: calendar)
            guard let plan = try loaded ?? store.plan(dayKey: key), plan.status == .confirmed || plan.status == .unknown else { return nil }
            return (plan, Set((try store.snapshot(dayKey: key) ?? []).map(\.blockId)))
        }
        let today = try confirmed(dayStart, .some(stored))
        let lastWeek = try confirmed(DayBoundary.sameDayLastWeek(dayStart, calendar: calendar))
        return OnPlanContext(morningBlockIds: today?.morning ?? [], addedAt: today?.plan.addedAt ?? [:],
                             lastWeekPlan: lastWeek?.plan, lastWeekMorningBlockIds: lastWeek?.morning ?? [])
    }

    // MARK: 環境音（TMR-14）

    /// 環境音を選ぶ。覚えて、タイマーが動いていればすぐ流す（「なし」なら止める）
    func setAmbientSound(_ sound: AmbientSound) {
        ambientSound = sound
        settings.ambientSound = sound.rawValue
        syncAmbient()
    }

    func setAmbientVolume(_ volume: Double) {
        ambientVolume = min(max(volume, 0), 1)
        settings.ambientVolume = ambientVolume
        ambient.setVolume(ambientVolume)
    }

    /// タイマーが動いていれば流し、一時停止・終了・タイマーなしなら止める
    private func syncAmbient() {
        if let running, !running.session.isPaused, ambientSound != .none {
            ambient.play(ambientSound, volume: ambientVolume)
        } else {
            ambient.stop()
        }
    }

    // MARK: ウィジェット（WID-01）

    /// ウィジェットに渡すその日の材料。予定は確定した今日の計画（下書き・計画なし日は空）
    func widgetSnapshot(now: Date, isConfirmed: Bool) -> WidgetSnapshot {
        let blocks = isConfirmed ? (plan?.sortedBlocks ?? []).map {
            WidgetSnapshot.Block(title: $0.title, start: $0.start, end: $0.end, isGameTime: $0.isUnblock)
        } : []
        let session = running?.session
        let counting = session.map { $0.category.countsAsFocus && !$0.isPaused } ?? false
        let ghostCurve = snapshot.ghost.map { ghost in
            (0...Int(snapshot.dayEnd.timeIntervalSince(snapshot.dayStart) / WidgetSnapshot.curveStep)).map {
                ghost.focusSeconds(at: snapshot.dayStart.addingTimeInterval(Double($0) * WidgetSnapshot.curveStep))
            }
        } ?? []
        return WidgetSnapshot(generatedAt: now, dayStart: snapshot.dayStart, dayEnd: snapshot.dayEnd, blocks: blocks,
                              focusSeconds: snapshot.focusSeconds, runningStart: counting ? now : nil,
                              runningEnd: counting ? session?.plannedEnd(at: now) : nil, ghostCurve: ghostCurve)
    }

    // MARK: 自己ベスト・休み明け・ラップの帯（GHO-06・15、ANA-06）

    /// 自己ベスト（今日より前）と、先週より前に記録があるか（休み明け）をホームの数字に入れる
    private func addHistory(to snapshot: inout HomeSnapshot, calendar: Calendar) throws {
        let byDay = try focusByDay(calendar: calendar, today: snapshot.dayStart)
        snapshot.personalBest = DailyFocus.best(byDay, before: snapshot.dayStart)
        let lastWeekStart = DayBoundary.sameDayLastWeek(snapshot.dayStart, calendar: calendar)
        snapshot.hasOlderHistory = byDay.keys.contains { $0 < lastWeekStart }
    }

    /// 日ごとの集中。保存したとき・日が変わったときだけ読み直す（毎分の読み直しで全件を読まない）。
    /// タイマーが動いている間は今の分が毎分変わるので、覚えない
    private func focusByDay(calendar: Calendar, today: Date) throws -> [Date: Int] {
        if let cache = historyCache, cache.revision == store.revision, cache.today == today { return cache.byDay }
        let sessions = try store.allSessions()
        let byDay = DailyFocus.byDay(sessions.flatMap { $0.activeSegments(now: clock.now()) }, calendar: calendar)
        if sessions.allSatisfy({ !$0.isRunning }) { historyCache = (store.revision, today, byDay) }
        return byDay
    }

    /// 自己ベストのポイント（ANA-06）：記録のある日のうち一番多い1日の合計と、その日の 4:00。今日は入れない。
    /// 毎回数え直すので重い。分析の画面を開いたときだけ使う（使い始めから最大180日）
    func bestPointsDay() -> (points: Double, dayStart: Date)? {
        let calendar = self.calendar
        let today = DayBoundary.dayStart(containing: clock.now(), calendar: calendar)
        guard let first = (try? store.allSessions())?.first.map({ DayBoundary.dayStart(containing: $0.startAt, calendar: calendar) }) else {
            return nil
        }
        let days = min(180, max(1, (calendar.dateComponents([.day], from: first, to: today).day ?? 0) + 1))
        return pointsHistory(days: days).filter { !$0.isToday }.compactMap { day in day.points.map { ($0, day.dayStart) } }
            .max { $0.0 < $1.0 }
    }

    /// 時間帯の地図（ANA-07）：直近4週の曜日×2時間の集中の平均
    func timeMap() -> TimeMap {
        let calendar = self.calendar
        let today = DayBoundary.dayStart(containing: clock.now(), calendar: calendar)
        // 今日は入れないので、保存したとき・日が変わったときだけ数え直す
        if let cache = timeMapCache, cache.revision == store.revision, cache.today == today { return cache.map }
        let segments = ((try? store.allSessions()) ?? []).flatMap { $0.activeSegments(now: clock.now()) }
        let map = TimeMap.make(segments, today: today, calendar: calendar)
        timeMapCache = (store.revision, today, map)
        return map
    }

    /// 計画どおりの点（GHO-16）が付いたら「計画どおり +1pt（今日 2/3）」を出す（ブロックごとに1回）。出したら true
    private func announcePlanPoint(dayKey: String) -> Bool {
        let shown = Set((settings.lastRaceNotice ?? "").split(separator: ",").map(String.init).filter { $0.hasPrefix(dayKey + "|") })
        let keys = snapshot.planAwards.map { "\(dayKey)|plan|\($0.blockId)" }
        guard keys.contains(where: { !shown.contains($0) }) else { return false }
        // 開いていない間に2つ以上付いていても、出すのは今日の数の1回だけ（全部を出したことにする）
        settings.lastRaceNotice = shown.union(keys).sorted().joined(separator: ",")
        notice = "計画どおり +1pt（今日 \(keys.count)/\(OnPlanPoints.dailyLimit)）"
        raceNoticeCount += 1
        return true
    }

    /// 区間の区切り・中間地点を過ぎて開いたとき、帯と軽い振動で知らせる（1日に同じものは1回だけ、GHO-06）。
    /// 一度に出すのは1つ。出したものはその日の分だけ覚える
    private func announceRace(dayKey: String) {
        var shown = Set((settings.lastRaceNotice ?? "").split(separator: ",").map(String.init).filter { $0.hasPrefix(dayKey + "|") })
        func show(_ key: String, _ text: String) {
            shown.insert(key)
            settings.lastRaceNotice = shown.sorted().joined(separator: ",")
            notice = text
            raceNoticeCount += 1
        }
        if let lap = snapshot.laps(opponent).last(where: { !$0.isCurrent && !$0.isEmpty }) {
            let key = "\(dayKey)|\(Int(lap.interval.start.timeIntervalSinceReferenceDate))"
            if !shown.contains(key) { return show(key, "\(Self.lapRange(lap)) のラップ \(DurationFormat.signed(lap.diff))") }
        }
        let half = "\(dayKey)|half"
        if snapshot.halfwayTime(opponent) != nil, !shown.contains(half) { show(half, "中間地点を通過") }
    }

    static func lapRange(_ lap: Lap) -> String {
        let style = Date.FormatStyle.dateTime.hour(.defaultDigits(amPM: .omitted)).minute(.twoDigits)
        return "\(lap.interval.start.formatted(style))–\(lap.interval.end.formatted(style))"
    }

    // MARK: 押し忘れの申告（TMR-13）

    /// 今日の計画のブロックを `end` まで申告できないときの理由。できるなら nil
    func declarationProblem(for block: PlanBlockDraft, end: Date) -> Declaration.Problem? {
        guard let context = declarationContext() else { return .notInMorningPlan }
        return Declaration.problem(block: block, end: end, morningBlockIds: context.morning, sessions: context.sessions,
                                   opened: context.opened, now: clock.now())
    }

    /// 終わったブロックを「やった」と申告する。できたら true
    @discardableResult
    func declare(_ block: PlanBlockDraft, end: Date) -> Bool {
        guard declarationProblem(for: block, end: end) == nil else { return false }
        let saved = perform {
            _ = try store.declare(DeclareRequest(category: block.category, project: block.project, planBlockId: block.id,
                                                 start: block.start, end: end, plannedEndAt: block.end, timeZone: timeZone()))
        }
        reload()
        return saved
    }

    /// 今のブロックを始めるとき「開始から始めていた」にできる開始（ブロックの開始）。聞かないときは nil
    func lateStart(for block: PlanBlockSummary) -> Date? {
        guard running == nil, let draft = plan?.blocks.first(where: { $0.id == block.id }),
              let context = declarationContext() else { return nil }
        return Declaration.lateStart(block: draft, morningBlockIds: context.morning, sessions: context.sessions,
                                     opened: context.opened, now: clock.now())
    }

    /// 計画ブロックを始める。`fromBlockStart` ならブロックの開始〜今を申告にしてから、今からタイマーを動かす。
    /// 申告を保存できなかったときはタイマーも始めない（「保存できませんでした」を出す）。聞いている間に申告できなくなったら今から始める
    func startPlanned(block: PlanBlockSummary, fromBlockStart: Bool) {
        if fromBlockStart, let start = lateStart(for: block), let draft = plan?.blocks.first(where: { $0.id == block.id }) {
            let now = clock.now()
            let declared = perform {
                _ = try store.declare(DeclareRequest(category: draft.category, project: draft.project, planBlockId: draft.id,
                                                     start: start, end: now, plannedEndAt: draft.end, timeZone: timeZone()))
            }
            guard declared else { return }
            return startPlanned(block: block, endsAtBlockEnd: true)
        }
        startPlanned(block: block)
    }

    // MARK: 遅れ開始（TMR-15）

    /// 終わったブロックを今から始められるか：タイマーなし、記録なし、開始から1時間以内、ゲーム・SNS でない
    func canStartLate(_ block: PlanBlockDraft) -> Bool {
        let now = clock.now()
        return running == nil && !block.isUnblock && block.end <= now && now.timeIntervalSince(block.start) <= OnPlanPoints.window
            && !snapshot.startedBlockIds.contains(block.id)
    }

    /// 終わったブロックを今から始める（終わりは計画の長さぶん後ろ）
    func startLate(_ block: PlanBlockDraft) {
        guard canStartLate(block), let summary = snapshot.planBlocks.first(where: { $0.id == block.id }) else { return }
        startPlanned(block: summary)
    }

    /// 申告の判定の材料：今日の朝の計画のブロック、今日の記録、開けていた時間
    private func declarationContext() -> (morning: Set<UUID>, sessions: [FocusSession], opened: [DateInterval])? {
        let now = clock.now()
        let calendar = self.calendar
        let dayStart = DayBoundary.dayStart(containing: now, calendar: calendar)
        let dayKey = DayBoundary.dayKey(containing: now, calendar: calendar)
        var result: (Set<UUID>, [FocusSession], [DateInterval])?
        perform(reportsError: false) {
            guard let snapshot = try store.snapshot(dayKey: dayKey) else { return }
            let opened = (try? detoxDays(now: now, dayStart: dayStart, calendar: calendar).today.openedIntervals) ?? []
            result = (Set(snapshot.map(\.blockId)), try store.sessions(dayKey: dayKey), opened)
        }
        return result
    }

    /// 計画外のタイマー中に始まった計画ブロックに切り替える（TMR-11）。計画外の記録を今で終え、そのブロックを始める。
    /// 本人が画面で押す操作なので、止め忘れの確認は出さない
    func switchToBlock(_ block: PlanBlockSummary) {
        guard let timer = running, timer.switchableBlock(at: clock.now()) == block else { return }
        var result: EndResult?
        guard perform({ result = try store.end(id: timer.id, reportedEnd: nil) }) else { return }
        if result == .discardedTooShort { notice = Self.discardedNotice }
        // 切り替えはブロックの終わりまで（TMR-11 の決まり。遅れ開始の「終わりをずらす」は使わない）
        startPlanned(block: block, endsAtBlockEnd: true)
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
        // 計画なし日に決めた目標は、作る計画に引き継ぐ（GHO-10）。習慣のブロックが最初から入る（PLN-08）
        var draft = newDraft(dayStart: dayStart)
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

    // MARK: 習慣と候補（PLN-08・09）

    /// 習慣を保存する（端末の設定なので失敗しない）。次に作る下書きから効く（今日の計画は変えない）
    func saveHabits(_ habits: PlanHabits) {
        settings.habitsJSON = TemplateBlockValue.encode(habits.blocks.map(TemplateBlockValue.init))
        self.habits = storedHabits()
    }

    /// 習慣の最初の案内を閉じる。nil は「あとで」（習慣なしで始め、計画のタブで決める）
    func finishHabitIntro(_ habits: PlanHabits?) {
        saveHabits(habits ?? PlanHabits())
        settings.habitIntroPending = false
        showsHabitIntro = false
        reload()
    }

    /// その日に足せる候補。昨日・先週の同じ曜日の確定した計画と、テンプレートのブロック。
    /// `excludingEnded`（計画のタブ）なら終わった時間のものを出さない。アーカイブしたカテゴリ・ブロック名のものは出さない
    func candidates(for plan: PlanDraft, dayStart: Date, excludingEnded: Bool) -> [PlanCandidate] {
        let calendar = self.calendar
        var result: [PlanCandidate] = []
        perform(reportsError: false) {
            var sources: [PlanCandidates.SourcePlan] = []
            for (source, offset) in [(PlanCandidate.Source.yesterday, -1), (.lastWeek, -7)] {
                guard let start = calendar.date(byAdding: .day, value: offset, to: dayStart),
                      let stored = try store.plan(dayKey: DayBoundary.dayKey(containing: start, calendar: calendar)),
                      stored.status == .confirmed || stored.status == .unknown else { continue }
                sources.append(.init(source: source, plan: stored.draft, dayStart: start))
            }
            result = PlanCandidates.make(plan: plan, dayStart: dayStart, calendar: calendar, sources: sources, templates: templates,
                                         notEndedBy: excludingEnded ? clock.now() : nil)
                .filter { isActive($0.block.category, $0.block.project) }
        }
        return result
    }

    /// 初めて使う端末なら最初の案内を出す。すでに使っている端末で習慣がまだなければ、引き継いでいた時刻で作る
    private func setUpHabits(isFreshInstall: Bool, offersIntro: Bool) {
        if settings.habitsJSON == nil {
            if isFreshInstall && offersIntro {
                settings.habitIntroPending = true
                settings.habitsJSON = TemplateBlockValue.encode([])
            } else {
                let calendar = self.calendar
                let dayStart = DayBoundary.dayStart(containing: clock.now(), calendar: calendar)
                // 読めなければ覚えず、次の起動でやり直す
                perform(reportsError: false) {
                    let carried = try carriedDraft(dayStart: dayStart, calendar: calendar)
                    settings.habitsJSON = TemplateBlockValue.encode(PlanHabits(plan: carried, calendar: calendar).blocks
                        .map(TemplateBlockValue.init))
                }
            }
        }
        showsHabitIntro = offersIntro && settings.habitIntroPending
    }

    /// 保存した習慣。アーカイブしたカテゴリ・ブロック名のブロックは入れない
    private func storedHabits() -> PlanHabits {
        guard let data = settings.habitsJSON else { return PlanHabits() }
        let categoryMap = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let projectMap = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return PlanHabits(blocks: TemplateBlockValue.decode(data).compactMap { value in
            guard let category = value.categoryId == CategoryOption.gameSNS.id ? .gameSNS : categoryMap[value.categoryId] else { return nil }
            let project = value.projectId.flatMap { projectMap[$0] }
            if value.projectId != nil, project == nil { return nil }
            return PlanTemplate.Block(hour: value.hour, minute: value.minute, minutes: value.minutes, category: category, project: project)
        })
    }

    private func isActive(_ category: CategoryOption, _ project: ProjectOption?) -> Bool {
        categories.contains(category) && (project.map(projects.contains) ?? true)
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
