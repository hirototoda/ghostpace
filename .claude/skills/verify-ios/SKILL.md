---
name: verify-ios
description: 実装後の動作確認と報告。機能を実装・修正したら必ず使う。ビルド、ユニットテスト・UIテスト、シミュレーターでの画面確認とスクリーンショット（ライト・ダーク・文字サイズ最大）、docs/reports への報告作成までを行う。
---

# iOS動作確認

オーナーはコードを読まない。報告のスクリーンショットとテスト結果だけで判断できるようにする。方針は docs/verification/strategy.md。

## 手順
1. `xcodegen generate` でプロジェクトを作り直す
2. XcodeBuildMCP でビルドする（最初に `session_show_defaults`）。失敗したら直してからやり直す
   - 別の作業場所（git worktree）にいるときは、MCP の既定のプロジェクトが本体を指している。`xcodebuild build -project FocusApp.xcodeproj -scheme FocusApp -destination 'id=<シミュレーターのUDID>' -derivedDataPath <scratchpad> -quiet 2>&1 | tail -40` を使う（そのままだと数千行出て会話が重くなる。失敗したら `grep -E 'error:|warning:.*FocusApp'` で原因の行だけ見る）
3. テストは **push して GitHub Actions で回す**（docs/verification/strategy.md「テストの回し方」、ADR-0021）。PR を出す・push するたびに、ユニットテスト全件と UI テスト全件が回る（約20〜30分）
   - 待つあいだは別の作業を進める。結果は `gh pr checks <番号> --watch`（Bash の `run_in_background` で）。件数は `gh run view <run> --log | grep 成功` で見る（`--log` をそのまま出さない。失敗したときは `gh run view <run> --log-failed | tail -80`）
   - 失敗したら `gh run download <run> -n test-results-<塊>` でログと xcresult を取り、原因を直して push する。「やり直して通った UI テスト」の警告が出たら、報告に書く
   - 急ぎのときだけ、この Mac で `scripts/test.sh` を使う（Mac 全体の順番待ち。同時に2つまで。始める前に `uptime` で負荷を確かめ、`run_in_background` で実行）。例 `scripts/test.sh ui RecordingFlowUITests/testPauseResumeEnd OpenedTimeUITests`。別の作業場所では `--sim <自分用のシミュレーターのUDID>` を付ける
   - `xcodebuild test` と XcodeBuildMCP の `test_sim` はフックで止まる（例外は下の実機の待ち時間テストだけ）
4. 該当する受け入れ基準を docs/verification/acceptance/ から読む
5. シミュレーターで確認する
   - 撮影は `scripts/sim-shot.sh <出力.png> [起動引数...]`
   - 時間に依存する項目は起動引数 `-fixedNow <日時>`（例 `2026-10-19T11:20`）で時刻を固定する。あわせて `xcrun simctl status_bar <UDID> override --time "11:20"` で画面上の時計も合わせる（"HH:MM" の形。日時の形は失敗することがある）。終わったら `status_bar <UDID> clear`
   - 過去データが必要な項目は `-seedDemoData <場面>` で入れる（day / morning / noplan / running / forgot / firstweek。メモリ内なので本物のデータに触れない）
   - タップが必要な場面は `FocusAppUITests/ScreenTourUITests` に足し、`scripts/test.sh tour ScreenTourUITests/<テスト名>` で実行する。画像は、最後に表示される場所の xcresult から `xcrun xcresulttool export attachments` で取り出す
   - 場面を切り替える起動引数は `LaunchOptions.swift` の冒頭に一覧がある
   - 各基準について操作し、スクリーンショットを撮って自分で目で確かめる。Read するのは `scripts/shot-grid.py` で並べた1枚だけにし、1枚ずつ Read しない（画像1枚ごとにトークンを使う）
6. 主要画面をライト・ダーク・文字サイズ最大でも撮る
   - ダーク：`xcrun simctl ui <UDID> appearance dark`（戻す：`light`）
   - 文字サイズ最大：`xcrun simctl ui <UDID> content_size accessibility-extra-extra-extra-large`（戻す：`large`）
   - 崩れ（はみ出し・重なり・切れ）は直してから撮り直す。円や大きな数字のように広げられない部分だけ `.dynamicTypeSize(...)` で上限を付ける
   - 撮り終えたら見た目の設定を必ず元に戻す
   - 別の作業場所で自分用に複製したシミュレーターは、撮り終えたら `xcrun simctl shutdown <UDID>` で止める（起動したままだと、何もしなくてもメモリと CPU を使う）
7. スクリーンショットを非公開側の ~/Desktop/focus-app-private/docs/reports/assets/ に保存する。何枚もあるときは `scripts/shot-grid.py <出力.png> <列数> <画像...>` で1枚に並べる
8. 受け入れ基準ファイルの「結果」欄を更新する
9. 非公開側の ~/Desktop/focus-app-private/docs/reports/README.md のテンプレートで報告を書く

## オーナーに見てもらうとき
- Claude が Read で見た画像は、オーナーには見えない。**`open <画像>` で Preview に開いてから**聞く
- シミュレーターも、見てほしい場面で起動しておく。DEBUG の「見本 ▾」メニューがあれば使い方を伝える

## 実機でしか確認できない項目
Screen Time API（ブロック、シールド、DeviceActivity）、通知の実際の届き方、実機の再起動をまたぐ挙動。
アプリを完全に閉じてからの時間経過は、実機で `TEST_RUNNER_REAL_WAIT=1 xcodebuild test -destination 'id=<UDID>' -only-testing:FocusAppUITests/RecordingFlowUITests/testRunningTimerSurvivesRealWaitClosed` として Claude が確かめられる（待ちは画面の自動ロックより短くする）。
これらは確認したふりをせず、報告の「オーナーにお願いしたいこと」に、iPhoneで行う具体的な操作手順と期待される結果を書く。
iPhone への届け方は、マージすると GitHub Actions が TestFlight に送る（ADR-0011・0021）。急ぐときは非公開側の CLAUDE.md の `devicectl` の手順。

## 失敗したとき
直せない失敗は隠さず報告に書く。仕様の解釈に迷った場合は実装で決めず、非公開側の docs/owner/open-questions.md に追記する。
