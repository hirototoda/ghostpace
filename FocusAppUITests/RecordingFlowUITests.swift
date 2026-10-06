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
        XCTAssertTrue(planBlock(app, "ゼミ準備").waitForExistence(timeout: timeout))

        // 下書きは再起動しても残る
        app.terminate()
        app = launch(store("ui-a", at: "09:12:00", reset: false))
        XCTAssertTrue(planBlock(app, "ゼミ準備").waitForExistence(timeout: timeout))
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

    /// タイムライン：下のタブの分析から開き、記録をタップして終了時刻を早めると「修正済み」になる（TML-04、NAV-01）
    func testTimelineShortenEnd() {
        let app = launch(["-seedDemoData", "day", "-fixedNow", "2026-10-19T15:20:00+09:00"])
        let open = app.tabBars.buttons["分析"]
        XCTAssertTrue(open.waitForExistence(timeout: timeout))
        open.tap()
        app.buttons["analysisTimelineRow"].tap()
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
        XCTAssertTrue(planBlock(app, "卒論").waitForExistence(timeout: timeout))
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
    /// 最初の裏返しだけ動き（直前2時間が伸びる約1.5秒。その間は［1日］［▶］を押せない）、2回目はすぐ押せる。裏返し直すと3時間に戻る（GHO-13、1b-15〜17）
    func testRaceChartZoomAndIntroOnlyOnce() {
        let app = launch(["-seedDemoData", "day", "-fixedNow", "2026-10-19T15:20:00+09:00", "-opponent", "goal"])
        let focus = app.descendants(matching: .any)["todayFocus"]
        XCTAssertTrue(focus.waitForExistence(timeout: timeout))
        focus.tap()
        let zoom = app.buttons["raceZoomButton"]
        XCTAssertTrue(zoom.waitForExistence(timeout: timeout))
        // 最初は動いている間（約1.85秒）［1日］［▶］を押せない。ほかを調べる前に確かめる。動き終わると押せる
        XCTAssertFalse(zoom.isEnabled)
        XCTAssertFalse(app.buttons["raceReplayButton"].isEnabled)
        XCTAssertTrue(zoom.wait(for: \.isEnabled, toEqual: true, timeout: 6))
        XCTAssertTrue(app.descendants(matching: .any)["raceGap"].label.hasPrefix("差 "))
        // グラフは VoiceOver で1つの部品として読む
        XCTAssertEqual(app.descendants(matching: .any)["今日たまったポイントのグラフ"].exists, true)
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

    /// ［▶］で 4:00 から今までを流し、［■］で止める。流している間は［1日］を押せない。
    /// ［1日］のときに押しても3時間で流し、最後まで流れたら［▶］に戻る（GHO-13、1b-26、2026-10-05）
    func testRaceChartReplayTheDay() {
        let app = launch(["-seedDemoData", "day", "-fixedNow", "2026-10-19T08:00:00+09:00", "-opponent", "goal"])
        let focus = app.descendants(matching: .any)["todayFocus"]
        XCTAssertTrue(focus.waitForExistence(timeout: timeout))
        focus.tap()
        let zoom = app.buttons["raceZoomButton"]
        let replay = app.buttons["raceReplayButton"]
        XCTAssertTrue(replay.waitForExistence(timeout: timeout))
        // 開いたときの動きが終わるのを待つ
        XCTAssertTrue(zoom.wait(for: \.isEnabled, toEqual: true, timeout: 6))
        XCTAssertTrue(replay.isEnabled)
        XCTAssertEqual(replay.label, "1日を流す")

        // 流している間は［■］、［1日］は押せない。［■］で止める
        replay.tap()
        XCTAssertTrue(replay.wait(for: \.label, toEqual: "止める", timeout: timeout))
        XCTAssertFalse(zoom.isEnabled)
        replay.tap()
        XCTAssertTrue(replay.wait(for: \.label, toEqual: "1日を流す", timeout: timeout))
        XCTAssertTrue(zoom.wait(for: \.isEnabled, toEqual: true, timeout: timeout))
        XCTAssertEqual(zoom.label, "1日全体を見る")

        // ［1日］から押しても3時間で流し、最後まで流れると（8:00 なら5秒）［▶］に戻って3時間のまま
        zoom.tap()
        XCTAssertTrue(zoom.wait(for: \.label, toEqual: "3時間に戻す", timeout: timeout))
        replay.tap()
        XCTAssertTrue(zoom.wait(for: \.label, toEqual: "1日全体を見る", timeout: timeout))
        XCTAssertTrue(replay.wait(for: \.label, toEqual: "1日を流す", timeout: 10))
        XCTAssertTrue(zoom.isEnabled)

        // 速くはじいてすぐ［1日］→［3時間］を押すと、滑りは止まって今のまわりの3時間のまま動かない（2026-10-05 慣性）
        let plot = app.descendants(matching: .any)["今日たまったポイントのグラフ"]
        let home = plot.value as? String
        plot.swipeLeft(velocity: .fast)
        zoom.tap()
        XCTAssertTrue(zoom.wait(for: \.label, toEqual: "3時間に戻す", timeout: timeout))
        zoom.tap()
        XCTAssertTrue(zoom.wait(for: \.label, toEqual: "1日全体を見る", timeout: timeout))
        let settled = plot.value as? String
        XCTAssertEqual(settled, home)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(plot.value as? String, settled)
    }

    /// 分析のタブ：一覧からポイントの推移 → 過ぎた日のグラフ（1日で始まり「この日」）→ 戻る。
    /// 今日の振り返りは昼でも開ける（NAV-01・ANA-04・05・REV-01、1b-27〜29、2026-10-05）
    func testAnalysisPointsAndDayGraph() {
        let app = launch(["-seedDemoData", "day", "-fixedNow", "2026-10-19T15:20:00+09:00"])
        let tab = app.tabBars.buttons["分析"]
        XCTAssertTrue(tab.waitForExistence(timeout: timeout))
        tab.tap()
        let points = app.buttons["analysisPointsRow"]
        XCTAssertTrue(points.waitForExistence(timeout: timeout))
        XCTAssertTrue(points.label.contains("7日の平均"))
        points.tap()

        // ［7日｜30日］で切り替えられる
        let picker = app.segmentedControls["pointsRangePicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: timeout))
        picker.buttons["30日"].tap()
        XCTAssertTrue(picker.buttons["30日"].isSelected)
        picker.buttons["7日"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH '10月19日'")).firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["日ごとのポイントのグラフ"].exists)

        // 昨日を押すと、その日のグラフが1日全体で始まる（動かないので［3時間］がすぐ押せる）
        let yesterday = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '10月18日'")).firstMatch
        XCTAssertTrue(yesterday.waitForExistence(timeout: timeout))
        yesterday.tap()
        let zoom = app.buttons["raceZoomButton"]
        XCTAssertTrue(zoom.waitForExistence(timeout: timeout))
        XCTAssertTrue(zoom.isEnabled)
        XCTAssertEqual(zoom.label, "3時間に戻す")
        XCTAssertTrue(app.descendants(matching: .any)["この日たまったポイントのグラフ"].exists)
        XCTAssertTrue(app.staticTexts["10月18日(日)"].exists)

        // 戻って、一覧から今日の振り返りを開く（通知の 22:00 の前でも開ける）
        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        let review = app.buttons["analysisReviewRow"]
        XCTAssertTrue(review.waitForExistence(timeout: timeout))
        review.tap()
        XCTAssertTrue(app.staticTexts["今のところ・確定は朝4:00"].waitForExistence(timeout: timeout))
    }

    /// テンプレートの読み込み：確認なしで置き換わり、「元に戻す」で戻る（PLN-07、1a-17）
    func testTemplateReplaceAndUndo() {
        let app = launch(["-seedDemoData", "morning", "-fixedNow", "2026-10-19T07:00:00+09:00"])
        let add = app.buttons["addBlockButton"]
        XCTAssertTrue(add.waitForExistence(timeout: timeout))
        add.tap()
        app.buttons["読書"].tap()
        app.buttons["blockSaveButton"].tap()
        XCTAssertTrue(planBlock(app, "読書").waitForExistence(timeout: timeout))

        app.buttons.matching(NSPredicate(format: "label BEGINSWITH '理想の休日'")).firstMatch.tap()
        XCTAssertTrue(planBlock(app, "瞑想").waitForExistence(timeout: timeout))
        let undo = app.buttons["undoTemplateButton"]
        XCTAssertTrue(undo.waitForExistence(timeout: timeout))
        undo.tap()
        XCTAssertFalse(planBlock(app, "瞑想").exists)
        XCTAssertTrue(planBlock(app, "読書").exists)
    }

    /// 日中にテンプレートで進める：計画のタブで押して「今日はこれで進む」、今から先だけ置き換わり「元に戻す」で戻る
    func testApplyTemplateMidday() {
        let app = launch(["-seedDemoData", "day", "-fixedNow", "2026-10-19T11:20:00+09:00", "-openPlan"])
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '理想の休日'")).firstMatch
        for _ in 0..<5 where !(row.exists && row.isHittable) { app.scrollViews.firstMatch.swipeUp() }
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
        for _ in 0..<5 { app.scrollViews.firstMatch.swipeDown() }
        XCTAssertTrue(planBlock(app, "掃除").waitForExistence(timeout: timeout))  // 掃除が入る
        XCTAssertTrue(planBlock(app, "ゼミ準備").exists)  // 今のブロックは残る
        XCTAssertFalse(planBlock(app, "卒論").exists)  // まだ始まっていない卒論は外れる
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
        XCTAssertTrue(planBlock(app, "ゲーム・SNS").waitForExistence(timeout: timeout))
        XCTAssertTrue(app.buttons["confirmPlanButton"].isEnabled)
    }

    /// 習慣（PLN-08）：初めて使う端末で習慣の画面が先に出て、決めたゲーム・SNS の時間が朝の計画に最初から入る。
    /// 開き直しても習慣の画面はもう出ない
    func testHabitIntroFillsTheMorningPlan() {
        let app = launch(store("habits", at: "07:00:00", reset: true) + ["-habitIntro"])
        let add = app.buttons["addHabitButton"]
        XCTAssertTrue(add.waitForExistence(timeout: timeout))
        XCTAssertFalse(app.buttons["finishHabitsButton"].isEnabled)
        add.tap()
        let chip = app.buttons["unblockChip"]
        XCTAssertTrue(chip.waitForExistence(timeout: timeout))
        chip.tap()
        app.buttons["blockSaveButton"].tap()
        let finish = app.buttons["finishHabitsButton"]
        XCTAssertTrue(finish.waitForExistence(timeout: timeout))
        finish.tap()
        XCTAssertTrue(app.buttons["confirmPlanButton"].waitForExistence(timeout: timeout))
        XCTAssertTrue(planBlock(app, "ゲーム・SNS").exists)

        app.terminate()
        let again = launch(store("habits", at: "07:05:00", reset: false) + ["-habitIntro"])
        XCTAssertTrue(again.buttons["confirmPlanButton"].waitForExistence(timeout: timeout))
        XCTAssertFalse(again.buttons["addHabitButton"].exists)
    }

    /// 候補（PLN-09）を押すと計画に足され、候補から消える。計画のタブから習慣を直すとすぐ行に出る（PLN-08）
    func testAddCandidateAndEditHabits() {
        let app = launch(["-seedDemoData", "habits", "-fixedNow", "2026-10-19T07:00:00+09:00"])
        XCTAssertTrue(app.buttons["confirmPlanButton"].waitForExistence(timeout: timeout))
        // 先週の月曜だけにある 12:30 の掃除（朝の計画の下の方。後ろのタブの画面ではなく、いちばん上の画面を送る）
        let cleaning = app.buttons.matching(identifier: "candidate").matching(label("先週の月曜")).firstMatch
        // 下の「この計画で始める」の帯に隠れない所まで送る
        let confirm = app.buttons["confirmPlanButton"]
        for _ in 0..<15 where !(cleaning.exists && cleaning.isHittable && cleaning.frame.maxY < confirm.frame.minY - 20) {
            app.swipeUp(velocity: .slow)
        }
        Thread.sleep(forTimeInterval: 1)  // 送り終わるのを待つ（動いている間に押すと止まるだけ）
        XCTAssertTrue(cleaning.isHittable)
        cleaning.tap()
        XCTAssertFalse(app.buttons.matching(identifier: "candidate").matching(label("先週の月曜")).firstMatch.exists)
        // 足したブロックは上の計画の一覧に入る（一覧は見えている行だけ読めるので、上へ戻して探す）
        let added = planBlock(app, "掃除")
        for _ in 0..<6 where !added.isHittable { app.swipeDown() }
        XCTAssertTrue(added.exists)
        XCTAssertTrue(added.label.contains("12:30–13:00"))

        app.buttons["confirmPlanButton"].tap()
        let later = app.buttons["あとで"]
        if later.waitForExistence(timeout: 3) { later.tap() }
        app.tabBars.buttons["計画"].tap()
        let row = app.descendants(matching: .any)["habitsRow"].firstMatch
        for _ in 0..<6 where !(row.exists && row.isHittable) { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(row.label.contains("ゲーム・SNS 2つ"))
        row.tap()
        let add = app.buttons["addHabitButton"]
        XCTAssertTrue(add.waitForExistence(timeout: timeout))
        add.tap()
        app.buttons["unblockChip"].tap()
        app.buttons["blockSaveButton"].tap()
        XCTAssertTrue(app.staticTexts.containing(label("あと0つ")).firstMatch.waitForExistence(timeout: timeout))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(row.waitForExistence(timeout: timeout))
        XCTAssertTrue(row.label.contains("ゲーム・SNS 3つ"))
    }

    private func label(_ text: String) -> NSPredicate { NSPredicate(format: "label CONTAINS %@", text) }

    /// 時間の格子（PLN-10）：空いた所を押すとその時刻から足せる。重なる所へのドラッグは元に戻って理由が出る。空いた所へは動く
    func testPlanGridTapAndDrag() {
        let app = launch(["-seedDemoData", "day", "-fixedNow", "2026-10-19T11:20:00+09:00", "-openPlan"])
        let zemi = planBlock(app, "ゼミ準備"), thesis = planBlock(app, "卒論")
        XCTAssertTrue(thesis.waitForExistence(timeout: timeout))
        // 13:00〜14:00 の空きの上の方（13:10 ごろ）を押す → 13:00 に切り下げて1時間
        let origin = app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: thesis.frame.midX, dy: zemi.frame.maxY + 10)).tap()
        let save = app.buttons["blockSaveButton"]
        XCTAssertTrue(save.waitForExistence(timeout: timeout))
        save.tap()
        XCTAssertTrue(planBlock(app, "勉強").waitForExistence(timeout: timeout))
        XCTAssertTrue(planBlock(app, "勉強").label.contains("13:00–14:00"))

        // 卒論を1時間下へ → 運動と重なるので元のまま
        let start = thesis.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        start.press(forDuration: 0.6, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 60)))
        XCTAssertTrue(app.descendants(matching: .any)["gridProblem"].waitForExistence(timeout: timeout))
        XCTAssertTrue(planBlock(app, "卒論").label.contains("14:00–16:00"))

        // 運動を1時間下へ → 17:00〜18:00
        let scroll = app.scrollViews.firstMatch
        let exercise = planBlock(app, "運動")
        for _ in 0..<3 where exercise.frame.maxY > scroll.frame.midY { scroll.swipeUp(velocity: .slow) }
        let from = exercise.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        from.press(forDuration: 0.6, thenDragTo: from.withOffset(CGVector(dx: 0, dy: 60)))
        XCTAssertTrue(planBlock(app, "運動").label.contains("17:00–18:00"))

        // 格子の上でも、すぐのドラッグは画面を上下に送る（最後に確かめる。送ったあとの位置で押すと下のタブに隠れることがある）
        let before = planBlock(app, "読書").frame.minY
        app.swipeUp(velocity: .slow)
        XCTAssertNotEqual(planBlock(app, "読書").frame.minY, before)
    }

    /// 押し忘れの申告（TMR-13）：計画のタブで記録のない終わったブロックを押すと「やった（申告）」で記録になり、二度は出ない
    func testDeclareForgottenBlock() {
        let app = launch(["-seedDemoData", "day", "-fixedNow", "2026-10-19T15:20:00+09:00", "-openPlan"])
        let zemi = planBlock(app, "ゼミ準備")
        XCTAssertTrue(zemi.waitForExistence(timeout: timeout))
        zemi.tap()
        let declare = app.buttons["declareButton"]
        XCTAssertTrue(declare.waitForExistence(timeout: timeout))
        XCTAssertTrue(declare.isEnabled)
        declare.tap()
        XCTAssertFalse(declare.waitForExistence(timeout: 2))
        zemi.tap()
        XCTAssertTrue(app.buttons["blockSaveButton"].waitForExistence(timeout: timeout))
        XCTAssertFalse(app.buttons["declareButton"].exists)
    }

    /// ブロックの最中に始めるとき（TMR-13、案A）：「11:00 から始めていた（申告）」を選ぶとタイマーが始まる
    func testStartLateFromBlockStart() {
        let app = launch(["-seedDemoData", "day", "-fixedNow", "2026-10-19T11:20:00+09:00"])
        let start = app.buttons["startButton"]
        XCTAssertTrue(start.waitForExistence(timeout: timeout))
        start.tap()
        let fromStart = app.buttons["11:00 から始めていた（申告）"]
        XCTAssertTrue(fromStart.waitForExistence(timeout: timeout))
        XCTAssertTrue(app.buttons["今から始める"].exists)
        fromStart.tap()
        XCTAssertTrue(app.buttons["endButton"].waitForExistence(timeout: timeout))
    }

    /// 見せ方と環境音（ANA-06・07、GHO-15、TMR-14）：ホームに予想ゴール、分析に自己ベストと時間帯の地図、タイマーの ♪ で音を選べる
    func testInsightsAnalysisAndAmbient() {
        var app = launch(["-seedDemoData", "day", "-fixedNow", "2026-10-19T15:20:00+09:00"])
        XCTAssertTrue(app.staticTexts["predictedFinish"].waitForExistence(timeout: timeout))
        app.tabBars.buttons["分析"].tap()
        let best = app.buttons["analysisBestRow"]
        XCTAssertTrue(best.waitForExistence(timeout: timeout))
        best.tap()
        XCTAssertTrue(app.navigationBars["自己ベスト"].waitForExistence(timeout: timeout))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["analysisTimeMapRow"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["timeMapGrid"].waitForExistence(timeout: timeout))
        app.terminate()
        app = launch(["-seedDemoData", "running", "-fixedNow", "2026-10-19T11:20:00+09:00"])
        let ambient = app.buttons["ambientButton"]
        XCTAssertTrue(ambient.waitForExistence(timeout: timeout))
        XCTAssertEqual(ambient.value as? String, "なし")
        ambient.tap()
        let rain = app.buttons["ambient-rain"]
        XCTAssertTrue(rain.waitForExistence(timeout: timeout))
        rain.tap()
        XCTAssertTrue(rain.isSelected)
        app.buttons["完了"].tap()
        XCTAssertTrue(ambient.waitForExistence(timeout: timeout))
        XCTAssertEqual(ambient.value as? String, "雨")
    }

    /// 今のブロックの最中でもタイマーがなければ次を前倒しで始められる（TMR-15）。計画どおりの点の帯（2秒）は単体テストで確かめる
    func testEarlyStartDuringABlock() {
        let app = launch(["-seedDemoData", "day", "-fixedNow", "2026-10-19T11:40:00+09:00"])
        let early = app.buttons["startEarlyButton"]
        XCTAssertTrue(early.waitForExistence(timeout: timeout))
        XCTAssertTrue(app.buttons["ゼミ準備を開始"].exists)
        early.tap()
        XCTAssertTrue(app.staticTexts["卒論"].waitForExistence(timeout: timeout))
        XCTAssertTrue(app.buttons["endButton"].exists)
    }

    /// 終わったブロックを遅れて始める（TMR-15）：ホームの「さっき」の行から。計画のタブの編集の画面にも［今から始める］
    func testStartMissedBlockLate() {
        var app = launch(["-seedDemoData", "missed", "-fixedNow", "2026-10-19T11:15:00+09:00"])
        let missed = app.buttons["startMissedButton"]
        XCTAssertTrue(missed.waitForExistence(timeout: timeout))
        XCTAssertTrue(app.buttons["startEarlyButton"].exists)
        missed.tap()
        XCTAssertTrue(app.buttons["endButton"].waitForExistence(timeout: timeout))
        XCTAssertTrue(app.staticTexts.containing(label("11:45 終了予定")).firstMatch.waitForExistence(timeout: timeout))
        app.terminate()
        app = launch(["-seedDemoData", "missed", "-fixedNow", "2026-10-19T11:15:00+09:00", "-openPlan"])
        let block = app.buttons.matching(identifier: "gridBlock").matching(NSPredicate(format: "label BEGINSWITH %@", "読書 10:30")).firstMatch
        XCTAssertTrue(block.waitForExistence(timeout: timeout))
        block.tap()
        let start = app.buttons["startLateButton"]
        XCTAssertTrue(start.waitForExistence(timeout: timeout))
        start.tap()
        XCTAssertTrue(app.buttons["endButton"].waitForExistence(timeout: timeout))
    }

    /// 計画の時間の格子のブロック（PLN-10）。読み上げは「名前 時刻」
    private func planBlock(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.buttons.matching(identifier: "gridBlock").matching(NSPredicate(format: "label BEGINSWITH %@", name + " ")).firstMatch
    }

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

    /// 睡眠をヘルスケアから読み直す（DTX-02）：記録がなければ開いたままひとこと出し、あれば閉じて行が「ヘルスケア」
    func testRereadSleepFromHealth() {
        let empty = launch(["-seedDemoData", "gamePlan", "-fixedNow", "2026-10-19T07:30:00+09:00", "-noHealthSleep"])
        XCTAssertTrue(empty.buttons["sleepRow"].waitForExistence(timeout: timeout))
        empty.buttons["sleepRow"].tap()
        XCTAssertTrue(empty.buttons["sleepRereadButton"].waitForExistence(timeout: timeout))
        empty.buttons["sleepRereadButton"].tap()
        XCTAssertTrue(empty.staticTexts["sleepNoRecordText"].waitForExistence(timeout: timeout))
        XCTAssertTrue(empty.buttons["sleepSaveButton"].exists)

        let app = launch(["-seedDemoData", "gamePlan", "-fixedNow", "2026-10-19T07:30:00+09:00"])
        XCTAssertTrue(app.buttons["sleepRow"].waitForExistence(timeout: timeout))
        app.buttons["sleepRow"].tap()
        XCTAssertTrue(app.buttons["sleepRereadButton"].waitForExistence(timeout: timeout))
        app.buttons["sleepRereadButton"].tap()
        XCTAssertTrue(app.buttons["sleepSaveButton"].waitForNonExistence(timeout: timeout))
        XCTAssertTrue(app.buttons["sleepRow"].label.contains("ヘルスケア"))
    }
}
