---
name: ghostpace-dev
description: GhostPace（focus-app）の機能開発・仕様変更の標準フロー。このリポジトリではグローバルの spec-dev の代わりに使う。選択肢で仕様を詰める → docs 更新 → 画面が変わるなら SwiftUI の案をスクショで選ぶ → テスト先行で実装 → verify-ios → review-3 → 報告・PR・自動マージ → TestFlight。引数: 要望の説明。
---

# GhostPace 開発フロー

オーナーはコードを読まず、docs と画面（スクショ・実機）だけで判断する。週5〜10時間の個人開発なので、確認の回数は変更の大きさに合わせて絞る。

## 0. 始める前に
- `CLAUDE.md`、`docs/README.md`、関係する `docs/product/features/*.md`・`requirements.md`・`design/data-model.md` を読む
- 作業は公開リポジトリ ghostpace（`~/Desktop/ghostpace`）で行う。報告と判断の表は非公開の focus-app（`~/Desktop/focus-app-private`）に書く（ADR-0021）
- `git status` と `git worktree list` を見る。自分のものでない未コミットの変更があれば、別のセッションが作業中。触らずに `git worktree add -b <branch> ../ghostpace-<名前> origin/main` で別の作業場所を作る
- 大きさを決める

  | 大きさ | 例 | 行う段階 |
  |---|---|---|
  | 小 | 文言・色・1画面内の小さな不具合 | 1・4・5・7・8 |
  | 中 | 画面の追加、操作の流れの変更 | すべて |
  | データの形が変わる | SwiftData のモデル・スキーマ | すべて。マージはオーナーの確認後（ADR-0010 の例外） |

## 1. 仕様を詰める
- 決まっていないことは AskUserQuestion で聞く。1回4問まで、推奨を先頭に置いて「(推奨)」を付け、説明には表示例や数字を入れる
- オーナーの回答が選択肢と違う言い方なら、解釈を1行で示してから進める。新しい決め事が生まれたら、画面を見せるときに確認する
- 決まったら、実装より先に docs を直す
  - `docs/product/features/*.md`（振る舞い）と `requirements.md`（要件IDを足す・直す）
  - `docs/design/data-model.md`（データが変わるとき）
  - 非公開側（`~/Desktop/focus-app-private`）の `docs/owner/open-questions.md` の「決定済み」表（日付・事項・決定・記録先）。公開側の docs には「Q33（非公開の判断表）」のように番号だけ書く
- 聞いていないことを実装で勝手に決めない。迷ったら非公開側の open-questions.md に書く
- 公開側（このリポジトリ）には、個人の情報・値段・自分の数字・秘密の情報を書かない（ADR-0021）

## 2. 画面の案を選ぶ（画面が変わるとき）
- SwiftUI で2〜3案を作る。HTML のモックは作らない
- 見本データと DEBUG の「見本 ▾」メニューで、案・場面を切り替えられるようにする
- シミュレーターで撮る：`scripts/sim-shot.sh <出力.png> -fixedNow <日時> ...`。時刻の表示は `xcrun simctl status_bar <UDID> override --time "HH:MM"` で合わせる
- 案を `scripts/shot-grid.py` で横に並べ、非公開側の `~/Desktop/focus-app-private/docs/reports/assets/` に置き、**`open` で開いて**から聞く。仕様（features）から画像を参照するときは、見本データの画面だけを公開側の `docs/product/assets/` に写す。Claude が Read した画像はオーナーには見えない
- シミュレーターも切り替えられる状態で起動しておき、「見本 ▾」の使い方を伝える
- 選ばれなかった案のコードは消す

## 3. 仕様のレビュー（中以上）
- `/review-3` を docs の変更に1回。critical・major は docs に反映する。判断が割れるものだけオーナーに聞く
- review-3 の3体には「`.claude/rules/review-checklist.md` をグローバルのチェックリストより優先せよ」と必ず伝える（グローバルの項目は Web アプリ向け）

