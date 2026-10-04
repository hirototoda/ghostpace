import XCTest

/// 再起動をまたぐ流れと、タイマー画面のつながり（docs/plan/recording-spec.md のテスト計画）。
@MainActor
final class RecordingFlowUITests: XCTestCase {
    private let timeout: TimeInterval = 10

    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        return app
    }

    private func store(_ name: String, at time: String, reset: Bool) -> [String] {
        ["-storeName", name] + (reset ? ["-resetStore"] : []) + ["-fixedNow", "2026-10-19T\(time)+09:00"]
    }

    /// 台本 A
    func testMorningPlanPersistsDraftAndConfirm() {
        // 時計は起動後も進むので、5分単位の切り上げで開始が 09:10 になる時刻から始める
        var app = launch(store("ui-a", at: "09:05:30", reset: true))
        let confirm = app.buttons["confirmPlanButton"]
        XCTAssertTrue(confirm.waitForExistence(timeout: timeout))
        XCTAssertFalse(confirm.isEnabled)

        app.buttons["addBlockButton"].tap()
        app.buttons["勉強に新しいブロック名を作る"].tap()
        let name = app.alerts.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: timeout))
        // 入力欄にカーソルが入る前に打つと文字が入らないことがあるので、押してから打つ。
        // 日本語キーボードでは変換中の文字が残るので、改行で確定する
        name.tap()
        name.typeText("ゼミ準備\n")
        // 改行で閉じなかったときだけ「作成」を押す（閉じかけのボタンを押さないよう、少し待ってから見る）
        let create = app.alerts.buttons["作成"]
        if create.waitForExistence(timeout: 1), create.isHittable { create.tap() }
        XCTAssertTrue(app.buttons["ゼミ準備"].waitForExistence(timeout: timeout))
        XCTAssertTrue(app.buttons["ゼミ準備"].isSelected)
        app.buttons["blockSaveButton"].tap()
        XCTAssertTrue(app.staticTexts["ゼミ準備"].waitForExistence(timeout: timeout))

        // 下書きは再起動しても残る
        app.terminate()
        app = launch(store("ui-a", at: "09:12:00", reset: false))
        XCTAssertTrue(app.staticTexts["ゼミ準備"].waitForExistence(timeout: timeout))
        app.buttons["confirmPlanButton"].tap()
        // 初めて確定した直後に、通知の説明が1回だけ出る（TMR-05）
        let later = app.buttons["notificationsLaterButton"]
        XCTAssertTrue(later.waitForExistence(timeout: timeout))
        later.tap()
        XCTAssertTrue(app.buttons["ゼミ準備を開始"].waitForExistence(timeout: timeout))

        // 確定した日は計画画面が出ない。通知の説明も二度は出ない
        app.terminate()
        app = launch(store("ui-a", at: "09:15:00", reset: false))
        XCTAssertTrue(app.buttons["ゼミ準備を開始"].waitForExistence(timeout: timeout))
        XCTAssertFalse(app.buttons["confirmPlanButton"].exists)
        XCTAssertFalse(app.buttons["notificationsLaterButton"].exists)
    }

    /// 台本 B
    func testSkipPlanPersists() {
        var app = launch(store("ui-b", at: "09:10:00", reset: true))
        let skip = app.buttons["skipPlanButton"]
        XCTAssertTrue(skip.waitForExistence(timeout: timeout))
        skip.tap()
        XCTAssertTrue(app.staticTexts["計画なし"].waitForExistence(timeout: timeout))

        app.terminate()
        app = launch(store("ui-b", at: "10:00:00", reset: false))
        XCTAssertTrue(app.staticTexts["計画なし"].waitForExistence(timeout: timeout))
        XCTAssertFalse(app.buttons["skipPlanButton"].exists)

        // 「計画なし」を押すと、あとから計画を作れる。閉じれば計画なしのまま
        app.buttons["planLine"].tap()
        XCTAssertTrue(app.buttons["skipPlanButton"].waitForExistence(timeout: timeout))
        app.buttons["skipPlanButton"].tap()
        XCTAssertTrue(app.staticTexts["計画なし"].waitForExistence(timeout: timeout))
    }

    /// 台本 G（1a-5）
    func testRunningTimerSurvivesRelaunch() {
        var app = launch(store("ui-g", at: "10:00:00", reset: true))
        let skip = app.buttons["skipPlanButton"]
        XCTAssertTrue(skip.waitForExistence(timeout: timeout))
        skip.tap()
        app.buttons["startButton"].tap()
        app.buttons["決めない"].tap()
        app.buttons["sheetStartButton"].tap()
        XCTAssertTrue(app.staticTexts["timerReading"].waitForExistence(timeout: timeout))

        app.terminate()
        // 30秒の余裕で起動の遅れを吸収する
        app = launch(store("ui-g", at: "10:30:30", reset: false))
        let reading = app.staticTexts["timerReading"]
        XCTAssertTrue(reading.waitForExistence(timeout: timeout))
        XCTAssertTrue(app.staticTexts["経過"].exists)
        XCTAssertTrue(reading.label.hasPrefix("30:"), "経過が \(reading.label)")
    }

    /// 台本 D の画面のつながり
    func testPauseResumeEnd() {
        let app = launch(["-seedDemoData", "running", "-fixedNow", "2026-10-19T11:20:00+09:00"])
        let pause = app.buttons["一時停止"]
        XCTAssertTrue(pause.waitForExistence(timeout: timeout))
        pause.tap()
        XCTAssertTrue(app.staticTexts["一時停止中"].waitForExistence(timeout: timeout))
        app.buttons["再開"].tap()
        XCTAssertTrue(app.buttons["一時停止"].waitForExistence(timeout: timeout))
        XCTAssertFalse(app.staticTexts["一時停止中"].exists)
        app.buttons["endButton"].tap()
        XCTAssertTrue(app.buttons["startButton"].waitForExistence(timeout: timeout))
        XCTAssertFalse(app.staticTexts["timerReading"].exists)
    }

    /// タイムライン：下のタブから開き、記録をタップして終了時刻を早めると「修正済み」になる（TML-04）
    func testTimelineShortenEnd() {
        let app = launch(["-seedDemoData", "day", "-fixedNow", "2026-10-19T15:20:00+09:00"])
        let open = app.tabBars.buttons["タイムライン"]
        XCTAssertTrue(open.waitForExistence(timeout: timeout))
        open.tap()
        let row = app.buttons["sessionRow"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: timeout))
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS '修正済み'")).firstMatch.exists)
        row.tap()
        let save = app.buttons["shortenEndButton"]
        XCTAssertTrue(save.waitForExistence(timeout: timeout))
        save.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS '修正済み'")).firstMatch.waitForExistence(timeout: timeout))
        // 前の日にさかのぼれて、今日より先には行けない
        XCTAssertFalse(app.buttons["nextDayButton"].isEnabled)
        app.buttons["previousDayButton"].tap()
        XCTAssertTrue(app.buttons["nextDayButton"].isEnabled)
    }

    /// 台本 K：保存に失敗してもタイマー画面のまま、もう一度押せる
    func testSaveFailureKeepsTimer() {
        let app = launch(["-seedDemoData", "running", "-fixedNow", "2026-10-19T11:20:00+09:00", "-failSave"])
        let end = app.buttons["endButton"]
        XCTAssertTrue(end.waitForExistence(timeout: timeout))
        end.tap()
        let alert = app.alerts["保存できませんでした"]
        XCTAssertTrue(alert.waitForExistence(timeout: timeout))
        alert.buttons["OK"].tap()
        XCTAssertTrue(app.buttons["endButton"].waitForExistence(timeout: timeout))
        XCTAssertTrue(app.staticTexts["timerReading"].exists)
    }

    /// 実機確認用（環境変数 REAL_WAIT=1 のときだけ動く）：本物の時計で、アプリを完全に閉じて90秒後に開いてもタイマーが続いている（1a-5）。
    /// 待ち時間は画面の自動ロックより短くする（ロックされるとテストが止まる）。保存先は検証用の別ファイル（-storeName）なので、実際の記録には触れない。
    func testRunningTimerSurvivesRealWaitClosed() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["REAL_WAIT"] == "1", "REAL_WAIT=1 のときだけ（90秒かかる）")
        var app = launch(["-storeName", "device-check", "-resetStore"])
        let skip = app.buttons["skipPlanButton"]
        if skip.waitForExistence(timeout: timeout) { skip.tap() }
        app.buttons["startButton"].tap()
        app.buttons["決めない"].tap()
        app.buttons["sheetStartButton"].tap()
        XCTAssertTrue(app.staticTexts["timerReading"].waitForExistence(timeout: timeout))
        // テストを動かす側の時計で、開始からの実際の経過を測る（アプリの表示と比べる）
        let startedAt = Date()

        app.terminate()
        sleep(90)
        app = launch(["-storeName", "device-check"])
        let reading = app.staticTexts["timerReading"]
        XCTAssertTrue(reading.waitForExistence(timeout: timeout))
        let actual = Date().timeIntervalSince(startedAt)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "device-after-wait"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertTrue(app.staticTexts["経過"].exists)
        let parts = reading.label.split(separator: ":").compactMap { Int($0) }
        let shown = parts.count == 2 ? Double(parts[0] * 60 + parts[1]) : -1
        // 起動や画面の読み取りにかかる時間の分だけ、15秒までのずれは許す
        XCTAssertLessThanOrEqual(abs(shown - actual), 15, "表示 \(reading.label)、実際の経過 \(Int(actual))秒")
        XCTAssertGreaterThanOrEqual(shown, 90)
    }

    /// 下のタブ・設定・夜の振り返りのつながり（NAV-01、CAT-04、REV-01）
    func testTabsSettingsAndReview() {
        let app = launch(["-seedDemoData", "day", "-fixedNow", "2026-10-19T22:30:00+09:00"])
        // 計画のタブで今日の計画が見える
        let planTab = app.tabBars.buttons["計画"]
        XCTAssertTrue(planTab.waitForExistence(timeout: timeout))
        planTab.tap()
        XCTAssertTrue(app.staticTexts["卒論"].waitForExistence(timeout: timeout))
        XCTAssertTrue(app.buttons["addBlockButton"].exists)

        // ホームの歯車から設定を開き、カテゴリを足す
        app.tabBars.buttons["タイマー"].tap()
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: timeout))
        let add = app.buttons["settingsAddCategoryButton"]
        // 一覧の下の方にあるので、見えるまで送る
        for _ in 0..<4 where !add.isHittable { app.swipeUp() }
        XCTAssertTrue(add.waitForExistence(timeout: timeout))
        add.tap()
        let name = app.textFields["newCategoryNameField"]
        XCTAssertTrue(name.waitForExistence(timeout: timeout))
        // 入力欄にカーソルが入る前に打つと文字が入らないことがあるので、押してから打つ
        name.tap()
        name.typeText("ピアノ\n")
        // 改行で閉じなかったときだけ「追加」を押す（閉じかけのボタンを押さないよう、少し待ってから見る）
        let confirm = app.buttons["confirmAddCategoryButton"]
        if confirm.waitForExistence(timeout: 1), confirm.isHittable { confirm.tap() }
        // 行は「ピアノ」のボタンとして出る（設定の一覧が長くなったので、見えるまで送る）
        let piano = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'ピアノ'")).firstMatch
        for _ in 0..<4 where !piano.exists { app.swipeUp() }
        XCTAssertTrue(piano.waitForExistence(timeout: timeout))
        app.navigationBars["設定"].buttons["閉じる"].tap()

        // 夜は「今日を振り返る」から振り返りを開き、明日の計画へ進める
        let review = app.buttons["reviewButton"]
        XCTAssertTrue(review.waitForExistence(timeout: timeout))
        review.tap()
        XCTAssertTrue(app.descendants(matching: .any)["reviewGaps"].waitForExistence(timeout: timeout))
        XCTAssertTrue(app.staticTexts["ゼミ準備"].exists)
        app.buttons["planTomorrowButton"].tap()
        XCTAssertTrue(app.navigationBars["明日の計画"].waitForExistence(timeout: timeout))
    }

    /// デトックスのカテゴリを作るときにグループを一覧から選べ、設定の一覧の右に出る（CAT-04、DTX-03、BD-26）
    func testAddDetoxCategoryWithGroup() {
        let app = launch(["-seedDemoData", "day", "-fixedNow", "2026-10-19T15:20:00+09:00"])
        let settings = app.buttons["settingsButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: timeout))
        settings.tap()
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: timeout))
        let add = app.buttons["settingsAddCategoryButton"]
        for _ in 0..<4 where !add.isHittable { app.swipeUp() }
        add.tap()
        let name = app.textFields["newCategoryNameField"]
        XCTAssertTrue(name.waitForExistence(timeout: timeout))
        // デトックスにすると、グループの一覧が出る（初めは「なし」）
        app.buttons["デトックス"].tap()
        let exercise = app.buttons["detoxGroup-exercise"]
        XCTAssertTrue(exercise.waitForExistence(timeout: timeout))
        XCTAssertTrue(app.buttons["detoxGroup-none"].isSelected)
        exercise.tap()
        XCTAssertTrue(exercise.isSelected)
        name.tap()
        name.typeText("散歩\n")
        let confirm = app.buttons["confirmAddCategoryButton"]
        if confirm.waitForExistence(timeout: 1), confirm.isHittable { confirm.tap() }
        let walk = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '散歩'")).firstMatch
        for _ in 0..<4 where !walk.exists { app.swipeUp() }
        XCTAssertTrue(walk.waitForExistence(timeout: timeout))
        XCTAssertTrue(walk.label.contains("グループ 運動"), walk.label)
        // 初めからある家事にもグループが出る
        let housework = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '家事'")).firstMatch
        XCTAssertTrue(housework.exists)
        XCTAssertTrue(housework.label.contains("グループ 家事"), housework.label)
    }

    /// 円の中の「先週 〜」を押すと比べる相手を選べ、選んだ相手が円と差に出る（GHO-10、1a-18）
    func testOpponentPickerChangesRing() {
        let app = launch(["-seedDemoData", "day", "-fixedNow", "2026-10-19T15:20:00+09:00"])
        let open = app.buttons["opponentButton"]
        XCTAssertTrue(open.waitForExistence(timeout: timeout))
        XCTAssertTrue(app.staticTexts["ghostFocus"].exists)
        open.tap()
        let goal = app.buttons["opponent-goal"]
        XCTAssertTrue(goal.waitForExistence(timeout: timeout))
        goal.tap()
        XCTAssertTrue(app.staticTexts["goalFocus"].waitForExistence(timeout: timeout))
        XCTAssertTrue(app.staticTexts["ghostDiff"].label.hasPrefix("目標より"))
    }

    /// 円（トラック）を押すと裏返って24時間のポイントのグラフ、もう一度押すと戻る（GHO-12〜14、1b-6〜8。2026-10-02 からポイントだけ）
    func testRaceCardFlipsToChart() {
        let app = launch(["-seedDemoData", "day", "-fixedNow", "2026-10-19T14:30:00+09:00"])
        let track = app.descendants(matching: .any)["raceTrack"]
        XCTAssertTrue(track.waitForExistence(timeout: timeout))
        app.descendants(matching: .any)["todayFocus"].tap()
        let chart = app.descendants(matching: .any)["raceChart"]
        XCTAssertTrue(chart.waitForExistence(timeout: timeout))
        let summary = app.descendants(matching: .any)["raceSummary"]
        XCTAssertTrue(summary.label.contains("pt"))
        // 時間とポイントの切り替えはない
        XCTAssertFalse(app.buttons["時間"].exists)

        // 裏にいる間は、表の「vs 先週の自分」は押せない
        let hiddenButton = app.buttons["opponentButton"]
        XCTAssertFalse(hiddenButton.exists && hiddenButton.isHittable)

        // 相手の一覧のボタンは裏では押せない。グラフを押すと表に戻る
        chart.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()
        XCTAssertTrue(app.buttons["opponentButton"].waitForExistence(timeout: timeout))
        XCTAssertTrue(app.buttons["opponentButton"].isHittable)

        // 裏にしてからほかのアプリへ行き、戻ってくると表から
        app.descendants(matching: .any)["todayFocus"].tap()
        XCTAssertTrue(chart.waitForExistence(timeout: timeout))
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["opponentButton"].waitForExistence(timeout: timeout))
        XCTAssertTrue(app.buttons["opponentButton"].isHittable)
    }

    /// 裏のグラフ：3時間で始まり、［1日］で24時間、［3時間］で戻る。上の行に差。
    /// 最初の裏返しだけ動き（その間は［1日］を押せない）、2回目はすぐ押せる。裏返し直すと3時間に戻る（GHO-13、1b-15〜17）
    func testRaceChartZoomAndIntroOnlyOnce() {
        let app = launch(["-seedDemoData", "day", "-fixedNow", "2026-10-19T15:20:00+09:00", "-opponent", "goal"])
        let focus = app.descendants(matching: .any)["todayFocus"]
        XCTAssertTrue(focus.waitForExistence(timeout: timeout))
        focus.tap()
        let zoom = app.buttons["raceZoomButton"]
        XCTAssertTrue(zoom.waitForExistence(timeout: timeout))
        XCTAssertTrue(app.descendants(matching: .any)["raceGap"].label.hasPrefix("差 "))
        // グラフは VoiceOver で1つの部品として読む
        XCTAssertEqual(app.descendants(matching: .any)["今日たまったポイントのグラフ"].exists, true)
        // 最初は動いている間［1日］を押せない。動き終わると押せる
        XCTAssertFalse(zoom.isEnabled)
        XCTAssertTrue(zoom.wait(for: \.isEnabled, toEqual: true, timeout: 6))
        XCTAssertEqual(zoom.label, "1日全体を見る")
        // 指で右へずらすと前の時刻が見える（裏返らない）
        let plot = app.descendants(matching: .any)["今日たまったポイントのグラフ"]
        let before = plot.value as? String
        plot.swipeRight()
        XCTAssertNotNil(before)
        XCTAssertNotEqual(plot.value as? String, before)
        XCTAssertTrue(zoom.exists)
        zoom.tap()
        XCTAssertTrue(zoom.wait(for: \.label, toEqual: "3時間に戻す", timeout: timeout))
        zoom.tap()
        XCTAssertTrue(zoom.wait(for: \.label, toEqual: "1日全体を見る", timeout: timeout))

        // 1日にしてから表に戻し、もう一度裏返すと、動かずに3時間から
        zoom.tap()
        XCTAssertTrue(zoom.wait(for: \.label, toEqual: "3時間に戻す", timeout: timeout))
        app.descendants(matching: .any)["raceChart"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()
        XCTAssertTrue(app.buttons["opponentButton"].waitForExistence(timeout: timeout))
        focus.tap()
        XCTAssertTrue(zoom.wait(for: \.isEnabled, toEqual: true, timeout: 1.5))
        XCTAssertEqual(zoom.label, "1日全体を見る")

        // ほかのアプリへ行って戻ると表から。最初の裏返しはまた動く
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["opponentButton"].waitForExistence(timeout: timeout))
        focus.tap()
        XCTAssertTrue(zoom.waitForExistence(timeout: timeout))
        XCTAssertFalse(zoom.isEnabled)
        XCTAssertTrue(zoom.wait(for: \.isEnabled, toEqual: true, timeout: 6))
    }

    /// テンプレートの読み込み：確認なしで置き換わり、「元に戻す」で戻る（PLN-07、1a-17）
    func testTemplateReplaceAndUndo() {
        let app = launch(["-seedDemoData", "morning", "-fixedNow", "2026-10-19T07:00:00+09:00"])
        let add = app.buttons["addBlockButton"]
        XCTAssertTrue(add.waitForExistence(timeout: timeout))
        add.tap()
        app.buttons["読書"].tap()
        app.buttons["blockSaveButton"].tap()
        XCTAssertTrue(app.staticTexts["読書"].waitForExistence(timeout: timeout))

        app.buttons.matching(NSPredicate(format: "label BEGINSWITH '理想の休日'")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["瞑想"].waitForExistence(timeout: timeout))
        let undo = app.buttons["undoTemplateButton"]
        XCTAssertTrue(undo.waitForExistence(timeout: timeout))
        undo.tap()
        XCTAssertFalse(app.staticTexts["瞑想"].exists)
        XCTAssertTrue(app.staticTexts["読書"].exists)
    }

    /// 日中にテンプレートで進める：計画のタブで押して「今日はこれで進む」、今から先だけ置き換わり「元に戻す」で戻る
    func testApplyTemplateMidday() {
        let app = launch(["-seedDemoData", "day", "-fixedNow", "2026-10-19T11:20:00+09:00", "-openPlan"])
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '理想の休日'")).firstMatch
        for _ in 0..<5 where !(row.exists && row.isHittable) { app.collectionViews.firstMatch.swipeUp() }
        row.tap()
        let apply = app.buttons["applyTemplateButton"]
        XCTAssertTrue(apply.waitForExistence(timeout: timeout))
        apply.tap()
        // 「元に戻す」は6秒で消えるので、先に戻せることを確かめる
        let undo = app.buttons["undoTemplateButton"]
        XCTAssertTrue(undo.waitForExistence(timeout: timeout))
        undo.tap()
        XCTAssertFalse(undo.exists)

        // もう一度進めると、今から先だけ置き換わる
        row.tap()
        XCTAssertTrue(apply.waitForExistence(timeout: timeout))
        apply.tap()
        for _ in 0..<5 { app.collectionViews.firstMatch.swipeDown() }
        XCTAssertTrue(app.staticTexts["13:30–14:00"].waitForExistence(timeout: timeout))  // 掃除が入る
        XCTAssertTrue(app.staticTexts["ゼミ準備"].exists)  // 今のブロックは残る
        XCTAssertFalse(app.staticTexts["14:00–16:00"].exists)  // まだ始まっていない卒論は外れる
    }

    /// 設定の「計画の前の通知」：初めは5分前。選ぶと変わり、開き直しても残る（TMR-12、1b-22）
    func testBlockNoticeSetting() {
        let app = launch(["-seedDemoData", "day", "-fixedNow", "2026-10-19T11:20:00+09:00", "-openSettings"])
        let picker = app.buttons["blockNoticePicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: timeout))
        XCTAssertTrue(picker.label.contains("5分前"), picker.label)
        picker.tap()
        for choice in ["オフ", "ちょうど", "10分前", "15分前"] {
            XCTAssertTrue(app.buttons[choice].waitForExistence(timeout: timeout), choice)
        }
        app.buttons["10分前"].tap()
        XCTAssertTrue(picker.waitForExistence(timeout: timeout))
        XCTAssertTrue(picker.label.contains("10分前"), picker.label)
    }

    /// 設定の「開ける」→ 長さを選ぶ → 短く押しても数えない → 3秒押すと5秒数えて開く → 今すぐ戻す（BLK-07・BLK-08、1a-24）
    func testHoldToUnlock() {
        let app = launch(["-seedDemoData", "day", "-fixedNow", "2026-10-19T11:20:00+09:00", "-openSettings"])
        let open = app.buttons["settingsOpenHoldButton"]
        XCTAssertTrue(open.waitForExistence(timeout: timeout))
        open.tap()
        let hold = app.buttons["holdButton"]
        XCTAssertTrue(hold.waitForExistence(timeout: timeout))
        XCTAssertTrue(app.descendants(matching: .any)["holdRaceLine"].exists)

        // 長さは15分から。5分刻みで変わる
        XCTAssertEqual(app.staticTexts["unlockMinutes"].label, "15分")
        app.buttons["unlockMinutesPlus"].tap()
        XCTAssertEqual(app.staticTexts["unlockMinutes"].label, "20分")
        app.buttons["unlockMinutesMinus"].tap()
        app.buttons["unlockMinutesMinus"].tap()
        XCTAssertEqual(app.staticTexts["unlockMinutes"].label, "10分")

        // 1.5秒で離すと数え始めない
        hold.press(forDuration: 1.5)
        let countdown = app.descendants(matching: .any)["unlockCountdown"]
        XCTAssertFalse(countdown.waitForExistence(timeout: 1))
        // 3秒以上押すと5秒数え、そのあと開く
        hold.press(forDuration: 3.5)
        XCTAssertTrue(countdown.waitForExistence(timeout: timeout))
        XCTAssertFalse(app.staticTexts["unlockedTitle"].exists)
        XCTAssertTrue(app.staticTexts["unlockedTitle"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["unlockRemaining"].exists)

        // 今すぐ戻すと閉じて、設定は「ブロック中」
        app.buttons["reblockNowButton"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["blockingStatus"].waitForExistence(timeout: timeout))
        XCTAssertTrue(app.staticTexts["ブロック中"].exists)
        XCTAssertTrue(app.buttons["settingsOpenHoldButton"].exists)
    }

    /// 数えている間に「やめる」を押すと開かない（BLK-08）
    func testCountdownCanBeCancelled() {
        let app = launch(["-seedDemoData", "day", "-fixedNow", "2026-10-19T11:20:00+09:00", "-openSettings"])
        let open = app.buttons["settingsOpenHoldButton"]
        XCTAssertTrue(open.waitForExistence(timeout: timeout))
        open.tap()
        let hold = app.buttons["holdButton"]
        XCTAssertTrue(hold.waitForExistence(timeout: timeout))
        hold.press(forDuration: 3.5)
        XCTAssertTrue(app.descendants(matching: .any)["unlockCountdown"].waitForExistence(timeout: timeout))
        app.buttons["holdCancelButton"].tap()
        XCTAssertTrue(app.staticTexts["ブロック中"].waitForExistence(timeout: timeout))
        XCTAssertFalse(app.staticTexts["unlockedTitle"].waitForExistence(timeout: 7))
    }

    /// ブロックするアプリを変える：長押し（3秒＋5秒）のあと選ぶ画面が出て、「完了」で閉じる（BLK-09）
    func testChangeBlockedAppsNeedsHold() {
        let app = launch(["-seedDemoData", "day", "-fixedNow", "2026-10-19T11:20:00+09:00", "-openSettings"])
        let change = app.buttons["blockSelectionButton"]
        XCTAssertTrue(change.waitForExistence(timeout: timeout))
        change.tap()
        let hold = app.buttons["holdButton"]
        XCTAssertTrue(hold.waitForExistence(timeout: timeout))
        // 長押しが終わるまで「完了」は出ない
        XCTAssertFalse(app.buttons["blockSelectionDoneButton"].exists)
        hold.press(forDuration: 3.5)
        let done = app.buttons["blockSelectionDoneButton"]
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        done.tap()
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: timeout))
        XCTAssertFalse(done.exists)
    }

    /// 集中中も使うアプリ：長押しなしで選ぶ画面が出て、「完了」で閉じる（BLK-02。タイマー中は設定を開けないので長押しは要らない）
    func testChooseFocusAllowAppsWithoutHold() {
        let app = launch(["-seedDemoData", "day", "-fixedNow", "2026-10-19T11:20:00+09:00", "-openSettings"])
        let row = app.buttons["focusAllowButton"]
        XCTAssertTrue(row.waitForExistence(timeout: timeout))
        XCTAssertTrue(row.label.contains("なし（全部ブロック）"))
        row.tap()
        XCTAssertTrue(app.navigationBars["集中中も使うアプリ"].waitForExistence(timeout: timeout))
        XCTAssertFalse(app.buttons["holdButton"].exists)
        let done = app.buttons["blockSelectionDoneButton"]
        XCTAssertTrue(done.waitForExistence(timeout: timeout))
        done.tap()
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: timeout))
    }

    /// 朝の計画で「ゲーム・SNS」を足す（BLK-10）：長さは30分で決まり、一覧にオレンジの行が出る
    func testAddGameTimeInMorningPlan() {
        let app = launch(["-seedDemoData", "morning", "-fixedNow", "2026-10-19T07:00:00+09:00"])
        let add = app.buttons["addBlockButton"]
        XCTAssertTrue(add.waitForExistence(timeout: timeout))
        add.tap()
        let chip = app.buttons["unblockChip"]
        XCTAssertTrue(chip.waitForExistence(timeout: timeout))
        chip.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "30分（決まり）")).firstMatch.exists)
        app.buttons["blockSaveButton"].tap()
        XCTAssertTrue(app.staticTexts["ゲーム・SNS"].waitForExistence(timeout: timeout))
        XCTAssertTrue(app.buttons["confirmPlanButton"].isEnabled)
    }

    private func label(_ text: String) -> NSPredicate { NSPredicate(format: "label CONTAINS %@", text) }

    /// 前倒しで始める（TMR-10）：10:40、次は 11:00–13:00 のゼミ準備 → ［今から始める］で 13:00 までのカウントダウン
    func testEarlyStart() {
        let app = launch(["-seedDemoData", "day", "-fixedNow", "2026-10-19T10:40:00+09:00"])
        let early = app.buttons["startEarlyButton"]
        XCTAssertTrue(early.waitForExistence(timeout: timeout))
        early.tap()
        XCTAssertTrue(app.staticTexts["ゼミ準備"].waitForExistence(timeout: timeout))
        XCTAssertTrue(app.staticTexts.containing(label("13:00 終了予定")).firstMatch.waitForExistence(timeout: timeout))
    }

    /// 計画の時刻で切り替える（TMR-11）：計画外のまま 11:00 を過ぎた → ［ゼミ準備に切り替える］→ 11:05 から
    func testSwitchToBlockAtItsTime() {
        let app = launch(["-seedDemoData", "offPlanAtBlock", "-fixedNow", "2026-10-19T11:05:00+09:00"])
        let switchButton = app.buttons["switchToBlockButton"]
        XCTAssertTrue(switchButton.waitForExistence(timeout: timeout))
        XCTAssertTrue(app.staticTexts["勉強"].waitForExistence(timeout: timeout))
        switchButton.tap()
        XCTAssertTrue(app.staticTexts["ゼミ準備"].waitForExistence(timeout: timeout))
        XCTAssertTrue(app.staticTexts.containing(label("11:05 開始・13:00 終了予定")).firstMatch.waitForExistence(timeout: timeout))
        XCTAssertFalse(app.buttons["switchToBlockButton"].exists)
    }

    /// 計画外で開始のシートで、勉強の中の「英語」を選んで始める（TMR-01）
    func testOffPlanWithProject() {
        let app = launch(["-seedDemoData", "day", "-fixedNow", "2026-10-19T10:40:00+09:00"])
        let start = app.buttons["startButton"]
        XCTAssertTrue(start.waitForExistence(timeout: timeout))
        start.tap()
        let project = app.buttons["英語"]
        XCTAssertTrue(project.waitForExistence(timeout: timeout))
        project.tap()
        let sheetStart = app.buttons["sheetStartButton"]
        XCTAssertTrue(app.buttons.containing(label("英語を開始")).firstMatch.waitForExistence(timeout: timeout))
        sheetStart.tap()
        XCTAssertTrue(app.staticTexts["英語"].waitForExistence(timeout: timeout))
        XCTAssertTrue(app.buttons["endButton"].exists)
    }
}
