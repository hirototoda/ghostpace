import SwiftData
import SwiftUI
import UserNotifications

@main
struct FocusApp: App {
    @State private var launcher: AppLauncher
    private let notificationDelegate: NotificationDelegate

    init() {
        #if DEBUG
        let options = LaunchOptions.parse(ProcessInfo.processInfo.arguments)
        #else
        let options = LaunchOptions()
        #endif
        let launcher = AppLauncher(options: options, clock: options.makeClock())
        _launcher = State(initialValue: launcher)
        // 振り返りの通知を押したら振り返りを開く。アプリを開いているあいだも通知を出す
        notificationDelegate = NotificationDelegate(launcher: launcher)
        UNUserNotificationCenter.current().delegate = notificationDelegate
    }

    var body: some Scene {
        WindowGroup {
            ContentView(launcher: launcher)
                .environment(\.clock, launcher.clock)
        }
    }
}

/// 保存先を開いて AppModel を作る。開けなければ、ファイルを消さずにエラーを出す（NFR-02）。
@MainActor
@Observable
final class AppLauncher {
    enum State {
        case ready(AppModel)
        case failed(String)
    }

    private(set) var state: State = .failed("")
    private(set) var options: LaunchOptions
    let clock: any AppClock
    /// ストアのコンテナ。ModelContext は弱参照なので、ここで持ち続ける
    private var container: ModelContainer?

    init(options: LaunchOptions, clock: any AppClock) {
        self.options = options
        self.clock = clock
        for url in Self.filesToReset(options) {
            try? FileManager.default.removeItem(at: url)
        }
        launch()
    }

