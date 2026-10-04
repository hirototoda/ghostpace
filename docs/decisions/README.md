# 設計判断の記録（ADR）

重要な判断を1件1ファイルで残す。覆すときは新しいADRを作り、古いものを `superseded` にする。

| 番号 | 判断 | 状態 |
|---|---|---|
| [0001](0001-ios-native-swiftui.md) | iPhoneネイティブ（SwiftUI）で作る | draft |
| [0002](0002-local-first-swiftdata.md) | ローカルファースト、SwiftData＋Repository層 | draft |
| [0003](0003-xcodegen.md) | Xcodeプロジェクトは XcodeGen で生成する | draft |
| [0004](0004-unlock-always-allowed.md) | ブロック解除は常に許可し、記録のみ | superseded（0013） |
| [0005](0005-day-boundary-4am.md) | 日付境界は4:00 | draft |
| [0006](0006-docs-as-source-of-truth.md) | ドキュメントを唯一の仕様とする | draft |
| [0007](0007-verification.md) | 検証はClaudeがシミュレーターで行い、実機専用項目のみオーナー | draft |
| [0008](0008-personal-first-publish-later.md) | まず自分用に作り、手応えがあれば公開を検討する | draft |
| [0009](0009-reclaimed-time-no-measurement.md) | 取り戻した時間はタイマー時間で数え、SNS使用時間は測らない | draft（デトックスの部分は 0014 で置き換え） |
| [0010](0010-auto-merge.md) | テストが通れば Claude が PR を自動でマージする | draft |
| [0011](0011-testflight.md) | iPhone への配布は TestFlight で行う | draft |
| [0012](0012-uuid-references-json-fields.md) | 保存データは UUID で参照し、版番号つきのスキーマで始める | draft |
| [0013](0013-hold-to-unlock.md) | ゲームと SNS はいつもブロックし、開くには長押しと待ちを挟む | draft |
| [0014](0014-detox-is-blocked-time.md) | デジタルデトックスは、ブロックが効いていた時間で数える（0009 のデトックスの部分を置き換え。画面に出す数字は 0018 で置き換え） | draft |
| 0015 | 無料で始められ、続きは年額か買い切りで売る（売り方の判断なので非公開の focus-app に置く） | draft |
| [0016](0016-localizable-strings.md) | 画面の文言を今から翻訳できる形にする | draft |
| [0017](0017-community-race.md) | 知らない人や友達とも対戦できるようにする（ビジョンの「やらないこと」を改める） | draft |
| [0018](0018-show-opened-time.md) | 画面にはデトックスの時間ではなく「開けた時間」を出す（0014 の表示の部分を置き換え） | draft |
| [0019](0019-points-diminishing-returns.md) | ポイントは、やりすぎると1分の価値が下がり、開けるほど1回が重くなる形で数える（続けたボーナスをなくす。0014 の睡眠・1.5倍と 0018 のご褒美の部分を置き換え） | draft |
| [0020](0020-test-queue.md) | テストは Mac 全体の順番待ちで回し、UI テストの全件は TestFlight に送る前に回す | draft |

## テンプレート
```
---
status: draft
date: YYYY-MM-DD
---
# NNNN. タイトル
## 背景
## 決定
## 理由
## 影響・トレードオフ
```
