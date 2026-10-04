---
status: draft
---
# アーキテクチャ

主な読者はClaude。オーナー向けの要点は冒頭のみ。

## 要点（オーナー向け）
- iPhone専用のネイティブアプリ。データは端末内に保存し、オフラインで動く
- アプリ本体と、ブロック用の小さな拡張機能3つ、ロック画面と画面上部にタイマーを出す拡張機能1つで構成される（2026-10-01 から）
- 後からサーバー同期やNotion連携を足せるよう、データの読み書きを1か所に集めている

## 構成
```
App（SwiftUI） … ターゲット名・フォルダ名は FocusApp、表示名は GhostPace
├── App/             起動（AppLauncher：保存先を開く）、AppModel（画面の状態と操作）、ContentView
├── Features/        画面ごと（Home, Plan, Timer。今後 Timeline, Review, Settings）
├── Domain/          純粋なロジック。UI・永続化に依存しない
│   ├── DayBoundary      日付境界の計算
│   ├── FocusSession     一時停止・残り時間・止め忘れの判定・終了時刻の決め方
│   ├── GhostRace        時間の区間、先週の記録を今日に揃える計算
│   ├── PlanSnapshot     計画の状態と確定時の写し
│   └── （今後）PlanVsActual 予実比較
├── Data/
│   ├── Schema.swift     保存データの形（SchemaV1 と MigrationPlan、data-model.md）
│   ├── Repositories/    プロトコル（画面と AppModel が依存するのはここだけ）
│   ├── SwiftData/       Repositoryの実装（SwiftDataStore）
│   └── DemoData.swift   検証用のデモデータ（Release にも含まれるが、起動引数は Debug でしか読まないので使われない）
└── Shared/          Clock、起動引数、テーマなど

Extensions（2026-10-01 から。ターゲット名は BlockMonitor / BlockShield / BlockShieldAction）
├── DeviceActivityMonitor   開けた時間が終わったらブロックに戻す、記録
├── ShieldConfiguration     シールドの見た目（先週の自分との差）、「シールドが出た」の記録
└── ShieldAction            「開く」で通知を出し、開くを押した時刻を残す

Extensions/TimerActivity（2026-10-01 から、TMR-06）
└── TimerActivityWidget     ロック画面と画面上部（Dynamic Island）のタイマー（Live Activity）。見るだけ

Shared/LiveActivity（本体と TimerActivity の両方に入るコード）
├── TimerActivityAttributes  表示に渡す値（名前・見出し・数字の時刻・進み具合）
└── TimerActivityViews       ロック画面・画面上部の部品。数字は iPhone が時刻から数える（アプリを開かなくても進む）
本体の Domain/TimerActivity が実行中のセッションから値を作り、Data/LiveActivity（ActivityKit）が出し入れする。AppModel の reload のたびにそろえる

Shared/Blocking（本体と拡張の両方に入るコード）
├── BlockPolicy             長押しの秒数・開ける長さの範囲・今ブロック中かの計算（純粋なロジック）
├── BlockState / BlockEventLog  App Group に置く状態と記録（JSON）
└── ShieldRaceSnapshot      シールドに出す差の材料（本体が保存のたびに書き、拡張がその時刻の分まで計算）

App Group（group.com.hirototoda.focusapp）
└── 本体と拡張の間でデータを受け渡す（ブロック対象の選択、開けている期限、記録、差の材料）
```

## 方針
- **Domainは純粋関数中心**：ゴースト計算・日付境界・予実比較はユニットテストで網羅する。オーナーがコードを読まないため、正しさはテストで担保する
- **Clock注入**：現在時刻は`AppClock`プロトコル経由（Swift標準の`Clock`と名前が衝突するため）。SwiftUIでは`@Environment(\.clock)`で受け取る。テストとシミュレーター検証で任意の時刻を再現できる
- **データの流れ**：画面 → AppModel → Repository（プロトコル）→ SwiftDataStore。画面から SwiftData を直接触らない（ADR-0002）。保存に失敗したら取り消して「保存できませんでした」を出す（[ADR-0012](../decisions/0012-uuid-references-json-fields.md)）
- **起動引数（Debug ビルドのみ）**：時間の再現とデモデータのため
  - `-fixedNow 2026-10-19T14:30`：その時刻から**実時間と同じ速さで進む**時計にする（タイマーの動作も確認できるように）。タイムゾーン省略時は端末のタイムゾーン。`+09:00` のように付けてもよい
  - `-seedDemoData [場面]`：メモリ内のストアに過去21日分と今日のデータを入れる（本物のデータに触れない）。場面は day（既定）／morning／noplan／running／forgot／firstweek。起動すると画面上に「見本 ▾」メニューが出て、場面を切り替えられる
  - `-inMemoryStore`：空のメモリ内ストア。`-storeName <名前>`：別名のファイル（UI テストで再起動をまたぐ確認に使う）。`-resetStore`：開く前にそのファイルを消す
  - `-failSave`：保存を毎回失敗させる。`-failStoreOpen`：ストアを開けなかったことにする（画面の確認用）
- **テスト**：ロジックと保存は Swift Testing（メモリ内ストア）。再起動をまたぐ流れは XCUITest（`FocusAppUITests/RecordingFlowUITests`）。テストは `scripts/test.sh` で、Mac 全体の順番待ちに並んで回す（docs/verification/strategy.md「テストの回し方」）。報告用のスクリーンショットは `ScreenTourUITests` を `scripts/test.sh tour` で（環境変数 `SCREEN_TOUR=1` 付きで）実行して撮る（普段はスキップ）。実機で本物の時計を使う確認 `testRunningTimerSurvivesRealWaitClosed` は `TEST_RUNNER_REAL_WAIT=1 xcodebuild test -destination 'id=<UDID>' …` で実行する（待ち時間は画面の自動ロックより短い90秒）
- **プロジェクト生成**：XcodeGen（[ADR-0003](../decisions/0003-xcodegen.md)）
- **拡張性**：Repositoryの裏に同期層を足せば段階4に対応できる。全エンティティにUUIDと更新日時を持たせる

## 技術選定
| 項目 | 選定 | 理由 |
|---|---|---|
| UI | SwiftUI | Screen Time APIの拡張と相性が良い（[ADR-0001](../decisions/0001-ios-native-swiftui.md)） |
| 永続化 | SwiftData | 標準、ローカルファースト（[ADR-0002](../decisions/0002-local-first-swiftdata.md)） |
| テスト | Swift Testing ＋ XCUITest | ロジックとUIの両方を自動検証 |
| 検証 | XcodeBuildMCP | ビルド・シミュレーター操作・スクショをClaudeが実行（[ADR-0007](../decisions/0007-verification.md)） |