    /// 端末の設定と通知。見本データ・メモリ内・UI テスト（`-storeName`）では本物の設定と通知に触れない。
    static func settingsAndNotifications(_ options: LaunchOptions) -> (any AppSettings, any NotificationScheduling) {
        if options.storeURL == nil {
            let settings = MemorySettings()
            if let opponent = options.opponent { settings.opponent = opponent }
            return (settings, NoNotifications())
        }
        if let storeName = options.storeName {
            let suite = "focusapp-test-\(storeName)"
            if options.resetStore { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
            return (UserDefaultsSettings(defaults: UserDefaults(suiteName: suite) ?? .standard), NoNotifications())
        }
        return (UserDefaultsSettings(defaults: .standard), UserNotificationScheduler(calendar: { .app(timeZone: .current) }))
    }

    /// 睡眠（DTX-02）。見本データ・メモリ内・UI テストではヘルスケアに触れず、ゆうべ 0:10〜7:05 寝た記録を返す
    /// （本物の保存先では使わない。ライブアクティビティの見本と同じ分け方）
    static func sleepSource(_ options: LaunchOptions, clock: any AppClock) -> any SleepSource {
        guard options.storeURL == nil || options.storeName != nil else { return HealthKitSleepSource() }
        guard !options.noHealthSleep else { return NoSleepSource(isAvailable: true) }
        let midnight = Calendar.app(timeZone: .current).startOfDay(for: clock.now())
        return NoSleepSource(isAvailable: true, intervals: [
            DateInterval(start: midnight.addingTimeInterval(10 * 60), end: midnight.addingTimeInterval(7 * 3600 + 5 * 60)),
        ])
    }

    /// アプリのブロック。見本データ・メモリ内・UI テストでは iPhone の Screen Time に触れず、始めた状態のメモリ内で動かす。
    static func blockingDependencies(_ options: LaunchOptions, clock: (any AppClock)? = nil)
        -> (any BlockingControlling, any BlockStoring, any BlockEventLogging) {
        if options.storeURL == nil || options.storeName != nil {
            let store = MemoryBlockStore()
            store.state = BlockState(isEnabled: true)
            store.selection = Data("demo".utf8)
            // ずっと前からブロックを始めていたことにする（デトックスの時間を見本でも出す、DTX-01）。
            // 見本データでは開けた記録も入れる（DTX-05）
            let log = MemoryBlockEventLog()
            if let scene = options.demoScene, let clock {
                for event in DemoData.blockEvents(scene, now: clock.now(), calendar: .app(timeZone: .current)) { try? log.append(event) }
            } else {
                try? log.append(BlockEvent(occurredAt: Date(timeIntervalSinceReferenceDate: 0), timeZoneId: TimeZone.current.identifier,
                                           kind: .started))
            }
            return (NoBlocking(isAvailable: true), store, log)
        }
        guard let defaults = BlockShared.defaults, let url = BlockShared.eventLogURL else {
            return (NoBlocking(), MemoryBlockStore(), MemoryBlockEventLog())
        }
        return (ScreenTimeBlocking(), UserDefaultsBlockStore(defaults: defaults), FileBlockEventLog(url: url))
    }

    /// ロック画面と画面上部のタイマー（TMR-06）。見本データ・メモリ内・UI テストでは出さない（`-liveActivity` を付けたときだけ出す）。
    static func liveActivity(_ options: LaunchOptions, clock: any AppClock) -> any LiveActivityControlling {
        let isReal = options.storeURL != nil && options.storeName == nil
        return isReal || options.liveActivity ? ActivityKitLiveActivity(clock: clock) : NoLiveActivity()
    }

    /// `-resetStore` で消すファイル。`-storeName` を付けたときだけ（通常の記録は決して消さない、NFR-02）。
    static func filesToReset(_ options: LaunchOptions) -> [URL] {
        guard options.resetStore, options.storeName != nil, let url = options.storeURL else { return [] }
        return ["", "-shm", "-wal"].map { URL(filePath: url.path(percentEncoded: false) + $0) }
    }

    func launch() {
        do {
            if options.failStoreOpen { throw LaunchError.forcedFailure }
            let url = options.storeURL
            if let directory = url?.deletingLastPathComponent() {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let container = try AppStore.makeContainer(url: url)
            let store = SwiftDataStore(container: container, clock: clock)
            if let scene = options.demoScene {
                try DemoData.seed(scene, into: store, calendar: .app(timeZone: .current), goalMinutes: options.demoGoalMinutes)
            }
            // デモデータを入れた後から失敗させる
            if options.failSave {
                store.saveHook = { throw LaunchError.forcedFailure }
            }
            self.container = container
            let (settings, notifications) = Self.settingsAndNotifications(options)
            let (blocking, blockStore, blockLog) = Self.blockingDependencies(options, clock: clock)
            let model = AppModel(store: store, clock: clock, settings: settings, notifications: notifications,
                                 blocking: blocking, blockStore: blockStore, blockLog: blockLog,
                                 liveActivity: Self.liveActivity(options, clock: clock),
                                 sleepSource: Self.sleepSource(options, clock: clock))
            state = .ready(model)
        } catch {
            container = nil
            state = .failed(String(describing: error))
        }
    }

    #if DEBUG
    /// 見本の場面を切り替える（メモリ内のストアを作り直す）。
    func switchDemo(to scene: DemoScene) {
        options.demoScene = scene
        options.failSave = false
        options.liveGallery = false
        launch()
    }

    /// ロック画面と画面上部の見本を出す。
    func showLiveGallery() {
        options.liveGallery = true
    }
    #endif

    enum LaunchError: Error, CustomStringConvertible {
        case forcedFailure
        var description: String { "検証用に失敗させました（-failStoreOpen / -failSave）" }
    }
}

/// 通知を押したとき・アプリを開いているときの扱い（REV-02）。
@MainActor
/// 通知を押したときの処理はメインスレッドで行い、iPhone への返事（completionHandler）もメインスレッドで返す。
/// async 版のメソッドだと返事が別のスレッドから返り、iPhone がアプリを止めていた（2026-10-01 実機で発生）。
final class NotificationDelegate: NSObject, @preconcurrency UNUserNotificationCenterDelegate {
    private weak var launcher: AppLauncher?

    init(launcher: AppLauncher) {
        self.launcher = launcher
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let kind = response.notification.request.content.userInfo["kind"] as? String
        if kind == BlockShared.holdNotificationKind {
            openHold()
        } else if kind == AppNotification.reviewID {
            openReview()
        }
        completionHandler()
    }

    /// シールドの「開く」の通知を押したら長押しの画面を開く（BLK-08）。タイマーの実行中も開く
    private func openHold() {
        guard case .ready(let model) = launcher?.state else { return }
        model.checkUnlockRequest()
        if model.holdRequest == nil, model.blockState.isEnabled { model.openHold() }
    }

    /// タイマーの実行中は開かない（全画面のタイマーの上には出せないため）
    private func openReview() {
        if case .ready(let model) = launcher?.state, model.running == nil { model.showsReview = true }
    }
}
