import XCTest

/// 報告用のスクリーンショットを撮る（docs/plan/recording-spec.md「シミュレーターで確かめて撮るもの」）。
/// 普段のテストでは動かさない。環境変数 SCREEN_TOUR=1 を付けたときだけ動く（`scripts/test.sh tour ScreenTourUITests/<テスト名>` で渡す）。
/// 撮った画像はテスト結果（xcresult）の添付として残る。
@MainActor
final class ScreenTourUITests: XCTestCase {
    private let timeout: TimeInterval = 10

    override func setUp() async throws {
        continueAfterFailure = false
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SCREEN_TOUR"] == "1", "SCREEN_TOUR=1 のときだけ撮る")
    }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        return app
    }

    private func demo(_ scene: String, _ time: String, _ extra: [String] = []) -> XCUIApplication {
        launch(["-seedDemoData", scene, "-fixedNow", "\(time)+09:00"] + extra)
    }

    private func shoot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// 習慣と候補（PLN-08・09）：朝の計画の候補、確定したあとの計画のタブの習慣の行と習慣の画面、初めて使う端末の最初の案内
    func testHabitsAndCandidates() {
        let app = demo("habits", "2026-10-19T07:00:00")
        let confirm = app.buttons["confirmPlanButton"]
        XCTAssertTrue(confirm.waitForExistence(timeout: timeout))
        shoot("morning-grid")
        // 候補が見えるまで送る（後ろのタブの画面ではなく、いちばん上の画面を送る）
        let candidate = app.buttons.matching(identifier: "candidate").firstMatch
        for _ in 0..<20 where !(candidate.exists && candidate.frame.minY < confirm.frame.minY - 200) { app.swipeUp(velocity: .slow) }
        Thread.sleep(forTimeInterval: 1)
        shoot("morning-candidates")
        app.buttons["confirmPlanButton"].tap()
        // 初めて確定したあとの通知の説明を閉じる
        let later = app.buttons["あとで"]
        if later.waitForExistence(timeout: 3) { later.tap() }
        app.tabBars.buttons["計画"].tap()
        let row = app.descendants(matching: .any)["habitsRow"].firstMatch
        for _ in 0..<20 where !(row.exists && row.isHittable) { app.swipeUp() }
        Thread.sleep(forTimeInterval: 1)
        shoot("plan-tab-habits-row")
        row.tap()
        XCTAssertTrue(app.navigationBars["習慣"].waitForExistence(timeout: timeout))
        shoot("habits-edit")
        app.terminate()
        let intro = launch(["-inMemoryStore", "-habitIntro", "-fixedNow", "2026-10-19T07:00:00+09:00"])
        XCTAssertTrue(intro.buttons["skipHabitsButton"].waitForExistence(timeout: timeout))
        shoot("habit-intro")
    }

    /// 計画どおりの点（GHO-16）の帯と、今のブロックの最中の前倒し（TMR-15）
    func testOnPlanPoints() {
        var app = demo("day", "2026-10-19T11:40:00")
        XCTAssertTrue(app.buttons["startEarlyButton"].waitForExistence(timeout: timeout))
        Thread.sleep(forTimeInterval: 1)
        shoot("home-current-and-next")
        app.terminate()
        // さっき・今・次の3行
        app = demo("missed", "2026-10-19T11:15:00")
        XCTAssertTrue(app.buttons["startMissedButton"].waitForExistence(timeout: timeout))
        Thread.sleep(forTimeInterval: 1)
        shoot("home-three-lines")
    }

    /// 見せ方・ウィジェット・環境音（GHO-06・15、ANA-06・07、WID-01、TMR-14）
    func testRaceViewsWidgetsAndSound() {
        var app = demo("day", "2026-10-19T15:20:00")
        XCTAssertTrue(app.staticTexts["predictedFinish"].waitForExistence(timeout: timeout))
        Thread.sleep(forTimeInterval: 2)
        shoot("home-insights")
        app.terminate()
        app = demo("day", "2026-10-19T15:20:00", ["-flipRace"])
        Thread.sleep(forTimeInterval: 5)
        shoot("chart-marks")
        app.terminate()
        app = demo("day", "2026-10-19T15:20:00")
        app.tabBars.buttons["分析"].tap()
        let best = app.buttons["analysisBestRow"]
        XCTAssertTrue(best.waitForExistence(timeout: timeout))
        shoot("analysis-hub")
        best.tap()
        Thread.sleep(forTimeInterval: 2)
        shoot("analysis-best")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["analysisTimeMapRow"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["timeMapGrid"].waitForExistence(timeout: timeout))
        shoot("analysis-time-map")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["analysisPointsRow"].tap()
        let today = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "10月19日")).firstMatch
        if today.waitForExistence(timeout: timeout) { today.tap() }
        let laps = app.descendants(matching: .any)["lapList"].firstMatch
        for _ in 0..<4 where !(laps.exists && laps.isHittable) { app.swipeUp() }
        shoot("analysis-laps")
        app.terminate()
        app = demo("running", "2026-10-19T11:20:00")
        let ambient = app.buttons["ambientButton"]
        XCTAssertTrue(ambient.waitForExistence(timeout: timeout))
        shoot("timer-ambient-button")
        ambient.tap()
        XCTAssertTrue(app.buttons["ambient-rain"].waitForExistence(timeout: timeout))
        app.buttons["ambient-rain"].tap()
        Thread.sleep(forTimeInterval: 1)
        shoot("timer-ambient-sheet")
        app.terminate()
        app = demo("day", "2026-10-19T10:40:00", ["-widgetGallery"])
        Thread.sleep(forTimeInterval: 2)
        shoot("widget-gallery")
    }

    /// 自己ベストのラップ表（ANA-06）：表の全体が見えるまで送って撮る（見た目と文字サイズはシミュレーターの設定のまま）
    func testPersonalBestLaps() {
        let app = demo("day", "2026-10-22T15:20:00", ["-openBest", "all"])
        XCTAssertTrue(app.segmentedControls["bestPeriodPicker"].waitForExistence(timeout: timeout))
        Thread.sleep(forTimeInterval: 1)
        shoot("best-top")
        for index in 1...8 {
            app.swipeUp(velocity: .slow)
            Thread.sleep(forTimeInterval: 1)
            shoot("best-scrolled-\(index)")
        }
    }

    /// ラップ表の相手（ANA-06）・区間ベストの ★ と理論ベスト（ANA-11）・ベスト10（ANA-09）
    func testRecordsTargets() {
        let app = demo("day", "2026-10-22T15:20:00", ["-openBest", "all", "-lapTarget", "sectionBest", "-bestScroll", "laps"])
        let targets = app.segmentedControls["lapTargetPicker"]
        XCTAssertTrue(targets.waitForExistence(timeout: timeout))
        Thread.sleep(forTimeInterval: 2)
        shoot("records-section-best")
        targets.buttons["平均"].tap()
        Thread.sleep(forTimeInterval: 1)
        shoot("records-average")
        for index in 1...3 {
            app.swipeUp(velocity: .slow)
            Thread.sleep(forTimeInterval: 1)
            shoot("records-scrolled-\(index)")
        }
    }

    /// 押し忘れの申告（TMR-13）：計画のタブの申告の画面と、遅れて始めるときの聞き方
    func testDeclaration() {
        var app = demo("day", "2026-10-19T15:20:00", ["-openPlan"])
        let zemi = app.buttons.matching(identifier: "gridBlock").matching(NSPredicate(format: "label BEGINSWITH %@", "ゼミ準備 ")).firstMatch
        XCTAssertTrue(zemi.waitForExistence(timeout: timeout))
        zemi.tap()
        XCTAssertTrue(app.buttons["declareButton"].waitForExistence(timeout: timeout))
        Thread.sleep(forTimeInterval: 1)
        shoot("declare-sheet")
        app.terminate()
        app = demo("day", "2026-10-19T11:20:00")
        app.buttons["startButton"].tap()
        XCTAssertTrue(app.buttons["今から始める"].waitForExistence(timeout: timeout))
        Thread.sleep(forTimeInterval: 1)
        shoot("late-start-dialog")
    }

    /// 時間の格子（PLN-10）：計画のタブ（今の線、終わったブロックは薄い）と、長押しで動かしている途中
    func testPlanGrid() {
        let app = demo("day", "2026-10-19T11:20:00", ["-openPlan"])
        let exercise = app.buttons.matching(identifier: "gridBlock").matching(NSPredicate(format: "label BEGINSWITH %@", "運動 ")).firstMatch
        XCTAssertTrue(exercise.waitForExistence(timeout: timeout))
        Thread.sleep(forTimeInterval: 1)
        shoot("plan-tab-grid")
        app.swipeUp(velocity: .slow)
        Thread.sleep(forTimeInterval: 1)
        shoot("plan-tab-grid-later")
    }

    /// デトックスのグループ（2026-10-03）：設定の一覧の右のグループと、カテゴリの編集のグループの一覧
    func testDetoxGroups() {
        let app = demo("day", "2026-10-19T15:20:00", ["-openSettings"])
        let housework = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '家事'")).firstMatch
        for _ in 0..<5 where !(housework.exists && housework.isHittable) { app.collectionViews.firstMatch.swipeUp() }
        shoot("settings-categories")
        housework.tap()
        let rest = app.buttons["detoxGroup-rest"]
        XCTAssertTrue(app.buttons["detoxGroup-housework"].waitForExistence(timeout: timeout))
        for _ in 0..<3 where !rest.isHittable { app.collectionViews.firstMatch.swipeUp() }
        shoot("category-edit-group")
    }

    /// 計画の前の通知（TMR-12）：設定の行と、選ぶときの一覧。文字サイズ最大でも行が見えるまでずらして撮る
    func testBlockNoticeSetting() {
        let app = demo("day", "2026-10-19T11:20:00", ["-openSettings"])
        let picker = app.buttons["blockNoticePicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: timeout))
        // 文字サイズ最大では行が下の端にかかるので、画面の上半分に来るまでずらす
        let list = app.collectionViews.firstMatch
        let from = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        let to = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        for _ in 0..<4 where picker.frame.maxY > list.frame.midY { from.press(forDuration: 0.05, thenDragTo: to) }
        shoot("settings-block-notice")
        picker.tap()
        XCTAssertTrue(app.buttons["10分前"].waitForExistence(timeout: timeout))
        shoot("settings-block-notice-menu")
    }

    func testStaticScenes() {
        _ = demo("morning", "2026-10-19T07:00:00")
        shoot("morning")
        _ = demo("noplan", "2026-10-19T11:20:00")
        shoot("noplan")
        _ = demo("firstweek", "2026-10-19T11:20:00")
        shoot("firstweek")
        _ = demo("running", "2026-10-19T11:20:00")
        shoot("running")
        _ = launch(["-failStoreOpen"])
        shoot("store-error")
    }

    /// C 計画の変更（ホームの「今：〜」から計画のタブへ。直すとすぐ保存）
    func testPlanChange() {
        let app = demo("day", "2026-10-19T10:30:00")
        app.buttons["planLine"].tap()
        // 時間の格子（PLN-10）のブロックを押して編集の画面から消す
        let block = app.buttons.matching(identifier: "gridBlock").matching(NSPredicate(format: "label BEGINSWITH %@", "卒論 ")).firstMatch
        XCTAssertTrue(block.waitForExistence(timeout: timeout))
        shoot("plan-tab")
        block.tap()
        app.buttons["このブロックを削除"].tap()
        app.tabBars.buttons["タイマー"].tap()
        XCTAssertTrue(app.buttons["planLine"].waitForExistence(timeout: timeout))
        shoot("plan-edit-saved")
    }

    /// 段階1aの残り：通知の説明・比べる相手・設定・カテゴリ・振り返り・明日の計画
    func testRemainingScreens() {
        // 初めて計画を確定した直後の通知の説明
        var app = demo("morning", "2026-10-19T07:00:00")
        app.buttons["addBlockButton"].tap()
        app.buttons["blockSaveButton"].tap()
        app.buttons["confirmPlanButton"].tap()
        XCTAssertTrue(app.buttons["notificationsLaterButton"].waitForExistence(timeout: timeout))
        shoot("notification-intro")

        // 比べる相手の一覧
        app = demo("day", "2026-10-19T15:20:00")
        app.buttons["opponentButton"].tap()
        XCTAssertTrue(app.navigationBars["比べる相手"].waitForExistence(timeout: timeout))
        shoot("opponent-picker")
        let goal = app.buttons["opponent-goal"]
        for _ in 0..<4 where !goal.isHittable { app.collectionViews.firstMatch.swipeUp() }
        goal.tap()
        XCTAssertTrue(app.staticTexts["goalFocus"].waitForExistence(timeout: timeout))
        shoot("opponent-goal")

        // 設定とカテゴリの編集
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: timeout))
        shoot("settings")
        let study = app.staticTexts["勉強"]
        for _ in 0..<4 where !(study.exists && study.isHittable) { app.collectionViews.firstMatch.swipeUp() }
        study.tap()
        XCTAssertTrue(app.segmentedControls["countsAsFocusPicker"].waitForExistence(timeout: timeout))
        shoot("category-edit")

        // 計画外で開始の「＋ カテゴリ」
        app = demo("noplan", "2026-10-19T11:20:00")
        app.buttons["startButton"].tap()
        XCTAssertTrue(app.buttons["addCategoryButton"].waitForExistence(timeout: timeout))
        shoot("start-sheet")
        app.buttons["addCategoryButton"].tap()
        XCTAssertTrue(app.textFields["newCategoryNameField"].waitForExistence(timeout: timeout))
        shoot("add-category")

        // 夜の振り返りと明日の計画
        app = demo("day", "2026-10-19T22:30:00")
        shoot("home-night")
        app.buttons["reviewButton"].tap()
        XCTAssertTrue(app.buttons["planTomorrowButton"].waitForExistence(timeout: timeout))
        shoot("review")
        app.buttons["planTomorrowButton"].tap()
        XCTAssertTrue(app.navigationBars["明日の計画"].waitForExistence(timeout: timeout))
        shoot("tomorrow-empty")
        let addBlock = app.buttons["addBlockButton"]
        for _ in 0..<4 where !addBlock.isHittable { app.scrollViews.firstMatch.swipeUp() }
        addBlock.tap()
        XCTAssertTrue(app.buttons["blockSaveButton"].waitForExistence(timeout: timeout))
        shoot("tomorrow-block")
        app.buttons["blockSaveButton"].tap()
        shoot("tomorrow-plan")

        // 計画なし日の計画のタブ
        app = demo("noplan", "2026-10-19T11:20:00")
        app.tabBars.buttons["計画"].tap()
        XCTAssertTrue(app.buttons["makePlanButton"].waitForExistence(timeout: timeout))
        shoot("plan-tab-noplan")
    }

    /// E 計画外の一時停止
    func testUnplannedPause() {
        let app = demo("noplan", "2026-10-19T11:20:00")
        app.buttons["startButton"].tap()
        app.buttons["sheetStartButton"].tap()
        let pause = app.buttons["一時停止"]
        XCTAssertTrue(pause.waitForExistence(timeout: timeout))
        sleep(1)  // 全画面の表示が終わるのを待つ
        pause.tap()
        XCTAssertTrue(app.staticTexts["一時停止中"].waitForExistence(timeout: timeout))
        shoot("paused-unplanned")
    }

    /// H 1分未満
    func testShortSession() {
        let app = demo("day", "2026-10-19T11:20:00")
        app.buttons["startButton"].tap()
        // 今のブロックを遅れて始めるので「いつから」を聞かれる（TMR-13）
        let now = app.buttons["今から始める"]
        if now.waitForExistence(timeout: 3) { now.tap() }
        app.buttons["endButton"].tap()
        XCTAssertTrue(app.staticTexts["notice"].waitForExistence(timeout: timeout))
        shoot("short-notice")
    }

    /// I 止め忘れ
    func testForgot() {
        let app = demo("forgot", "2026-10-19T14:00:00")
        app.buttons["endButton"].tap()
        XCTAssertTrue(app.buttons["confirmEndTimeButton"].waitForExistence(timeout: timeout))
        shoot("forgot-sheet")
        app.buttons["confirmEndTimeButton"].tap()
        XCTAssertTrue(app.buttons["startButton"].waitForExistence(timeout: timeout))
        shoot("forgot-ended")
    }

    /// J 4:00 をまたぐ
    func testCrossDayBoundary() {
        let app = demo("forgot", "2026-10-20T04:10:00")
        app.buttons["endButton"].tap()
        app.buttons["confirmEndTimeButton"].tap()
        XCTAssertTrue(app.buttons["confirmPlanButton"].waitForExistence(timeout: timeout))
        shoot("crossed-morning-plan")
    }

    /// K 保存失敗
    func testSaveFailure() {
        let app = demo("running", "2026-10-19T11:20:00", ["-failSave"])
        app.buttons["endButton"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: timeout))
        shoot("save-error")
        app.alerts.buttons["OK"].tap()
        XCTAssertTrue(app.buttons["endButton"].waitForExistence(timeout: timeout))
    }

    /// タイムライン（カード）と、終了時刻を早めるシート
    func testTimeline() {
        let app = demo("day", "2026-10-19T15:20:00")
        app.tabBars.buttons["分析"].tap()
        app.buttons["analysisTimelineRow"].tap()
        let row = app.buttons["sessionRow"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: timeout))
        shoot("timeline")
        row.tap()
        XCTAssertTrue(app.buttons["shortenEndButton"].waitForExistence(timeout: timeout))
        shoot("timeline-shorten")
        app.buttons["shortenEndButton"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: timeout))
        shoot("timeline-shortened")
        app.buttons["previousDayButton"].tap()
        shoot("timeline-yesterday")
    }

    /// ブロックの追加（スクロールせずに長さまで届く）
    func testBlockEditor() {
        let app = demo("morning", "2026-10-19T07:00:00")
        let add = app.buttons["addBlockButton"]
        for _ in 0..<5 where !(add.exists && add.isHittable) { app.swipeUp() }
        add.tap()
        XCTAssertTrue(app.buttons["blockSaveButton"].waitForExistence(timeout: timeout))
        shoot("block-editor")
        // 開始時刻を押すと、分が5分刻みの回転式が出る
        app.datePickers["blockStartPicker"].tap()
        XCTAssertTrue(app.pickerWheels.firstMatch.waitForExistence(timeout: timeout))
        shoot("block-editor-start-picker")
    }

    /// 目標とテンプレート（GHO-10、PLN-07）
    func testGoalAndTemplates() {
        var app = demo("morning", "2026-10-19T07:00:00")
        XCTAssertTrue(app.buttons["addBlockButton"].waitForExistence(timeout: timeout))
        shoot("morning-template-bar")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH '理想の休日'")).firstMatch.tap()
        let stepper = app.steppers["goalStepper"]
        XCTAssertTrue(stepper.waitForExistence(timeout: timeout))
        stepper.buttons.element(boundBy: 1).tap()
        stepper.buttons.element(boundBy: 1).tap()
        shoot("morning-goal")

        app = demo("day", "2026-10-19T15:20:00")
        app.tabBars.buttons["計画"].tap()
        let section = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '理想の休日'")).firstMatch
        for _ in 0..<5 where !(section.exists && section.isHittable) { app.scrollViews.firstMatch.swipeUp() }
        shoot("plan-tab-templates")
        section.tap()
        XCTAssertTrue(app.textFields["templateNameField"].waitForExistence(timeout: timeout))
        shoot("template-edit")

        app = demo("noplan", "2026-10-19T11:20:00")
        app.tabBars.buttons["計画"].tap()
        let goal = app.steppers["goalStepper"]
        XCTAssertTrue(goal.waitForExistence(timeout: timeout))
        for _ in 0..<8 { goal.buttons.element(boundBy: 1).tap() }
        shoot("noplan-goal")
        app.tabBars.buttons["タイマー"].tap()
        shoot("noplan-goal-home")
    }

    /// 日中にテンプレートで進める
    func testApplyTemplateMidday() {
        let app = demo("day", "2026-10-19T11:20:00", ["-openPlan"])
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '理想の休日'")).firstMatch
        for _ in 0..<5 where !(row.exists && row.isHittable) { app.scrollViews.firstMatch.swipeUp() }
        shoot("midday-list")
        row.tap()
        XCTAssertTrue(app.buttons["applyTemplateButton"].waitForExistence(timeout: timeout))
        shoot("midday-preview")
        app.buttons["applyTemplateButton"].tap()
        shoot("midday-undo")
        for _ in 0..<3 { app.scrollViews.firstMatch.swipeDown() }
        shoot("midday-applied")
    }

    /// 設定の「集中中も使うアプリ」（BLK-02）。文字サイズ最大でも見えるところまでスクロールして撮る
    func testFocusAllowSettings() {
        let app = demo("day", "2026-10-19T11:20:00", ["-openSettings"])
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: timeout))
        // 一覧は画面の外の行をまだ作らないので、見えるまでスクロールする
        let row = app.buttons["focusAllowButton"]
        for _ in 0..<10 where !(row.exists && row.isHittable) { app.swipeUp() }
        XCTAssertTrue(row.isHittable)
        shoot("settings-focus-allow")
        row.tap()
        XCTAssertTrue(app.navigationBars["集中中も使うアプリ"].waitForExistence(timeout: timeout))
        shoot("focus-allow-picker")
    }

    /// ゲーム・SNS の時間（BLK-10、案A に決定）と睡眠の行（DTX-02）。朝の計画と、ブロックを追加の画面を撮る
    func testUnblockPlan() {
        let app = demo("gamePlan", "2026-10-19T07:00:00")
        XCTAssertTrue(app.buttons["confirmPlanButton"].waitForExistence(timeout: timeout))
        shoot("unblock-top")
        let row = app.buttons.matching(identifier: "gridBlock").matching(NSPredicate(format: "label BEGINSWITH %@", "ゲーム・SNS ")).firstMatch
        for _ in 0..<8 where !(row.exists && row.isHittable) { app.swipeUp() }
        shoot("unblock-list")
        let add = app.buttons["addBlockButton"]
        for _ in 0..<8 where !(add.exists && add.isHittable) { app.swipeUp() }
        add.tap()
        let chip = app.buttons["unblockChip"]
        XCTAssertTrue(chip.waitForExistence(timeout: timeout))
        chip.tap()
        shoot("unblock-editor")
    }

    /// 睡眠（DTX-02）：朝の計画の上の行、時刻を直す画面、設定の「睡眠」
    func testSleep() {
        let app = demo("gamePlan", "2026-10-19T07:30:00")
        let row = app.buttons["sleepRow"]
        XCTAssertTrue(row.waitForExistence(timeout: timeout))
        sleep(2)
        shoot("sleep-row")
        row.tap()
        XCTAssertTrue(app.buttons["sleepSaveButton"].waitForExistence(timeout: timeout))
        sleep(1)
        shoot("sleep-edit")
        let settings = demo("day", "2026-10-19T11:20:00", ["-openSettings"])
        let picker = settings.datePickers["sleepStartPicker"]
        for _ in 0..<10 where !(picker.exists && picker.isHittable) { settings.swipeUp() }
        shoot("sleep-settings")
    }

    /// 睡眠をヘルスケアから読み直す（DTX-02、2026-10-03）：直す画面のボタン、記録がないとき、読み直して閉じたあとの行
    func testSleepReread() {
        let empty = demo("gamePlan", "2026-10-19T07:30:00", ["-noHealthSleep"])
        XCTAssertTrue(empty.buttons["sleepRow"].waitForExistence(timeout: timeout))
        empty.buttons["sleepRow"].tap()
        let emptyButton = empty.buttons["sleepRereadButton"]
        XCTAssertTrue(emptyButton.waitForExistence(timeout: timeout))
        // 大きな文字では下に隠れるので、見えるまで送る
        for _ in 0..<6 where !emptyButton.isHittable { empty.swipeUp() }
        sleep(1)
        shoot("sleep-reread-sheet")
        emptyButton.tap()
        XCTAssertTrue(empty.staticTexts["sleepNoRecordText"].waitForExistence(timeout: timeout))
        sleep(1)  // ひとことまで送り終えるのを待つ
        shoot("sleep-reread-norecord")

        let app = demo("gamePlan", "2026-10-19T07:30:00")
        XCTAssertTrue(app.buttons["sleepRow"].waitForExistence(timeout: timeout))
        app.buttons["sleepRow"].tap()
        XCTAssertTrue(app.buttons["sleepRereadButton"].waitForExistence(timeout: timeout))
        app.buttons["sleepRereadButton"].tap()
        XCTAssertTrue(app.buttons["sleepSaveButton"].waitForNonExistence(timeout: timeout))
        sleep(1)
        shoot("sleep-reread-done")
    }
}