### 区切る（中以上）
段階1〜3で決めたことは docs にあるので、実装の前に会話を軽くする。長い会話のまま実装に入ると、以降のやりとりが毎回重くなる。
- `.claude/state/session-notes.md` を書く：要望、大きさ、選ばれた画面案、直した docs のファイル、review-3 で直したこと・見送ったことと理由、作業ブランチ・worktree、「次は段階4から」
- オーナーに「ここで一度区切ります。`/compact` と打ち、終わったら『続けて』と送ってください」と伝えて止まる（Claude は自分で compact できない）。`/clear` や新しいセッションにはしない（session-notes が自動で戻るのは compact のときだけ）
- 再開したら、session-notes と変更した docs を読み直してから段階4へ進む
- 段階5で手間取って会話が長くなったときも、段階6の前に同じように区切ってよい

## 4. テストを先に書いて実装する
- Swift Testing でテストを先に書き、失敗を確かめてから実装する。テストを弱めて通すのは禁止
- 守ること：現在時刻は `AppClock`（テストは `FixedClock`・`OffsetClock`）、日付の区切りは `DayBoundary`（朝4:00）、データは Repository 経由、`project.yml` を直して `xcodegen generate`
- ビルドは XcodeBuildMCP を使う（最初に `session_show_defaults` を呼ぶ）。テストは push して GitHub Actions で回す（ユニット全件＋UI 全件。使い方は verify-ios の手順3）。早く確かめたいテストだけ、この Mac の `scripts/test.sh` で回してよい
- 主な操作の流れが変わるなら、UI テスト（FocusAppUITests）を1本足す

## 5. 動作確認
- `verify-ios` スキルに従う。ライト・ダーク・文字サイズ最大（`xcrun simctl ui <sim> content_size accessibility-extra-extra-extra-large`）で撮り、崩れは直す。撮り終えたら `content_size large` に戻す
- `docs/verification/acceptance/` の結果欄を更新する

## 6. 実装のレビュー（中以上）
- `/review-3` を差分に1回（`.claude/rules/review-checklist.md` を渡す）。critical・major を直して push し、CI をもう一度通す

## 7. 報告・PR・マージ
- 非公開側に `~/Desktop/focus-app-private/docs/reports/YYYY-MM-DD-<内容>.md` を書く（テンプレートは非公開側の `docs/reports/README.md`）。決めたこと、スクショ、テストの件数、オーナーへのお願い
- コミットと PR のタイトルに要件ID（例：TMR-07）を入れる
- 報告・open-questions は非公開側の main に直接コミットして push する（`git pull --rebase` してから。PR は作らない）。報告の「PR:」に ghostpace の PR を書く
- docs と報告がそろったら `gh pr merge <番号> --auto --squash --delete-branch` で自動マージを予約する。CI の「CI OK」が通ると GitHub がマージする（ADR-0010・0021）。データの形が変わる PR は予約せず、オーナーの確認を待つ
- CI が失敗したら直して push する（予約はそのまま残る）
- CI の結果は `gh pr checks <番号> --watch` を Bash の `run_in_background` で1本だけ走らせて待つ。終われば知らせが来るので、`gh pr checks` を何度も打って様子を見ない。待つあいだは報告など別の作業を進める
- `.claude/state/session-notes.md` を更新する

## 8. iPhone に届ける（画面や動きが変わったとき）
- マージすると、GitHub Actions が main でテスト全件 → TestFlight に送る（ADR-0011・0021。docs だけの変更では送らない）。`gh run list -R hirototoda/ghostpace --workflow TestFlight` で回の番号を調べ、`gh run watch <番号> -R hirototoda/ghostpace --exit-status` を `run_in_background` で待つ（何度も見に行かない）。送れたら「マージから40分〜1時間で iPhone の TestFlight に届く」と伝える。失敗したら直す PR を出す
- CI が使えないときだけ、この Mac の main で `scripts/testflight.sh` をバックグラウンドで実行する
- オーナーが急いでいるときは、CLAUDE.md の `devicectl` の手順で直接入れる。起動の指示が失敗したら（画面ロック中など）、「ホーム画面から開いてください」と伝える

## オーナーへの伝え方
- 地の文は日本語。専門用語は避けるか、ひとこと添える
- 最後の報告は、何ができたか → 見てほしいもの（画像・シミュレーター・実機）→ 決めてほしいこと、の順にする
