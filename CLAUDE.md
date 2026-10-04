# GhostPace

個人用のiPhone時間管理アプリ。朝の計画 → 自動ブロック → 集中タイマー → 記録 → 過去の自分との対戦・振り返り。
SwiftUI / SwiftData / XcodeGen。オーナーはコードを読まず、docs/ と非公開の報告だけを読む。

このリポジトリ（ghostpace）は公開している。売り方・報告・判断待ちの事項・実機の情報は、非公開のリポジトリ focus-app（この Mac では `~/Desktop/focus-app-private`）に置く（ADR-0021）。**公開側に個人の情報・値段・自分の数字・秘密の情報を書かない。**

## 最重要ルール
- **仕様の正は docs/**。振る舞いを変えたら同じPRで該当ドキュメントを更新する。docsとコードが矛盾したら実装前にオーナーへ確認。
- 要件IDは docs/product/requirements.md を参照。コミットとPRに対応するID（例: TMR-02）を書く。
- 作業完了時は、非公開側の docs/reports/ に報告を書く（テンプレートは非公開側の docs/reports/README.md）。オーナーはこれで判断する。
- 機能開発・仕様変更は `ghostpace-dev` スキルの流れで進める（グローバルの spec-dev は使わない）。レビュー（review-3）の観点は `.claude/rules/review-checklist.md` を優先する。動作確認は `verify-ios` スキルに従う。実機でしか確認できない項目は報告にオーナー向け手順として書く。
- 未決事項は勝手に決めず、非公開側の docs/owner/open-questions.md に追記する。公開側の docs では「Q33（非公開の判断表）」のように番号だけ書く。

## 設計ルール
- IDはUUID、時刻はUTCで保存しタイムゾーンを別に持つ。日付境界は4:00（docs/decisions/0005）。
- 現在時刻は注入可能なClock（`AppClock`）経由で取得する（Date()の直接呼び出し禁止。例外は`SystemClock`のみ）。テストとデモデータのため。
- データアクセスはRepository層経由。ViewからSwiftDataを直接触らない。
- 画面の文言は String Catalog に集め、英語に訳せる形にする（ADR-0016、NFR-06）。今ある画面も触るついでに移す
- `*.xcodeproj` は生成物。直接編集せず `project.yml` を編集して `xcodegen generate`。
- 証明書・プロビジョニングプロファイル・秘密情報はコミットしない。

## コマンド
- 生成: `xcodegen generate`
- ビルド・シミュレーター操作: XcodeBuildMCP を使う（既定: iPhone 18 Pro シミュレーター、`.xcodebuildmcp/config.yaml`）
- テスト: `scripts/test.sh` だけで回す（Mac 全体の順番待ち。同時に2つまで。バックグラウンドで実行）。PR では `scripts/test.sh ui <関係する UI テスト>`、UI テストの全件は `scripts/testflight.sh` が送る前に回す（ADR-0020）。`xcodebuild test` と `test_sim` はフックで止まる
- 実機（オーナーの iPhone）へ直接入れる手順と UDID は、非公開側の CLAUDE.md にある（下で読み込む）
- 署名: project.yml の `DEVELOPMENT_TEAM` のチーム
- TestFlight に送る: main で `scripts/testflight.sh`（ADR-0011。先に UI テストを全件回し、失敗したら送らない）。`--no-upload` で署名と書き出しだけ確認。画面や動きが変わる PR をマージしたら送る

## 詳細
- 全体像: docs/README.md
- アーキテクチャ: docs/design/architecture.md
- iOSの制約（Screen Time API）: docs/design/ios-constraints.md

## この Mac だけの情報（非公開）
@~/Desktop/focus-app-private/CLAUDE.md
