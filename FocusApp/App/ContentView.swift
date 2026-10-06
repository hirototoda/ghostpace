import SwiftUI

struct ContentView: View {
    let launcher: AppLauncher

    var body: some View {
        Group {
            switch launcher.state {
            case .ready(let model):
                #if DEBUG
                if launcher.options.liveGallery {
                    LiveActivityGallery()
                } else if launcher.options.widgetGallery {
                    WidgetGallery(model: model)
                } else if launcher.options.openAddCategory {
                    AddCategorySheet(startsDetox: true, focusesName: false) { _, _, _ in false }
                } else {
                    MainView(model: model, options: launcher.options)
                }
                #else
                MainView(model: model, options: launcher.options)
                #endif
            case .failed(let message):
                StoreErrorView(message: message) { launcher.launch() }
            }
        }
        .tint(Theme.focus)
        #if DEBUG
        .environment(\.raceStartsFlipped, launcher.options.raceStartsFlipped)
        .environment(\.raceStartsWholeDay, launcher.options.raceStartsWholeDay)
        .environment(\.raceStartsReplay, launcher.options.raceStartsReplay)
        .environment(\.opensStartSheet, launcher.options.openStartSheet)
        .overlay(alignment: .top) {
            if launcher.options.demoScene != nil || launcher.options.liveGallery {
                DemoMenu(launcher: launcher)
            }
        }
        #endif
    }
}

/// 下のタブ（NAV-01、2026-10-01 決定。2026-10-05 にタイムラインを分析に置き換え）。
private enum MainTab: Hashable {
    case timer
    case plan
    case analysis
}

/// 下のタブ（タイマー・計画・分析）と、その上に出る朝の計画・タイマー・設定・振り返り。
private struct MainView: View {
    @Bindable var model: AppModel
    @State private var tab: MainTab
    /// 分析のタブで進んだ先（タイムライン・ポイントの推移・その日のグラフ）
    @State private var analysisPath: [AnalysisRoute]
    @State private var showsSettings: Bool
    /// 夜の振り返りから開いた明日の計画
    @State private var tomorrow: MorningPlan?
    /// 通知の説明を実際に出しているか（朝の計画の全画面が閉じ終わってから出す）
    @State private var presentsIntro = false
    /// 見本の撮影用に、長押しの画面を押している途中の見た目で始める（`-holdProgress`）
    @State private var holdProgress: Double
    /// 最初の説明の「続ける」のあとの選択画面（BLK-01）
    @State private var showsIntroPicker = false
    @Environment(\.scenePhase) private var scenePhase

    init(model: AppModel, options: LaunchOptions) {
        self.model = model
        let opensAnalysis = options.openAnalysis || options.openTimeline || options.openPoints
        _tab = State(initialValue: opensAnalysis ? .analysis : options.openPlan ? .plan : .timer)
        _analysisPath = State(initialValue: options.openTimeline ? [.timeline]
                              : options.openPoints ? [.points] + (options.openDay.map { days in
                                  let today = DayBoundary.dayStart(containing: model.clock.now(), calendar: model.calendar)
                                  return [.day(model.calendar.date(byAdding: .day, value: -days, to: today) ?? today)]
                              } ?? []) : [])
        _showsSettings = State(initialValue: options.openSettings)
        if options.openReview { model.showsReview = true }
        _holdProgress = State(initialValue: options.holdProgress)
        #if DEBUG
        if options.openHold {
            if options.openHoldUnlocked { model.unlock(minutes: BlockPolicy.defaultUnlockMinutes) }
            model.openHold()
        }
        #endif
    }

    var body: some View {
        tabs
            .habitIntroCover(model: model)
            // 長押しの画面は、いちばん上に出ている画面から出す（設定・タイマーの上ではそれぞれの中から）
            .holdUnlockCover(model: model, initialProgress: holdProgress,
                             when: model.running == nil && model.morningPlan == nil && !showsSettings && !model.showsReview)
            .background {
                Color.clear.sheet(isPresented: Binding(get: { presentsBlockingIntro },
                                                       set: { if !$0 { model.postponeBlocking() } })) {
                    BlockingIntroSheet {
                        Task {
                            let result = await model.requestBlockingAuthorization()
                            guard result == .approved else { return }
                            // 説明のシートが閉じてから選択画面を出す
                            try? await Task.sleep(for: .milliseconds(500))
                            showsIntroPicker = true
                        }
                    } onLater: {
                        model.postponeBlocking()
                    }
                }
            }
            .background {
                Color.clear.sheet(isPresented: $showsIntroPicker) { BlockSelectionSheet(model: model, requiresHold: false) }
            }
    }

