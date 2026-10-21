import Foundation
import Observation

/// 手動の記録（TMR-13）を保存した結果。
enum ManualSaveResult: Equatable {
    case saved
    /// 条件に合わないので保存しなかった（理由は errorMessage にも出す）
    case refused(ManualRecord.Problem)
    /// 保存に失敗した（「保存できませんでした」）
    case failed
}

/// 朝の計画・明日の計画を出すときの値。開いた時点の日を持ち続ける（編集中にその日の区切りを過ぎても、その日の計画として保存する）。
struct MorningPlan: Identifiable, Hashable {
    var day: BoundaryDay
    var draft: PlanDraft
    /// 格子の始まり（朝の計画は起きた時刻、明日の計画は一日の始まり。PLN-11、Q47）
    var gridStart: Date

    init(day: BoundaryDay, draft: PlanDraft, gridStart: Date? = nil) {
        self.day = day
        self.draft = draft
        self.gridStart = gridStart ?? day.start
    }

    var dayKey: String { day.key }
    var dayStart: Date { day.start }
    var dayEnd: Date { day.end }
    var id: String { dayKey }
}

/// 区切りを変えたときの、設定の行の下の知らせ（settings.md、Q46）
struct PendingBoundaryChange: Hashable {
    /// 今日の区切り（日の名前の日の 0:00 からの分）
    var todayEndMinutes: Int
    /// 明日の区切り
    var tomorrowEndMinutes: Int
    /// 明日の長さ（時間）
    var tomorrowHours: Double
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
    /// いつものブロックを外すゲーム・SNS の時間（BLK-10）：今日の計画（確定、または区切りから朝に確定するまでの下書き）のものと、
    /// 次の日の前の夜の分（区切り〜設定の睡眠の起きる時刻。次の日の下書き、なければ習慣。PLN-11、Q47）。計画なし日は空
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
    /// タイマーのタブが見えているか（ホームの帯はそのときだけ出す、2026-10-11）。`setTimerTabVisible` で入れる
    private(set) var isTimerTabVisible = true
    /// 自己ベストと休み明けの判定の材料（記録の数が変わったときだけ数え直す）
    private var historyCache: (revision: Int, today: Date, byDay: [Date: Int])?
    private var timeMapCache: (revision: Int, today: Date, map: TimeMap)?
    /// 過ぎた日のポイントと材料、期間ごとの記録（分析）。保存したとき・日が変わったとき・ブロックの記録や睡眠の設定が
    /// 変わったときだけ数え直す（全期間の自己ベスト・平均・区間ベストで毎回全部の日を数えない）
    private var pastCache: PastCache?

    private struct PastCache {
        var revision: Int
        var today: Date
        var events: Int
        var sleep: (start: Int, end: Int)
        var days: [Date: DayPoints] = [:]
        /// 記録のある過ぎた日の材料（HomeSnapshot は丸ごと覚えない）
        var recordDays: [Date: RecordDay] = [:]
        /// 期間ごとの記録・理論ベスト・ベスト10（ANA-06・09・11）
        var periods: [BestPeriod: PeriodRecords] = [:]

