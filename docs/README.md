# ドキュメント案内

オーナーはコードを読まない。このフォルダ（仕様）と、非公開のリポジトリ focus-app（報告・判断待ちの事項・売り方）だけで、仕様の確認・判断・受け入れができる状態を保つ。

## 状態の見方
各ファイル冒頭の `status` で判断する。
- `draft`：Claudeが作成。オーナー未確認
- `approved`：オーナー確認済み。これを正として実装する
- `superseded`：新しい決定に置き換え済み

## 目的別の読む場所

| やりたいこと | 読む場所 |
|---|---|
| 自分がやるべき作業を知る | 非公開の focus-app の docs/owner/checklist.md |
| 判断待ちの事項に答える | 非公開の focus-app の docs/owner/open-questions.md |
| アプリの目的・方針を確認する | [product/vision.md](product/vision.md) |
| 何を作るかを確認する | [product/requirements.md](product/requirements.md) と [product/features/](product/features/) |
| 似たアプリとの比較を見る | 非公開の focus-app の docs/product/research/ |
| 公開・価格・売上の見込みを見る | 非公開の focus-app の docs/business/ |
| 開発の進み具合を知る | [plan/roadmap.md](plan/roadmap.md) と、非公開の focus-app の docs/reports/ |
| 完成したかを確認する | [verification/acceptance/](verification/acceptance/) |
| なぜそう決めたかを知る | [decisions/](decisions/README.md) |

## フォルダ構成
```
docs/
├── product/        何を作るか（ビジョン、要件、機能別仕様、用語集）
├── design/         どう作るか（アーキテクチャ、データモデル、iOSの制約）
├── decisions/      設計判断の記録（ADR）
├── plan/           ロードマップ
└── verification/   検証方針と受け入れ基準

非公開の focus-app（このリポジトリには入れない）
├── docs/owner/             オーナーの作業・判断事項（open-questions・checklist）
├── docs/business/          誰に・いくらで・どう届けるか（公開と売り方）
├── docs/product/research/  似たアプリと価格の調査
└── docs/reports/           Claudeの作業報告（スクリーンショット付き）
```
仕様の画面の画像（案の比較など）は `product/assets/` に置く（見本データのシミュレーター画面だけ）。

`design/` はClaude向けの内容が多い。オーナーが読まなくても判断に困らないよう、判断が必要な点は `product/` と `decisions/` に書く。