    /// 朝の計画・計画のタブの睡眠の行（DTX-02）
    private func sleepRow(dayStart: Date) -> SleepRowModel? {
        model.sleepLine(dayStart: dayStart).map { line in
            SleepRowModel(line: line, needsHealth: model.healthNeedsRequest,
                          onEdit: { model.setSleepManually(start: $0, end: $1) },
                          onRequestHealth: { Task { await model.requestHealthAccess() } },
                          onReread: model.canRereadHealth ? { await model.rereadSleepFromHealth() != .noRecord } : nil)
        }
    }

    /// ブロックの説明は、ほかの画面（朝の計画・タイマー・通知の説明・設定・振り返り・長押し）が出ていないときだけ
    private var presentsBlockingIntro: Bool {
        model.showsBlockingIntro && canPresentOverHome && !showsSettings && !model.showsReview
            && !model.showsNotificationIntro && model.holdRequest == nil
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            Tab("タイマー", systemImage: "timer", value: MainTab.timer) { home }
                .accessibilityIdentifier("timerTab")
            Tab("計画", systemImage: "list.bullet.clipboard", value: MainTab.plan) { planTab }
                .accessibilityIdentifier("planTab")
            Tab("分析", systemImage: "chart.line.uptrend.xyaxis", value: MainTab.analysis) {
                AnalysisScreen(model: model, path: $analysisPath)
            }
            .accessibilityIdentifier("analysisTab")
        }
        .overlay(alignment: .top) { noticeBanner }
        // ラップ・中間地点の帯は軽く振動させる（GHO-06）。タイマー中は前のタイマーの画面が鳴らす
        .sensoryFeedback(trigger: model.raceNoticeCount) { _, _ in model.running == nil ? .impact(weight: .light) : nil }
        // 計画・分析のタブは、それぞれの画面が自分で知らせを出す
        .saveErrorAlert($model.errorMessage, when: tab == .timer && isHomeTopmost)
        .fullScreenCover(item: Binding(get: { model.morningPlan }, set: { _ in })) { morning in
            DailyPlanView(mode: .morning, dayStart: morning.dayStart, now: model.clock.now(), plan: morning.draft,
                          categories: model.categories, projects: model.projects,
                          onCreateProject: { model.createProject(name: $0, category: $1) },
                          onCreateCategory: { model.createCategory(name: $0, countsAsFocus: $1, detoxGroup: $2) },
                          onChange: { model.saveDraft($0) },
                          onConfirm: { model.confirmPlan($0) },
                          onDismiss: { model.skipPlan(goalSeconds: $0) },
                          errorMessage: $model.errorMessage,
                          showsGoal: true, templates: model.templates, calendar: model.calendar,
                          onSaveAsTemplate: { model.saveAsTemplate(name: $0, plan: $1) },
                          sleep: sleepRow(dayStart: morning.dayStart),
                          habitDraft: model.habits.draft(dayStart: morning.dayStart, calendar: model.calendar),
                          candidates: { model.candidates(for: $0, dayStart: morning.dayStart, excludingEnded: false) },
                          awake: model.awakeRange(dayStart: morning.dayStart))
        }
        .background {
            // シートは1つの View に1つまで。設定・振り返り・通知の説明は別の階層から出す
            Color.clear.sheet(isPresented: $showsSettings) { SettingsView(model: model) }
        }
        .background {
            // 振り返りは、ほかの画面（設定・朝の計画・タイマー・通知の説明）が閉じてから出す
            Color.clear.sheet(isPresented: Binding(get: { model.showsReview && canPresentOverHome && !showsSettings },
                                                   set: { if !$0 { model.showsReview = false } })) { reviewSheet }
        }
        .background {
            Color.clear.sheet(isPresented: Binding(get: { presentsIntro }, set: { if !$0 { model.postponeNotifications() } })) {
                NotificationIntroSheet(reviewMinutes: model.reviewMinutes) {
                    Task { await model.enableNotifications() }
                } onLater: {
                    model.postponeNotifications()
                }
            }
        }
        .background {
            // 実行中のタイマーは、朝の計画とは別の階層から出す（全画面の表示は1つの View に1つまで）
            Color.clear.fullScreenCover(item: Binding(get: { model.running }, set: { _ in })) { timer in
                TimerRunningView(timer: timer, opponent: model.opponent, onPause: model.pause, onResume: model.resume,
                                 onEnd: model.requestEnd, onSwitch: model.switchToBlock,
                                 ambient: AmbientControl(sound: model.ambientSound, volume: model.ambientVolume,
                                                         onSelect: { model.setAmbientSound($0) },
                                                         onVolume: { model.setAmbientVolume($0) }))
                    .sheet(item: $model.endTimeCheck) { check in
                        EndTimeSheet(check: check) { model.end(reportedEnd: $0) }
                            .saveErrorAlert($model.errorMessage)
                    }
                    .saveErrorAlert($model.errorMessage, when: model.endTimeCheck == nil)
                    .holdUnlockCover(model: model, when: model.endTimeCheck == nil)
                    // 計画どおりの点（GHO-16）はタイマーの画面にも出す
                    .overlay(alignment: .top) { noticeBanner }
                    .sensoryFeedback(.impact(weight: .light), trigger: model.raceNoticeCount)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.reload(quietly: true)
                model.refreshBlockingAuthorization()
                model.checkUnlockRequest()
                Task {
                    await model.refreshNotificationStatus()
                    await model.refreshSleep()
                }
            }
        }
        .onChange(of: model.showsNotificationIntro) { _, wants in
            guard wants else { presentsIntro = false; return }
            // 朝の計画の全画面が閉じるのを待ってから出す（同時に出すと表示が落ちることがある）
            Task {
                try? await Task.sleep(for: .milliseconds(700))
                presentsIntro = model.showsNotificationIntro && canPresentOverHome
            }
        }
        .task {
            await model.refreshNotificationStatus()
            await model.refreshSleep()
        }
        .task {
            // ホーム表示中は1分ごとに「今」と数字を進める
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                model.reload(quietly: true)
                // 開いたまま朝4:00をまたいだ日も、ヘルスケアに入っていれば置き換える（DTX-02）
                await model.refreshSleep(onlyIfSetting: true)
            }
        }
    }

    private var isHomeTopmost: Bool {
        canPresentOverHome && !showsSettings && !model.showsReview && !presentsIntro && model.holdRequest == nil
    }

    /// 全画面（朝の計画・タイマー）と通知の説明が出ていない
    private var canPresentOverHome: Bool {
        model.running == nil && model.morningPlan == nil && !presentsIntro
    }

    private var home: some View {
        HomeView(snapshot: model.snapshot, categories: model.categories,
                 onTapPlan: {
                     // 計画なし日は、あとから計画を作る画面を開く。計画があれば計画のタブへ
                     if model.plan == nil { model.openPlanOnNoPlanDay() } else { tab = .plan }
                 },
                 onStartBlock: { model.startPlanned(block: $0) },
                 onStartUnplanned: { model.startUnplanned(category: $0, project: $1, minutes: $2) },
                 onOpenSettings: { showsSettings = true },
                 onOpenReview: { model.showsReview = true },
                 opponent: Binding(get: { model.opponent }, set: { model.selectOpponent($0) }),
                 onCreateCategory: { model.createCategory(name: $0, countsAsFocus: $1, detoxGroup: $2) },
                 projects: model.projects,
                 onCreateProject: { model.createProject(name: $0, category: $1) },
                 lateStart: { model.lateStart(for: $0) },
                 onStartFromBlockStart: { model.startPlanned(block: $0, fromBlockStart: true) })
    }

    @ViewBuilder
    private var planTab: some View {
        if let plan = model.plan {
            DailyPlanView(mode: .tab, dayStart: model.snapshot.dayStart, now: model.snapshot.now, plan: plan,
                          categories: model.categories, projects: model.projects,
                          onCreateProject: { model.createProject(name: $0, category: $1) },
                          onCreateCategory: { model.createCategory(name: $0, countsAsFocus: $1, detoxGroup: $2) },
                          onChange: { model.savePlanChanges($0) },
                          errorMessage: $model.errorMessage, storedPlan: plan,
                          showsGoal: true, templates: model.templates, calendar: model.calendar,
                          onSaveAsTemplate: { model.saveAsTemplate(name: $0, plan: $1) },
                          templateEditor: { AnyView(TemplateEditView(model: model, template: $0)) },
                          sleep: sleepRow(dayStart: model.snapshot.dayStart),
                          habitDraft: model.habits.draft(dayStart: model.snapshot.dayStart, calendar: model.calendar),
                          candidates: { model.candidates(for: $0, dayStart: model.snapshot.dayStart, excludingEnded: true) },
                          habits: model.habits, habitsEditor: { AnyView(HabitsView(model: model)) },
                          awake: model.awakeRange(dayStart: model.snapshot.dayStart),
                          declarationProblem: { model.declarationProblem(for: $0, end: $1) },
                          onDeclare: { model.declare($0, end: $1) },
                          canStartLate: { model.canStartLate($0) },
                          onStartLate: { model.startLate($0) })
                .id(model.snapshot.dayStart)
        } else {
            NoPlanTab(model: model)
        }
    }

    @ViewBuilder
    private var reviewSheet: some View {
        if let content = model.reviewContent() {
            ReviewView(content: content) { tomorrow = model.tomorrowPlan() }
                .sheet(item: $tomorrow) { plan in
                    DailyPlanView(mode: .tomorrow, dayStart: plan.dayStart, now: model.clock.now(), plan: plan.draft,
                                  categories: model.categories, projects: model.projects,
                                  onCreateProject: { model.createProject(name: $0, category: $1) },
                                  onCreateCategory: { model.createCategory(name: $0, countsAsFocus: $1, detoxGroup: $2) },
                                  onChange: { model.saveTomorrowDraft($0, for: plan) },
                                  onConfirm: { if model.saveTomorrowDraft($0, for: plan) { tomorrow = nil } },
                                  onDismiss: { _ in tomorrow = nil },
                                  errorMessage: $model.errorMessage,
                                  // 明日の最初のブロックは 8:00 から（review.md）
                                  firstStart: model.calendar.date(byAdding: .hour, value: 8 - DayBoundary.hour, to: plan.dayStart),
                                  showsGoal: true, templates: model.templates, calendar: model.calendar,
                                  onSaveAsTemplate: { model.saveAsTemplate(name: $0, plan: $1) },
                                  habitDraft: model.habits.draft(dayStart: plan.dayStart, calendar: model.calendar),
                                  candidates: { model.candidates(for: $0, dayStart: plan.dayStart, excludingEnded: false) },
                                  awake: model.awakeRange(dayStart: plan.dayStart))
                }
        } else {
            ContentUnavailableView("記録を読めませんでした", systemImage: "exclamationmark.triangle")
        }
    }

    @ViewBuilder
    private var noticeBanner: some View {
        if let notice = model.notice {
            Text(notice)
                .font(.subheadline.bold())
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Capsule().fill(.regularMaterial))
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .padding(.top, 44)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityIdentifier("notice")
                .task(id: notice) {
                    try? await Task.sleep(for: .seconds(2))
                    model.notice = nil
                }
        }
    }
}