        func matches(revision: Int, today: Date, events: Int, sleep: (start: Int, end: Int)) -> Bool {
            self.revision == revision && self.today == today && self.events == events && self.sleep == sleep
        }
    }
    var endTimeCheck: EndTimeCheck?
    /// 実行中のタイマーの画面に出す「11:00 から始めていた？［前の分を足す］」の区間（TMR-13）。出さないときは nil
    private(set) var previousPart: DateInterval?
    /// 短い知らせ（ホームの上に2秒出す）
    var notice: String?
    var errorMessage: String?
    /// ホームの円で比べる相手（GHO-10）。端末の設定に覚えておく
    private(set) var opponent: Opponent
    /// 一日の区切りの履歴（GHO-17、data-model.md「DayBoundaryChange」）。読み直すたびに読む
    private(set) var boundaryChanges: [DayBoundaryChange] = []
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
         ambient: any AmbientPlaying = SilentAmbientPlayer(), startsOnTimerTab: Bool = true) {
        // 最初のタブがタイマー以外（`-openAnalysis` など）なら、最初の読み直しでホームの帯を出さない
        isTimerTabVisible = startsOnTimerTab
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
        sleepSettings = (settings.sleepStartMinutes, settings.sleepEndMinutes)
        plannedEndNotifications = settings.plannedEndNotifications
        blockNoticeMinutes = settings.blockNoticeMinutes
        let now = clock.now()
        snapshot = HomeSnapshot.make(now: now, calendar: .app(timeZone: timeZone()), todaySessions: [], plan: PlanDraft(),
                                     lastWeekSessions: [])
        // 区切りの履歴より前に、移す端末か新しく入れた端末かを決める（カテゴリなどを入れる前の記録で）
        let hasRecord = (try? store.hasAnyRecord()) ?? true
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
        setUpBoundary(hasRecord: hasRecord)
        setUpHabits(isFreshInstall: isFreshInstall, offersIntro: offersHabitIntro)
        reload()
        // 終了していた状態から開いたときも、シールドの「開く」から2分以内なら長押しの画面を出す（BLK-08）
        checkUnlockRequest()
    }

    var calendar: Calendar { .app(timeZone: timeZone()) }

    /// 一日の区切り（GHO-17）。区切りの履歴と、そのときの端末のタイムゾーンで決める
    var boundary: DayBoundary { DayBoundary(calendar: calendar, changes: boundaryChanges) }

    /// 区切りの履歴が1行もなければ足す（data-model.md「第5版から移すとき」、Q46）。
    /// タイマーの記録か1日の計画がある端末は、今の日（朝4:00区切り）までそのままで、次の日から 22:00。
    /// 新しく入れた端末は、その時点の日（22:00 区切り）から 22:00（その日が前の夜 22:00 から始まるよう、前の日を fromDayKey にする）。
    /// 読めない・書けないときは足さず（すべての日を朝4:00区切りで数える）、次の起動でやり直す
    private func setUpBoundary(hasRecord: Bool) {
        perform(reportsError: false) {
            var changes = try store.boundaryChanges()
            if changes.isEmpty {
                let now = clock.now()
                let from: String
                if hasRecord {
                    let legacy = DayBoundary(calendar: calendar)
                    from = legacy.day(1, from: legacy.day(containing: now)).key
                } else {
                    let evening = DayBoundary(calendar: calendar,
                                              changes: [DayBoundaryChange(fromDayKey: "0000-01-01", endMinutes: DayBoundary.defaultEndMinutes)])
                    from = evening.day(-1, from: evening.day(containing: now)).key
                }
                try store.setBoundary(endMinutes: DayBoundary.defaultEndMinutes, fromDayKey: from, timeZone: timeZone())
                changes = try store.boundaryChanges()
            }
            boundaryChanges = changes
        }
    }

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
            boundaryChanges = try store.boundaryChanges()
            let boundary = self.boundary
            let today = boundary.day(containing: now)
            let dayKey = today.key
            categories = try store.categories()
            projects = try store.projects()
            templates = try store.templates()
            habits = storedHabits()

            var stored = try store.plan(dayKey: dayKey)
            // 下書きがなければ、区切りより後に最初に読み直したときに習慣で作る（前の夜のゲーム・SNS の時間などに使う。PLN-11、Q47）
            if stored == nil, !today.isLegacy, !showsHabitIntro {
                let draft = newDraft(day: today)
                if !draft.blocks.isEmpty {
                    try store.saveDraft(draft, dayKey: dayKey, timeZone: timeZone())
                    stored = try store.plan(dayKey: dayKey)
                }
            }
            plan = stored?.status == .skipped ? nil : (stored?.draft ?? PlanDraft())
            let isConfirmed = stored?.status == .confirmed || stored?.status == .unknown
            isPlanConfirmed = isConfirmed
            // 区切りから朝の計画を確定するまでは、下書きをふつうの計画と同じに使う（PLN-11、2026-10-21 オーナー決定）
            let usesDraft = !today.isLegacy && stored?.status == .draft
            let next = boundary.day(1, from: today)
            confirmedUnblocks = (isConfirmed || usesDraft ? (plan?.blocks.filter(\.isUnblock) ?? []) : [])
                + (try nightBlocks(of: next, includingHabits: true).blocks.filter(\.isUnblock))
            let todaySessions = try store.sessions(dayKey: dayKey)
            // 計画の前の通知：確定した今日の計画と、前の夜の予定（今日の下書きの前の夜の分・次の日の下書きの前の夜の分）
            noticeBlocks = (isConfirmed ? (plan?.summaries ?? []) : usesDraft ? nightPart(plan, of: today).summaries : [])
                + (try nightBlocks(of: next, includingHabits: false).summaries)
            startedBlockIds = Set(todaySessions.compactMap(\.planBlockId))

            let detox = try detoxDays(now: now, day: today)
            snapshot = HomeSnapshot.make(now: now, calendar: calendar,
                                         todaySessions: todaySessions + (try carriedOver(into: today)),
                                         plan: plan, lastWeekSessions: try lastWeekSessions(of: today),
                                         noPlanGoalSeconds: stored?.draft.goalSeconds,
                                         detox: detox.today, lastWeekDetox: detox.lastWeek, sleep: detox.sleep, sleepCaps: detox.sleepCaps,
                                         awakeSleep: detox.awake, day: today, lastWeekDay: boundary.day(-7, from: today),
                                         onPlan: try onPlanContext(day: today, today: stored))
            snapshot.showsReviewEntry = showsReviewEntry(today: today, stored: stored, now: now)

            try addHistory(to: &snapshot)
            snapshot.awake = awakeRange(day: today)

            if let session = try store.runningSession() {
                running = try runningTimer(session, today: today, now: now)
                // タイマーの画面の「前の分を足す」（TMR-13）。読めなければ出さない
                previousPart = (try? addablePreviousPart(of: session)) ?? nil
            } else {
                running = nil
                endTimeCheck = nil
                previousPart = nil
            }
            widgets.publish(widgetSnapshot(now: now, isConfirmed: isConfirmed || usesDraft))
            syncAmbient()
            // ロック画面と画面上部のタイマー（TMR-06）。開き直したときも、実行中なら出し直す
            liveActivity.show(running.map { TimerActivity.make($0.session, now: now, timeZone: calendar.timeZone) })
            refreshNotifications()
            refreshBlocking(now: now)
            // 睡眠は付随の機能なので、読み書きに失敗しても朝の計画などは続ける
            do { try ensureSleep(today: today, now: now) } catch { sleep = nil }

            // 実行中のタイマーがあればタイマーを優先し、終了後に出す。開いている朝の計画は置き換えない。
            // 朝の計画は朝4:00以降に出す（その日の区切り〜3:59 は出さない、PLN-01）
            let needsPlan = stored == nil || stored?.status == .draft
            // 初めて使う端末は、習慣を決めてから朝の計画を出す（PLN-08）
            if running == nil, needsPlan, morningPlan == nil, !showsHabitIntro, boundary.isMorning(now) {
                let draft = stored?.draft ?? newDraft(day: today)
                morningPlan = MorningPlan(day: today, draft: draft, gridStart: morningGridStart(day: today))
            }
            announceNotices(dayKey: dayKey)
        }
    }

    /// 次の日の前の夜の分（その日の始まり〜設定の睡眠の起きる時刻）のブロック。下書きがあればそのブロック、
    /// なければ `includingHabits` のとき習慣（ゲーム・SNS の時間でいつものブロックを外す予定を先に登録するため、Q47）。
    /// 確定した・計画しない日は空（次の日はまだ来ていないので、ふつうは下書きか、まだない）
    private func nightBlocks(of day: BoundaryDay, includingHabits: Bool) throws -> PlanDraft {
        guard !day.isLegacy else { return PlanDraft() }
        let stored = try store.plan(dayKey: day.key)
        if let stored {
            return stored.status == .draft ? nightPart(stored.draft, of: day) : PlanDraft()
        }
        return includingHabits ? nightPart(newDraft(day: day), of: day) : PlanDraft()
    }

    /// 前の夜の分：その日の始まり〜設定の睡眠の起きる時刻に始まるブロック（起きた時刻はまだ分からないので設定の時刻。Q47）
    private func nightPart(_ plan: PlanDraft?, of day: BoundaryDay) -> PlanDraft {
        let wake = SleepLine.fromSetting(startMinutes: sleepSettings.start, endMinutes: sleepSettings.end, dayStart: day.date,
                                         calendar: calendar).end
        return PlanDraft(blocks: (plan?.blocks ?? []).filter { $0.start >= day.start && $0.start < wake })
    }

    /// 朝の計画の格子の始まり：起きた時刻（:00・:30 に切り下げ）。分からなければ朝4:00（PLN-11、Q47）
    func morningGridStart(day: BoundaryDay) -> Date {
        let morning = boundary.morningStart(of: day)
        guard let wake = sleepLine(day: day)?.end, wake > day.start, wake < day.end else { return morning }
        let step = Double(PlanGridLayout.snapMinutes * 60)
        let floored = Date(timeIntervalSinceReferenceDate: (wake.timeIntervalSinceReferenceDate / step).rounded(.down) * step)
        return max(floored, day.start)
    }

    /// ホームに「今日を振り返る」を出すか（REV-02）。その日の区切りから、次の朝の計画を確定する（「今日は計画しない」を含む）まで。
    /// 遅くとも次の区切りまで（その日のうちだけ見る）。区切りの履歴より前の日（移した日）は今までどおり 22:00 から朝4:00まで（Q46・Q47）
    private func showsReviewEntry(today: BoundaryDay, stored: StoredPlan?, now: Date) -> Bool {
        if today.isLegacy { return now >= boundary.wallClock(today.date, minutes: DayBoundary.defaultEndMinutes) }
        return isReviewingFinishedDay(today: today, stored: stored)
    }

    /// 終わったばかりの日を振り返る時間か：今の日の朝の計画をまだ確定していない（計画しないも含めて決めていない）
    private func isReviewingFinishedDay(today: BoundaryDay, stored: StoredPlan?) -> Bool {
        !today.isLegacy && (stored == nil || stored?.status == .draft)
    }

    /// ホームの帯（計画どおりの点・ラップ・中間地点）を出す。計画どおりの点はタイマー中も（タイマーの画面に）知らせ、
    /// ラップの帯はタイマー中は出さない。タイマーの画面が出ていないときは、タイマーのタブにいるときだけ出す
    /// （分析・計画のタブにいる間は出したことにせず、戻ったときに出す。2026-10-11）
    private func announceNotices(dayKey: String) {
        guard morningPlan == nil, running != nil || isTimerTabVisible else { return }
        if !announcePlanPoint(dayKey: dayKey), running == nil { announceRace(dayKey: dayKey) }
    }

    /// 下のタブでタイマーのタブが見えているか（ContentView が切り替えるたびに入れる）。
    /// 戻ったときに、出していない帯を出す。戻る前にその日の区切りを過ぎていたら読み直して新しい日の分だけ（前の日の分は出さない）
    func setTimerTabVisible(_ visible: Bool) {
        isTimerTabVisible = visible
        guard visible else { return }
        let today = boundary.day(containing: clock.now())
        if today.start != snapshot.dayStart {
            reload(quietly: true)
        } else {
            announceNotices(dayKey: today.key)
        }
    }

    /// 動いているタイマー。差は今の日（区切りを過ぎたら新しい日の0から）で比べる（focus-timer.md、Q47）
    private func runningTimer(_ session: FocusSession, today: BoundaryDay, now: Date) throws -> RunningTimer {
        let others = (try store.sessions(dayKey: today.key) + carriedOver(into: today)).filter { $0.id != session.id }
        let countsFrom = max(session.startAt, today.start)
        let stored = try store.plan(dayKey: today.key)
        let plan = stored?.status == .skipped ? nil : stored?.draft
        let sleep = try daySleep(today)
        let isConfirmed = stored?.status == .confirmed || stored?.status == .unknown
        let usesDraft = !today.isLegacy && stored?.status == .draft
        return RunningTimer(
            session: session,
            focusSecondsBefore: others.flatMap { $0.activeSegments(now: countsFrom) }.compactMap { $0.starting(at: today.start) }
                .focusSeconds(until: countsFrom),
            ghost: GhostSummary(lastWeek: try lastWeekSessions(of: today), lastWeekDay: boundary.day(-7, from: today).interval,
                                shift: today.date.timeIntervalSince(boundary.day(-7, from: today).date)),
            goal: GoalGhost(plan: plan, goalSeconds: stored?.draft.goalSeconds, sleep: sleep.awake.map(\.interval),
                            dayStart: today.start, dayEnd: today.end, dayDate: today.date, calendar: calendar).nonEmpty,
            // 切り替え・計画の時刻の通知は確定した今日の計画だけ。下書きは前の夜の予定の分だけ（ふつうの計画と同じに動く、PLN-11）
            planBlocks: isConfirmed ? (plan?.summaries ?? []) : usesDraft ? nightPart(plan, of: today).summaries : [],
            countsFrom: countsFrom > session.startAt ? countsFrom : nil)
    }

    // MARK: 対戦相手（GHO-10）

    func selectOpponent(_ opponent: Opponent) {
        self.opponent = opponent
        settings.opponent = opponent
    }

    // MARK: 夜の振り返り（REV-01）

    /// 振り返る日（REV-01、review.md「どの日を振り返るか」）。その日の区切りから次の朝の計画を確定するまでは、
    /// 終わったばかりの日（確定した日）。それ以外は今の日（「今のところ」）
    func reviewDay(now: Date? = nil) -> BoundaryDay {
        let now = now ?? clock.now()
        let today = boundary.day(containing: now)
        let stored = try? store.plan(dayKey: today.key)
        return isReviewingFinishedDay(today: today, stored: stored ?? nil) ? boundary.day(-1, from: today) : today
    }

    /// 振り返り（終わったばかりの日、または今の日の今まで）。読めなければ nil
    func reviewContent() -> ReviewContent? {
        // 日付・合計・相手の値を同じ時刻から作る（ホームの表示は最大1分古いことがある）
        let now = clock.now()
        let day = reviewDay(now: now)
        var content: ReviewContent?
        perform(reportsError: false) {
            let stored = try store.plan(dayKey: day.key)
            let sessions = try store.sessions(dayKey: day.key)
            var home = try daySnapshot(day: day, now: now, events: (try? blockLog.all()) ?? [])
            try addHistory(to: &home)
            // 確定した日だけ朝の計画と比べる。下書きのまま・計画なし日は計画なしとして扱う
            let confirmed = stored?.status == .confirmed || stored?.status == .unknown
            content = ReviewContent.make(home: home, sessions: sessions,
                                         snapshot: confirmed ? (try store.snapshot(dayKey: day.key) ?? []) : nil)
            content?.isFinal = day.end <= now
            content?.finalLabel = day.isLegacy ? nil : BoundaryText.time(day.endMinutes)
        }
        return content
    }

    /// 「明日の計画を立てる」で開く計画。明日は振り返っている日の次の日（区切りの後に開いたら、もう始まっている今の日。
    /// 0:00 を過ぎて開いても同じ日。review.md）。下書きがあれば続きから
    func tomorrowPlan() -> MorningPlan {
        let tomorrow = boundary.day(1, from: reviewDay())
        var draft = PlanDraft()
        perform(reportsError: false) {
            if let stored = try store.plan(dayKey: tomorrow.key) {
                if stored.status == .draft { draft = stored.draft }
            } else {
                draft = newDraft(day: tomorrow)
            }
        }
        return MorningPlan(day: tomorrow, draft: draft)
    }

    /// 新しく作る下書き。習慣のブロックが最初から入る（PLN-08、2026-10-05 に前の日からの引き継ぎから変更）
    private func newDraft(day: BoundaryDay) -> PlanDraft {
        habits.draft(day: day, calendar: calendar)
    }

    /// それまでの「前の日から引き継ぐ」ゲーム・SNS の時間（BLK-10、2026-10-02）。すでに使っている端末の最初の習慣に使う。
    /// 前の日に確定した計画がなければ、7日前までさかのぼって最後に確定した日から。その日に1つもなければ、なし
    private func carriedDraft(today: BoundaryDay) throws -> PlanDraft {
        for offset in 1...7 {
            let previous = boundary.day(-offset, from: today)
            let stored = try store.plan(dayKey: previous.key)
            guard let stored, stored.status == .confirmed || stored.status == .unknown else { continue }
            return PlanDraft(blocks: PlanDraft.carriedUnblocks(stored.draft.blocks, previousDayStart: previous.date,
                                                               dayStart: today.date, calendar: calendar))
        }
        return PlanDraft()
    }

    /// 明日の計画の下書きを保存する。翌朝の朝の計画に出る。区切りより後の予定（前の夜の予定）の通知と、
    /// ゲーム・SNS の時間のブロックを外す予定も、ここで登録し直す（アプリを開かなくても動くように、PLN-11）
    /// `reloads` は「保存」を押したとき（下書きが変わるたびには読み直さない）
    @discardableResult
    func saveTomorrowDraft(_ draft: PlanDraft, for plan: MorningPlan, reloads: Bool = false) -> Bool {
        let saved = perform { try store.saveDraft(draft, dayKey: plan.dayKey, timeZone: timeZone()) }
        if saved, reloads { reload(quietly: true) }
        return saved
    }

    // MARK: 通知（TMR-05、REV-02）

    /// 予約をいまの状態にそろえる（予定の時間・計画ブロックの前・振り返り）。許可がなければ何もしない
    func refreshNotifications() {
        let now = clock.now()
        let plan = NotificationPlan.make(running: running?.session, now: now,
                                         plannedEndEnabled: plannedEndNotifications,
                                         review: ReviewSchedule.make(boundary: boundary, now: now),
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

    // MARK: 一日の区切り（GHO-17）

    /// 設定の画面に出す区切り（一番新しい行）
    var boundaryEndMinutes: Int { boundary.latestEndMinutes }

    /// 今日の区切り（日の名前の日の 0:00 からの分）
    var todayEndMinutes: Int { boundary.day(containing: clock.now()).endMinutes }

    /// 区切りを変えたときの、行の下の知らせ（settings.md、Q46）。次の日の区切りが今日と同じなら nil
    var pendingBoundaryChange: PendingBoundaryChange? {
        let today = boundary.day(containing: clock.now())
        let next = boundary.day(1, from: today)
        guard next.endMinutes != today.endMinutes else { return nil }
        return PendingBoundaryChange(todayEndMinutes: today.endMinutes, tomorrowEndMinutes: next.endMinutes,
                                     tomorrowHours: next.duration / 3600)
    }

    /// 一日の区切りを変える（20:00〜翌4:00、30分きざみ）。次の日から効く（今日は今の区切りで確定する。2026-10-21 オーナー決定）。
    /// 同じ日に何度変えても、最後に選んだものが次の日から効く。使い始めた行は書き換えない
    @discardableResult
    func setBoundary(endMinutes: Int) -> Bool {
        let minutes = DayBoundary.normalized(endMinutes)
        let today = boundary.day(containing: clock.now())
        let next = boundary.day(1, from: today)
        guard next.endMinutes != minutes else { return true }
        let saved = perform { try store.setBoundary(endMinutes: minutes, fromDayKey: next.key, timeZone: timeZone()) }
        reload(quietly: true)
        return saved
    }

    // MARK: 目標・テンプレート（GHO-10、PLN-07）

    /// 計画なし日の目標（GHO-10、Q13）。nil で目標なし
    @discardableResult
    func setNoPlanGoal(_ seconds: Int?) -> Bool {
        let dayKey = boundary.dayKey(containing: clock.now())
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
    private func detoxDays(now: Date, day: BoundaryDay) throws
        -> (today: DetoxDay, lastWeek: DetoxDay, sleep: [DateInterval], sleepCaps: [DateInterval], awake: [DateInterval]) {
        // 記録のファイルが読めなくても、ほかの表示は続ける（デトックスが0になるだけ）
        let events = (try? blockLog.all()) ?? []
        let sleep = try daySleep(day)
        return (try detoxDay(day, until: now, events: events),
                try detoxDay(boundary.day(-7, from: day), until: .distantFuture, events: events),
                sleep.points.map(\.interval), sleep.points.compactMap(\.extendedPart), sleep.awake.map(\.interval))
    }

    /// 1日分の材料を集めて数える（digital-detox.md「数え方」）
    private func detoxDay(_ day: BoundaryDay, until: Date, events: [BlockEvent]) throws -> DetoxDay {
        // 前の日に始めて区切りをまたいだタイマーも入れる
        let sessions = try store.sessions(dayKey: day.key) + store.sessions(dayKey: boundary.day(-1, from: day).key)
        let segments = sessions.flatMap { $0.activeSegments(now: min(until, clock.now())) }
        let plan = try store.plan(dayKey: day.key)
        let sleep = try daySleep(day).points
        return DetoxDay.make(DetoxDay.Inputs(
            dayStart: day.start, dayEnd: day.end, until: until, events: events,
            focus: segments.filter(\.countsAsFocus).map { DateInterval(start: $0.start, end: max($0.start, $0.end)) },
            detoxTimers: segments.filter { !$0.countsAsFocus }.map {
                DetoxTimer(interval: DateInterval(start: $0.start, end: max($0.start, $0.end)), group: $0.detoxGroup,
                           isDeclared: $0.isDeclared)
            },
            // その日の朝に終わった睡眠（一晩分まとめて起きた日に。区切りより前に寝始めた分は寝た日に残る、Q48）。
            // 区切りの履歴より前の日は、今までどおりその夜の睡眠も（翌朝決まるまでは設定の時刻で仮に数える）
            sleep: sleep.map(\.interval),
            gameWindows: gameWindows(plan, of: day),
            // 手で直す前より長くした所は、0.5pt と睡眠の点の低いほう（DTX-03）
            sleepCaps: sleep.compactMap(\.extendedPart)))
    }

    /// その日の予定のゲーム・SNS の時間。区切りの履歴より前の日は確定した計画だけ（今までの数え方）。
    /// それより後の日は、下書き（区切りから朝に確定するまで、PLN-11）と計画しない日に残した前の夜の分も
    private func gameWindows(_ plan: StoredPlan?, of day: BoundaryDay) -> [DateInterval] {
        guard let plan else { return [] }
        let confirmed = plan.status == .confirmed || plan.status == .unknown
        guard confirmed || !day.isLegacy else { return [] }
        return plan.draft.blocks.filter(\.isUnblock).map { DateInterval(start: $0.start, end: $0.end) }
    }

    /// その日の睡眠。`points` は点を付ける睡眠（その日の朝に終わった睡眠。区切りの履歴より前の日はその夜の睡眠も）、
    /// `awake` は起きている時間に使う [その朝の睡眠, その夜の睡眠]（その夜は設定の時刻。区切りの履歴より前の日はその夜の記録）
    func daySleep(_ day: BoundaryDay) throws -> (points: [SleepLine], awake: [SleepLine]) {
        let morning = try sleepLine(storedFor: day)
        let next = boundary.day(1, from: day)
        if day.isLegacy {
            let night = try sleepLine(storedFor: next)
            return ([morning, night], [morning, night])
        }
        let tonight = SleepLine.fromSetting(startMinutes: sleepSettings.start, endMinutes: sleepSettings.end, dayStart: next.date,
                                            calendar: calendar)
        return ([morning], [morning, tonight])
    }

    /// その日の朝に終わった睡眠。保存していなければ設定の時刻
    private func sleepLine(storedFor day: BoundaryDay) throws -> SleepLine {
        try store.sleep(dayKey: day.key)
            ?? .fromSetting(startMinutes: sleepSettings.start, endMinutes: sleepSettings.end, dayStart: day.date, calendar: calendar)
    }

    /// 先週の同じ曜日のセッション（GHO-02）。前の日に始めて区切りをまたいだものも入れる
    private func lastWeekSessions(of day: BoundaryDay) throws -> [FocusSession] {
        let lastWeek = boundary.day(-7, from: day)
        return try store.sessions(dayKey: lastWeek.key) + (try carriedOver(into: lastWeek))
    }

    /// 前の日に始めてその日の始まり（前の日の区切り）をまたいだセッション。区切りより後の分はその日の集中に入れる（GHO-14、2026-10-03）
    private func carriedOver(into day: BoundaryDay) throws -> [FocusSession] {
        let now = clock.now()
        return try store.sessions(dayKey: boundary.day(-1, from: day).key).filter { ($0.endAt ?? now) > day.start }
    }

    // MARK: 分析（ANA-04・05）：過去の日のポイント。ホームと同じ計算をその日の記録でやり直す

    /// `daysAgo` 日前（今日は0）の1日分の数字。今日は今まで、過ぎた日はその日の区切りまで。未来・読めないときは nil
    func daySnapshot(daysAgo: Int) -> HomeSnapshot? {
        guard daysAgo >= 0 else { return nil }
        let today = boundary.day(containing: clock.now())
        return daySnapshot(of: boundary.day(-daysAgo, from: today).start)
    }

    /// `dayStart`（その日の始まり）の1日分の数字。分析で押した日を、開いたまま区切りをまたいでも取り違えないよう日付で開く
    func daySnapshot(of dayStart: Date) -> HomeSnapshot? {
        let now = clock.now()
        let boundary = self.boundary
        guard dayStart <= boundary.dayStart(containing: now) else { return nil }
        var snapshot: HomeSnapshot?
        perform(reportsError: false) {
            snapshot = try daySnapshot(day: boundary.day(containing: dayStart), now: now, events: (try? blockLog.all()) ?? [])
        }
        return snapshot
    }

    /// 自己ベストから開いたその日のグラフ（ANA-05、2026-10-11）：相手を今日にする。
    /// 今日の数字は同じ時刻でそろえて持たせる（GHO-02）。押した日が今日なら今までどおり（相手は今日にしない）
    func daySnapshot(of dayStart: Date, versusToday: Bool) -> HomeSnapshot? {
        guard var snapshot = daySnapshot(of: dayStart) else { return nil }
        let today = boundary.dayStart(containing: clock.now())
        guard versusToday, dayStart < today, let mine = daySnapshot(of: today) else { return snapshot }
        snapshot.todayRival = TodayRival(today: mine, alignedTo: snapshot.dayDate)
        return snapshot
    }

    /// `days` 日（古い日が先）のポイントと、先週の同じ曜日のポイント。`page` は0が今日を右の端にした期間で、
    /// 1つ増えるごとに `days` 日ずつ前へさかのぼる（ANA-04）
    func pointsHistory(days: Int, page: Int = 0) -> [DayPoints] {
        let boundary = self.boundary
        let today = boundary.day(containing: clock.now())
        let last = max(page, 0) * days
        return pointsHistory(dayStarts: (last..<last + max(days, 0)).reversed().map { boundary.day(-$0, from: today).start })
    }

    /// ‹ でもう1期間前へ行けるか：今見ている期間より前に、一番古いタイマーの記録の日がある
    func canGoBack(days: Int, page: Int) -> Bool {
        let boundary = self.boundary
        let today = boundary.day(containing: clock.now())
        guard let oldest = oldestRecordDay() else { return false }
        let first = boundary.day(-(max(page, 0) * days + days - 1), from: today).start
        return oldest < first
    }

    /// 一番古いタイマーの記録の日の始まり
    private func oldestRecordDay() -> Date? {
        let boundary = self.boundary
        return (try? store.allSessions())?.first.map { boundary.dayStart(containing: $0.startAt) }
    }

    /// 覚えた過ぎた日の数字が今も使えるか確かめ、使えなければ空にする。
    /// ブロックの記録はあとから届くことがある（ブロックの画面の拡張が書く）ので、件数が変わっても数え直す。
    /// 睡眠を保存していない日は設定の睡眠の時刻で点が付き、睡眠の区間も設定で決まるので、設定を変えても数え直す
    private func refreshPastCache(today: Date, events: Int) {
        if pastCache?.matches(revision: store.revision, today: today, events: events, sleep: sleepSettings) != true {
            pastCache = PastCache(revision: store.revision, today: today, events: events, sleep: sleepSettings)
        }
    }

    /// 指定した日（その日の始まり、古い日が先）のポイントと、先週の同じ曜日のポイント
    private func pointsHistory(dayStarts: [Date], events: [BlockEvent]? = nil) -> [DayPoints] {
        let now = clock.now()
        let boundary = self.boundary
        let today = boundary.dayStart(containing: now)
        // ブロックの記録は1回だけ読む
        let events = events ?? (try? blockLog.all()) ?? []
        refreshPastCache(today: today, events: events.count)
        // 途中の1日が読めなくても全体は欠かさず、その日だけ記録なしにする
        return dayStarts.filter { $0 <= today }.map { dayStart -> DayPoints in
            let isToday = dayStart == today
            let day = boundary.day(containing: dayStart)
            if !isToday, let cached = pastCache?.days[dayStart] { return cached }
            do {
                let (points, snapshot) = try dayPoints(day: day, isToday: isToday, now: now, events: events)
                if !isToday {
                    pastCache?.days[dayStart] = points
                    if points.points != nil { pastCache?.recordDays[dayStart] = snapshot.recordDay }
                }
                return points
            } catch {
                // 読めなかった日は覚えず、次に開いたときに読み直す
                return DayPoints(dayStart: dayStart, points: nil, lastWeek: nil, isToday: isToday, date: day.date)
            }
        }
    }

    private func dayPoints(day: BoundaryDay, isToday: Bool, now: Date, events: [BlockEvent]) throws -> (DayPoints, HomeSnapshot) {
        let snapshot = try daySnapshot(day: day, now: now, events: events)
        guard try isToday || hasRecord(day: day, snapshot: snapshot) else {
            return (DayPoints(dayStart: day.start, points: nil, lastWeek: nil, isToday: isToday, date: day.date), snapshot)
        }
        return (DayPoints(dayStart: day.start, points: snapshot.points,
                          lastWeek: snapshot.opponentPoints(.lastWeek, at: snapshot.now), isToday: isToday, date: day.date), snapshot)
    }

    /// その日に何か記録があるか：タイマーの記録・計画（下書き・確定・計画なし）・ブロックが効いていた時間のどれか。
    /// ない日は使い始める前などで、設定の睡眠の時刻だけで点が付いてしまうので数えない。
    /// 睡眠は開くたびに直近7日分を保存するので、使っていた印にはならない
    private func hasRecord(day: BoundaryDay, snapshot: HomeSnapshot) throws -> Bool {
        // ブロックが一度も効いていない日は開けた時間が nil（DTX-05 の「出さない日」と同じ判定）
        try !store.sessions(dayKey: day.key).isEmpty || store.plan(dayKey: day.key) != nil || snapshot.opened != nil
    }

    /// その日の始まりから（今日は今まで、過ぎた日はその日の区切りまで）の、ホームと同じ数字
    private func daySnapshot(day: BoundaryDay, now: Date, events: [BlockEvent]) throws -> HomeSnapshot {
        let until = min(now, day.end)
        let stored = try store.plan(dayKey: day.key)
        let sleep = try daySleep(day)
        let lastWeek = boundary.day(-7, from: day)
        return HomeSnapshot.make(
            now: until, calendar: calendar,
            todaySessions: try store.sessions(dayKey: day.key) + carriedOver(into: day),
            plan: stored?.status == .skipped ? nil : (stored?.draft ?? PlanDraft()),
            lastWeekSessions: try lastWeekSessions(of: day),
            noPlanGoalSeconds: stored?.draft.goalSeconds,
            detox: try detoxDay(day, until: until, events: events),
            lastWeekDetox: try detoxDay(lastWeek, until: .distantFuture, events: events),
            sleep: sleep.points.map(\.interval), sleepCaps: sleep.points.compactMap(\.extendedPart),
            awakeSleep: sleep.awake.map(\.interval), day: day, lastWeekDay: lastWeek,
            onPlan: try onPlanContext(day: day, today: stored))
    }

    // MARK: タイムライン

    /// タイムラインの1日分。`daysAgo` は今日を0として何日前か（未来は見られない、TML-02）。
    func timelineDay(daysAgo: Int) -> TimelineDay? {
        let now = clock.now()
        guard daysAgo >= 0 else { return nil }
        let boundary = self.boundary
        let day = boundary.day(-daysAgo, from: boundary.day(containing: now))
        var result: TimelineDay?
        perform(reportsError: false) {
            let stored = try store.plan(dayKey: day.key)
            // 開けた時間（TML-05）：今日は今まで、過ぎた日は1日分。数えられなくても、ほかの表示は続ける（開けた時間を出さないだけ）
            let until = min(now, day.end)
            let detox = try? detoxDay(day, until: until, events: (try? blockLog.all()) ?? [])
            result = TimelineDay(
                dayKey: day.key, dayStart: day.start, now: now, isToday: daysAgo == 0,
                // 計画しない日も、残した前の夜の予定は出す（PLN-11）
                planBlocks: stored?.draft.summaries ?? [],
                isNoPlanDay: stored == nil || stored?.status == .skipped,
                sessions: try store.sessions(dayKey: day.key),
                editableDayKeys: editableDayKeys(now: now),
                opened: detox?.opened(until: until), dayDate: day.date)
        }
        return result
    }

    /// 終了時刻を直せる日（今日と昨日、その日の区切りで分けた日）
    private func editableDayKeys(now: Date) -> Set<String> {
        let boundary = self.boundary
        let today = boundary.day(containing: now)
        return [today.key, boundary.day(-1, from: today).key]
    }

    /// 開始と終了で日付（暦の日）が変わるか。時刻の選択で日付も出すかを決める
    func crossesDate(from start: Date, to end: Date) -> Bool {
        !calendar.isDate(start, inSameDayAs: end)
    }

    /// 終わった記録の終了時刻を早める（TML-04）。保存する瞬間にも「今日・昨日の記録か」を確かめる。成功なら true
    @discardableResult
    func shortenEnd(_ session: FocusSession, to newEnd: Date) -> Bool {
        guard TimelineDay.canEdit(session, editableDayKeys: editableDayKeys(now: clock.now())) else {
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
    /// `endsAtBlockEnd` は計画外から切り替えたとき（TMR-11。終わりはブロックの終わり）
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

    /// その日と先週の同じ曜日の、計画どおりの点の材料。その日の計画は読み済みのものを渡す。
    /// 確定した計画は朝の計画の写しで決める。区切りの履歴より後の日は、下書き（区切りから朝に確定するまで）と
    /// 計画しない日に残した前の夜の分も、足した時刻で決める（PLN-11、2026-10-21 オーナー決定）
    private func onPlanContext(day: BoundaryDay, today stored: StoredPlan?) throws -> OnPlanContext {
        func confirmed(_ key: String, _ loaded: StoredPlan?? = nil) throws -> (plan: StoredPlan, morning: Set<UUID>)? {
            guard let plan = try loaded ?? store.plan(dayKey: key), plan.status == .confirmed || plan.status == .unknown else { return nil }
            return (plan, Set((try store.snapshot(dayKey: key) ?? []).map(\.blockId)))
        }
        let lastWeek = try confirmed(boundary.day(-7, from: day).key)
        var context = OnPlanContext(lastWeekPlan: lastWeek?.plan, lastWeekMorningBlockIds: lastWeek?.morning ?? [])
        if let today = try confirmed(day.key, .some(stored)) {
            context.morningBlockIds = today.morning
            context.addedAt = today.plan.addedAt
            context.confirmedAt = day.isLegacy ? nil : today.plan.confirmedAt
        } else if let stored, !day.isLegacy, stored.status == .draft || stored.status == .skipped {
            context.addedAt = stored.addedAt
            context.blocks = stored.draft.blocks
        }
        return context
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
    private func addHistory(to snapshot: inout HomeSnapshot) throws {
        let byDay = try focusByDay(today: snapshot.dayStart)
        snapshot.personalBest = DailyFocus.best(byDay, before: snapshot.dayStart)
        let lastWeekStart = boundary.sameDayLastWeek(snapshot.dayStart)
        snapshot.hasOlderHistory = byDay.keys.contains { $0 < lastWeekStart }
    }

    /// 日ごとの集中。保存したとき・日が変わったときだけ読み直す（毎分の読み直しで全件を読まない）。
    /// タイマーが動いている間は今の分が毎分変わるので、覚えない
    private func focusByDay(today: Date) throws -> [Date: Int] {
        if let cache = historyCache, cache.revision == store.revision, cache.today == today { return cache.byDay }
        let sessions = try store.allSessions()
        let byDay = DailyFocus.byDay(sessions.flatMap { $0.activeSegments(now: clock.now()) }, boundary: boundary)
        if sessions.allSatisfy({ !$0.isRunning }) { historyCache = (store.revision, today, byDay) }
        return byDay
    }

    /// 自己ベスト（ANA-06）：全期間・今月・今週の、一番多い1日のポイントと集中した時間。今日は入れない。
    /// 記録のある日がない期間は入らない。全期間は使い始めの日から全部。過ぎた日のポイントは覚えるので、重いのは最初に開いたときだけ
    func periodBests() -> [BestPeriod: PeriodBest] {
        let boundary = self.boundary
        let today = boundary.dayStart(containing: clock.now())
        let history = recordedDays(.all)
        guard !history.isEmpty else { return [:] }
        let byDay = (try? focusByDay(today: today)) ?? [:]
        var result: [BestPeriod: PeriodBest] = [:]
        for period in BestPeriod.allCases {
            // 今週（今月）に記録のある日がなければ先週（先月）の日で（2026-10-11）
            let range = BestPeriods.range(period, today: today, boundary: boundary, recordDays: history.map(\.dayStart))
            // 同じ値なら新しい日（集中した時間のベストと同じ決まり）
            guard let best = LapTargets.ranked(history.filter { range.contains($0.dayStart) }).first, let points = best.points else { continue }
            result[period] = PeriodBest(points: points, pointsDay: best.dayStart,
                                        focus: DailyFocus.best(byDay.filter { range.contains($0.key) }, before: range.end),
                                        isFallback: range.isFallback)
        }
        return result
    }

    /// 期間の記録のある日（今日は入れない。古い日が先）。全期間は使い始めの日から。
    /// 今週（今月）に記録のある日がなければ先週（先月）の日（2026-10-11、`BestPeriods.range`）
    private func recordedDays(_ period: BestPeriod, events: [BlockEvent]? = nil) -> [DayPoints] {
        let boundary = self.boundary
        let today = boundary.day(containing: clock.now())
        guard let first = oldestRecordDay(), first < today.start else { return [] }
        var dayStarts: [Date] = []
        var day = boundary.day(-1, from: today)
        while day.start >= first {
            dayStarts.append(day.start)
            day = boundary.day(-1, from: day)
        }
        let all = pointsHistory(dayStarts: dayStarts.reversed(), events: events).filter { $0.points != nil }
        guard period != .all else { return all }
        let range = BestPeriods.range(period, today: today.start, boundary: boundary, recordDays: all.map(\.dayStart))
        return all.filter { range.contains($0.dayStart) }
    }

    /// 期間の記録・理論ベスト・ベスト10（ANA-06・09・11）。期間・記録・日付・ブロックの記録・睡眠の設定が変わったときだけ作る
    private func periodRecords(_ period: BestPeriod) -> PeriodRecords {
        let calendar = self.calendar
        let today = boundary.day(containing: clock.now())
        let events = (try? blockLog.all()) ?? []
        refreshPastCache(today: today.start, events: events.count)
        if let cached = pastCache?.periods[period] { return cached }
        let days = recordedDays(period, events: events).compactMap { points -> (points: DayPoints, day: RecordDay)? in
            // 覚えた材料がなければ（読めなかった日など）読み直す
            guard let day = pastCache?.recordDays[points.dayStart] ?? daySnapshot(of: points.dayStart)?.recordDay else { return nil }
            return (points, day)
        }
        // 区間は今日と同じ時刻の区間（今日の一日の始まりから2時間ごと。同じ時刻でそろえる、Q46）
        let records = PeriodRecords(days: days, sleepSections: LapTargets.sleepSections(
            startMinutes: sleepSettings.start, endMinutes: sleepSettings.end, day: today, calendar: calendar),
            sections: LapSection.of(dayStart: today.start, dayEnd: today.end, origin: today.date))
        pastCache?.periods[period] = records
        return records
    }

    /// 今日と相手（ベストの日・平均・区間ベスト）の比べとラップ表（ANA-06・11）。相手は `period` の記録のある日から作る。
    /// 期間に記録のある日がなければ nil（切り替えも表も出さない）。★の区間ベストは相手が何でも入れる。
    /// 期間の材料は覚えておくので、相手を切り替えたときに作り直すのは今日とラップ表だけ
    func lapComparison(target: LapTarget, period: BestPeriod) -> BestComparison? {
        let records = periodRecords(period)
        guard let theirs = records.curve(target),
              let mine = daySnapshot(of: boundary.dayStart(containing: clock.now())) else { return nil }
        // 同じ時刻でそろえる（日の名前の日の 0:00 からの経過、GHO-02）
        return BestComparison(today: mine.points, theirsAtSameTime: theirs(mine.now.timeIntervalSince(mine.dayDate)),
                              rows: BestLaps.make(today: mine.myPoints(until:), todayStart: mine.dayStart, todayEnd: mine.dayEnd,
                                                  origin: mine.dayDate, now: mine.now,
                                                  theirs: theirs, records: records.records.map(\.value)),
                              days: records.days.count)
    }

    /// 理論ベスト（ANA-11）：期間の区間ベストをつないだ1日の合計（睡眠の区間は平均、1日の合計の倍率は数え直す）。
    /// 期間に記録のある日がなければ nil
    func theoreticalBest(period: BestPeriod) -> Double? {
        periodRecords(period).theoreticalBest
    }

    /// ベスト10（ANA-09）：期間の記録のある日を1日のポイントの多い順に最大10日。同じなら新しい日が上。今日は入れない
    func topDays(period: BestPeriod) -> [DayPoints] {
        periodRecords(period).topDays
    }

    /// 時間帯の地図（ANA-07）：直近4週の曜日×2時間の集中の平均
    func timeMap() -> TimeMap {
        let boundary = self.boundary
        let today = boundary.day(containing: clock.now())
        // 今日は入れないので、保存したとき・日が変わったときだけ数え直す
        if let cache = timeMapCache, cache.revision == store.revision, cache.today == today.start { return cache.map }
        let segments = ((try? store.allSessions()) ?? []).flatMap { $0.activeSegments(now: clock.now()) }
        let map = TimeMap.make(segments, today: today, boundary: boundary)
        timeMapCache = (store.revision, today.start, map)
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
        if let lap = snapshot.laps(opponent).last(where: { !$0.isCurrent && !$0.hasNoFocus }) {
            let key = "\(dayKey)|\(Int(lap.interval.start.timeIntervalSinceReferenceDate))"
            // 出すかどうかは集中で決め（両者が集中していない区間は出さない）、差はポイントで出す（2026-10-12）
            if !shown.contains(key) { return show(key, "\(Self.lapRange(lap)) のラップ \(RaceChartLayout.signedPoints(lap.pointsGap))") }
        }
        let half = "\(dayKey)|half"
        if snapshot.halfwayTime(opponent) != nil, !shown.contains(half) { show(half, "中間地点を通過") }
    }

    static func lapRange(_ lap: Lap) -> String {
        let style = Date.FormatStyle.dateTime.hour(.defaultDigits(amPM: .omitted)).minute(.twoDigits)
        return "\(lap.interval.start.formatted(style))–\(lap.interval.end.formatted(style))"
    }

    // MARK: 手動の記録（TMR-13・TML-06）

    /// 手動で記録できないときの理由。できるなら nil。`editing` は直している記録（自分とは比べない）。
    /// 記録を読めなければ nil（保存のときにもう一度確かめ、読めなければ「保存できませんでした」）
    func manualProblem(start: Date, end: Date, editing id: UUID? = nil) -> ManualRecord.Problem? {
        guard let context = try? manualContext() else { return nil }
        return ManualRecord.problem(start: start, end: end, excluding: id, context: context)
    }

    /// 手動で記録できる時刻の範囲：昨日の始まり（区切りの日の始まり）〜今（分に切り捨て）
    func manualRange() -> ClosedRange<Date> {
        let yesterday = yesterdayStart(now: clock.now())
        return yesterday...max(yesterday, ManualRecord.floorToMinute(clock.now()))
    }

    /// 「手動の記録を直す」で選べる時刻：昨日の始まり〜今（分に切り捨て）。前の分を足した記録の終わりは秒つきなので、
    /// それより前に切り捨てないよう、記録の終わりまでは選べるようにする
    func manualEditRange(for session: FocusSession) -> ClosedRange<Date> {
        let range = manualRange()
        return range.lowerBound...max(range.upperBound, session.endAt ?? range.upperBound)
    }

    /// タイムラインの「＋ 手動で記録」の初めの時刻。今日は今の30分前〜今、
    /// 昨日は昨日の一日の中の最後の記録の終わりから30分（区切りをまたぐ記録は今日の始まりで切る。
    /// 記録がなければ起きた時刻から30分）
    func manualInitial(daysAgo: Int) -> DateInterval {
        let now = ManualRecord.floorToMinute(clock.now())
        let length: TimeInterval = 30 * 60
        guard daysAgo == 1 else { return DateInterval(start: now.addingTimeInterval(-length), end: now) }
        let yesterday = yesterdayStart(now: now)
        let today = boundary.dayStart(containing: now)
        let lastEnd = (try? manualContext())?.sessions.filter { $0.startAt < today }.compactMap(\.endAt)
            .map { min($0, today) }.filter { $0 > yesterday }.max()
        let wake = (try? sleepLine(storedFor: boundary.day(containing: yesterday)))?.end
        let start = min(ManualRecord.ceilToMinute(max(lastEnd ?? wake ?? yesterday, yesterday)), now)
        return DateInterval(start: start, end: min(start.addingTimeInterval(length), now))
    }

    /// 計画のタブの「やった（手動で記録）」の初めの時刻：ブロックの時刻のうち記録のない一番長い部分。
    /// 出さないとき（終わっていない・ゲーム・SNS の時間・記録のない部分がない）は nil
    func manualStart(for block: PlanBlockDraft) -> DateInterval? {
        let now = clock.now()
        guard !block.isUnblock, block.end <= now, let context = try? manualContext() else { return nil }
        return ManualRecord.longestGap(in: DateInterval(start: block.start, end: block.end), sessions: context.sessions, now: now)
    }

    /// タイムラインから：計画外の手動の記録を足す
    @discardableResult
    func addManual(category: CategoryOption, project: ProjectOption?, start: Date, end: Date) -> ManualSaveResult {
        saveManual(ManualRecordRequest(category: category, project: project, planBlockId: nil, start: start, end: end,
                                       plannedEndAt: nil, timeZone: timeZone()))
    }

    /// 計画のタブから：ブロックの記録として足す（カテゴリ・ブロック名はブロックのもの）
    @discardableResult
    func addManual(for block: PlanBlockDraft, start: Date, end: Date) -> ManualSaveResult {
        guard !block.isUnblock else { return refuse(.gameTime) }
        return saveManual(ManualRecordRequest(category: block.category, project: block.project, planBlockId: block.id,
                                              start: start, end: end, plannedEndAt: block.end, timeZone: timeZone()))
    }

    /// タイマーの画面の「前の分を足す」：`start`〜タイマーを始めた時刻を手動の記録にし、タイマーの終わりを
    /// 「足した開始＋始めた時点のブロックの長さ」にする（手動の開始を始めた時刻とみなす、TMR-15 と同じ決まり）
    @discardableResult
    func addPreviousPart(from start: Date) -> ManualSaveResult {
        guard let session = running?.session, let blockId = session.planBlockId else {
            errorMessage = Self.saveErrorMessage
            return .failed
        }
        var block: PlanBlockDraft?
        perform(reportsError: false) { block = try store.plan(dayKey: session.dayKey)?.draft.blocks.first { $0.id == blockId } }
        guard let block, !block.isUnblock else {
            errorMessage = Self.saveErrorMessage
            return .failed
        }
        guard start >= block.start else { return refuse(.outOfRange) }
        let length = TimeInterval(session.plannedDurationSec ?? Int(block.end.timeIntervalSince(block.start)))
        let newEnd = start.addingTimeInterval(length)
        // 戻した終わりが今以下になるときは、タイマーの終わりを動かさず記録だけ足す（すぐ超過にしない。Claude 補足、Q47）
        return saveManual(ManualRecordRequest(category: session.category, project: session.project, planBlockId: blockId,
                                              start: start, end: session.startAt, plannedEndAt: block.end, timeZone: timeZone()),
                          adjusting: newEnd > clock.now() ? (session.id, newEnd) : nil)
    }

    /// タイムラインの「手動の記録を直す」：開始・終わりを変える（今日と昨日の記録だけ）
    @discardableResult
    func updateManual(_ session: FocusSession, start: Date, end: Date) -> ManualSaveResult {
        guard session.isDeclared else {
            errorMessage = Self.saveErrorMessage
            return .failed
        }
        guard TimelineDay.canEdit(session, editableDayKeys: editableDayKeys(now: clock.now())) else {
            errorMessage = Self.cannotEditMessage
            return .refused(.outOfRange)
        }
        var problem: ManualRecord.Problem?
        let saved = perform {
            problem = ManualRecord.problem(start: start, end: end, excluding: session.id, context: try manualContext())
            if problem == nil { try store.updateManual(id: session.id, start: start, end: end) }
        }
        if let problem { return refuse(problem) }
        reload()
        return saved ? .saved : .failed
    }

    /// 手動の記録を消す（実際に削除する）。今日と昨日の記録だけ。消せたら true
    @discardableResult
    func deleteManual(_ session: FocusSession) -> Bool {
        guard session.isDeclared else { return false }
        guard TimelineDay.canEdit(session, editableDayKeys: editableDayKeys(now: clock.now())) else {
            errorMessage = Self.cannotEditMessage
            return false
        }
        let deleted = perform { try store.deleteManual(id: session.id) }
        reload()
        return deleted
    }

    /// 保存の直前にもう一度確かめてから足す（画面を開いたまま4:00を過ぎた・その間に開けたなど）
    private func saveManual(_ request: ManualRecordRequest, adjusting: (id: UUID, end: Date)? = nil) -> ManualSaveResult {
        var problem: ManualRecord.Problem?
        let saved = perform {
            problem = ManualRecord.problem(start: request.start, end: request.end, context: try manualContext())
            if problem == nil { _ = try store.addManual(request, adjustingPlannedEnd: adjusting) }
        }
        if let problem { return refuse(problem) }
        reload()
        return saved ? .saved : .failed
    }

    private func refuse(_ problem: ManualRecord.Problem) -> ManualSaveResult {
        errorMessage = problem.message
        return .refused(problem)
    }

    /// 実行中のタイマーの「前の分を足す」で足せる区間（計画ブロックのタイマーで、ブロックの開始から5分以上たって始めたとき）
    private func addablePreviousPart(of session: FocusSession) throws -> DateInterval? {
        guard let blockId = session.planBlockId, !session.isDeclared,
              let stored = try store.plan(dayKey: session.dayKey), stored.status != .skipped,
              let block = stored.draft.blocks.first(where: { $0.id == blockId }) else { return nil }
        return ManualRecord.previousPart(blockStart: block.start, blockEnd: block.end, isGameTime: block.isUnblock,
                                         timerStart: session.startAt, context: try manualContext())
    }

    /// 手動の記録の判定の材料：一昨日〜今日の記録（区切りをまたいで昨日に入る記録も見る）、ブロックの記録、
    /// 予定のゲーム・SNS の時間、昨日・今日の朝の睡眠と今夜の睡眠（まだなければ設定の時刻、DTX-02）
    private func manualContext() throws -> ManualRecord.Context {
        let now = clock.now()
        let boundary = self.boundary
        let today = boundary.day(containing: now)
        var sessions: [FocusSession] = []
        var games: [DateInterval] = []
        for offset in -2...0 {
            let day = boundary.day(offset, from: today)
            sessions += try store.sessions(dayKey: day.key)
            games += gameWindows(try store.plan(dayKey: day.key), of: day)
        }
        let sleep = try (-1...1).map { try sleepLine(storedFor: boundary.day($0, from: today)).interval }
        // ブロックの記録が読めなければ、効いていたか分からないので記録できない（ブロックが効いていない）
        return ManualRecord.Context(now: now, dayKeys: editableDayKeys(now: now), calendar: calendar,
                                    events: (try? blockLog.all()) ?? [], gameWindows: games, sessions: sessions, sleep: sleep,
                                    boundary: boundary)
    }

    private func yesterdayStart(now: Date) -> Date {
        boundary.dayStart(-1, from: boundary.dayStart(containing: now))
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
        let dayKey = morningPlan?.dayKey ?? boundary.dayKey(containing: clock.now())
        if perform({ try store.skip(dayKey: dayKey, timeZone: timeZone(), goalSeconds: goalSeconds) }) {
            morningPlan = nil
        }
        reload()
    }

    /// 計画なし日にあとから計画を作る（2026-09-30 決定）。朝の計画画面を開き、閉じれば計画なしのまま。
    func openPlanOnNoPlanDay() {
        let today = boundary.day(containing: clock.now())
        // 計画なし日に決めた目標は、作る計画に引き継ぐ（GHO-10）。習慣のブロックが最初から入る（PLN-08）。
        // 計画しない日に残した前の夜の予定も入れる（PLN-11）
        var draft = newDraft(day: today)
        if let kept = try? store.plan(dayKey: today.key)?.draft.blocks {
            draft.blocks = kept + draft.blocks.filter { block in !kept.contains { $0.overlaps(block) || $0.matches(block) } }
        }
        draft.goalSeconds = noPlanGoalSeconds
        morningPlan = MorningPlan(day: today, draft: draft, gridStart: morningGridStart(day: today))
    }

    /// 日中の計画の変更（PLN-04）。朝のスナップショットは変わらない。
    @discardableResult
    /// 区切りから朝の計画を確定するまでは下書きを直す（すぐ保存、PLN-11・Q47）
    func savePlanChanges(_ draft: PlanDraft) -> Bool {
        let dayKey = boundary.dayKey(containing: clock.now())
        let saved = perform {
            if try store.plan(dayKey: dayKey)?.status == .draft {
                try store.saveDraft(draft, dayKey: dayKey, timeZone: timeZone())
            } else {
                try store.saveChanges(draft, dayKey: dayKey)
            }
        }
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
        let boundary = self.boundary
        let day = boundary.day(containing: dayStart)
        var result: [PlanCandidate] = []
        perform(reportsError: false) {
            var sources: [PlanCandidates.SourcePlan] = []
            for (source, offset) in [(PlanCandidate.Source.yesterday, -1), (.lastWeek, -7)] {
                let other = boundary.day(offset, from: day)
                guard let stored = try store.plan(dayKey: other.key),
                      stored.status == .confirmed || stored.status == .unknown else { continue }
                sources.append(.init(source: source, plan: stored.draft, dayStart: other.date))
            }
            result = PlanCandidates.make(plan: plan, dayStart: day.start, dayEnd: day.end, dayDate: day.date, calendar: calendar,
                                         sources: sources, templates: templates,
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
                let today = boundary.day(containing: clock.now())
                // 読めなければ覚えず、次の起動でやり直す
                perform(reportsError: false) {
                    let carried = try carriedDraft(today: today)
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