/// 計画なし日の計画のタブ。あとから計画を作れる。目標時間だけ決めることもできる（GHO-10、Q13）。
private struct NoPlanTab: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "list.bullet.clipboard").font(.largeTitle).foregroundStyle(.secondary)
                        Text("今日は計画なし").font(.headline)
                        Text("今から計画を作ると、今日の朝の計画として残ります。")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("計画を作る") { model.openPlanOnNoPlanDay() }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("makePlanButton")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                Section {
                    GoalStepper(seconds: model.noPlanGoalSeconds ?? 0, minimum: 0) { model.setNoPlanGoal($0) }
                } header: {
                    Text("今日の目標")
                } footer: {
                    Text("目標と対戦できます。計画なしの日は 8:00〜20:00 に同じ速さで進みます。")
                }
                Section {
                    NavigationLink {
                        HabitsView(model: model)
                    } label: {
                        HabitsRow(habits: model.habits)
                    }
                    .accessibilityIdentifier("habitsRow")
                }
                if !model.templates.isEmpty {
                    Section("テンプレート") {
                        ForEach(model.templates) { template in
                            NavigationLink {
                                TemplateEditView(model: model, template: template)
                            } label: {
                                TemplateRow(template: template)
                            }
                        }
                    }
                }
            }
            .navigationTitle("計画")
            .navigationBarTitleDisplayMode(.inline)
            .saveErrorAlert($model.errorMessage)
        }
    }
}

/// 長押しの画面（BLK-08）を全画面で出す。`when` が false のあいだは出さない（上に別の画面が出ているとき）。
private struct HoldUnlockCover: ViewModifier {
    @Bindable var model: AppModel
    var initialProgress: Double
    var when: Bool

    func body(content: Content) -> some View {
        content.background {
            Color.clear.fullScreenCover(item: Binding(get: { when ? model.holdRequest : nil },
                                                      set: { if $0 == nil { model.closeHold() } })) { _ in
                HoldUnlockView(snapshot: model.snapshot, opponent: model.opponent, unlockedUntil: model.unlockedUntil,
                               onUnlock: { model.unlock(minutes: $0) },
                               onReblock: { model.reblockNow(); model.closeHold() },
                               onClose: { model.closeHold() },
                               onExpire: { model.reload(quietly: true); model.closeHold() },
                               initialProgress: initialProgress, unblockedUntil: model.unblockedUntil)
                    // 開けなかった理由（選択を読めない等）は、この画面の上に出す
                    .saveErrorAlert($model.errorMessage)
            }
        }
    }
}

/// 初めて使う端末の習慣の画面（PLN-08）を全画面で出す。決めると朝の計画が出る
private struct HabitIntroCover: ViewModifier {
    @Bindable var model: AppModel

    func body(content: Content) -> some View {
        content.background {
            Color.clear.fullScreenCover(isPresented: Binding(get: { model.showsHabitIntro && model.running == nil }, set: { _ in })) {
                NavigationStack { HabitsView(model: model, isIntro: true) }
                    .tint(Theme.focus)
                    .interactiveDismissDisabled()
            }
        }
    }
}

extension View {
    func habitIntroCover(model: AppModel) -> some View {
        modifier(HabitIntroCover(model: model))
    }

    func holdUnlockCover(model: AppModel, initialProgress: Double = 0, when: Bool) -> some View {
        modifier(HoldUnlockCover(model: model, initialProgress: initialProgress, when: when))
    }
}

/// 記録を開けなかったときの画面。ファイルは消さない（NFR-02）。
struct StoreErrorView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        ScrollView {
            content.padding(24).frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.center)
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
    }

    private var content: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("記録を開けませんでした").font(.title2.bold())
            Text("記録は消していません。").font(.headline)
            Text(message)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            Button(action: onRetry) {
                Text("もう一度試す").fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("retryOpenStoreButton")
        }
        .multilineTextAlignment(.center)
    }
}

#if DEBUG
/// 見本の場面を切り替えるメニュー（`-seedDemoData` で起動したときだけ出る）。
private struct DemoMenu: View {
    let launcher: AppLauncher

    var body: some View {
        Menu {
            ForEach(DemoScene.allCases, id: \.self) { scene in
                Button(scene.label) { launcher.switchDemo(to: scene) }
            }
            Button("ロック画面と画面上部") { launcher.showLiveGallery() }
        } label: {
            Text("見本 ▾")
                .font(.caption.bold())
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(.orange.opacity(0.2)))
                .foregroundStyle(.orange)
        }
        .padding(.top, 8)
        .dynamicTypeSize(...DynamicTypeSize.large)
        .accessibilityIdentifier("sceneSwitcher")
    }
}
#endif
