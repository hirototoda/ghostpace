---
status: draft
date: 2026-09-30
requirements: [PLN-01, PLN-02, PLN-03, PLN-04, PLN-05, CAT-01, CAT-02, CAT-03, TMR-01, TMR-02, TMR-03, TMR-04, TMR-07, TMR-08, GHO-01, GHO-02, GHO-03, NFR-01, NFR-02]
---
# 仕様書：記録のしくみ（段階1a）

主な読者は Claude。オーナー向けの要点は冒頭のみ。

## 要点（オーナー向け）
- これまでのホーム・タイマー・朝の計画は見本の数字を出していただけで、何も保存していなかった。この作業で**端末に保存**し、毎日使えるようにする
- 保存するのは「カテゴリ」「ブロック名」「1日の計画」「計画ブロック」「タイマーの記録」の5種類。項目は [data-model.md](../design/data-model.md)
- アプリを閉じても、タイマーは動き続けているものとして正しく数える（TMR-02）
- 保存データの形を決める作業なので、**data-model.md をオーナーに確認してもらってからマージする**（[ADR-0010](../decisions/0010-auto-merge.md) の例外）
- 決定（2026-09-30）
  - 一時停止中、計画ブロックから始めたカウントダウンはブロックの終わりに合わせて減り続ける。計画外で長さを決めたものは止まる
  - 一時停止を除いて1分未満のセッションは記録しない（「1分未満なので記録しませんでした」と出す）
  - 止め忘れの救済：終了を押したとき、予定を30分以上超過／ストップウォッチで3時間超／朝4:00をまたいだ のどれかなら「実際にやめた時刻」を聞く

## 背景・目的
- ロードマップ段階1a（記録MVP）の中心。「10/12頃から毎日使い始める」ための前提
- 1b（対戦）は溜まった記録から作るので、記録の形がここで決まる
- 前回（PR #4）でホーム・タイマー・朝の計画の見た目と操作は決定済み。今回は見た目をほぼ変えず、中身を実データにする

## スコープ
1. SwiftData のモデル（5種類）と、最初から版番号つきのスキーマ（VersionedSchema V1 ＋ MigrationPlan）
2. Repository 層（プロトコル＋SwiftData 実装）。View から SwiftData を直接触らない
3. 初回起動時にデフォルトカテゴリ（CAT-01）を保存する
4. 朝の計画：今日の計画がなければ全画面で出す（PLN-01）。下書きの自動保存、確定（スナップショット、PLN-03）、スキップ（PLN-05）
5. 計画の変更（PLN-04）：変更を保存し、消したブロックは削除の印をつけて残す。スナップショットは変えない
6. ブロック名（プロジェクト）をその場で作ると保存する（CAT-03）
7. タイマー：開始・一時停止・再開・終了を保存（TMR-01, 03, 04, 07）。起動時に実行中のセッションがあればタイマー画面を戻す（TMR-02）
8. ホームの数字（今日の集中・デトックス、今／次のブロック）を実データから計算する。集中に数えないカテゴリ（CAT-02 の値）は集中に入れない
9. 先週の同じ曜日の記録があれば、対戦表示（リングの内側と差）を実データから出す（home.md「データの有無で切り替え」の実装。1b の勝敗記録 GHO-04 はしない）
10. 止め忘れの救済：長いときだけ終了時刻を聞く（TMR-08 のうち「終了時に早める」部分）
11. デモデータ（`-seedDemoData <場面>`）と、DEBUG の「見本 ▾」メニューを実データ版に置き換える
12. UI テストのターゲットを追加し、主要フローを自動で確認する

## 非スコープ（やらないこと）
| 項目 | 理由・いつやるか |
|---|---|
| 予定時間に達したときの通知（TMR-05） | 次の PR（小さいので分ける）。実機確認が必要 |
| 終了後にタイムラインから終了時刻を早める画面（TMR-08 の残り） | タイムライン画面の PR。今回は終了時の救済だけ |
| タイムライン・夜の振り返り・設定（CAT-02 の切り替え画面、ブロック名の名前変更・アーカイブ） | それぞれ別 PR |
| ShieldEvent のモデル | 段階2で追加する。DailyReview は作らない（夜の振り返りはメモを取らない、2026-10-01） |
| iCloud 同期 | 段階4。今回は `cloudKitDatabase: .none` |
| バックアップ（ファイル書き出し） | ADR-0002 のとおり段階3で検討。それまで端末故障で記録を失う可能性は残る |
| 夏時間・旅行でタイムゾーンが変わる日の対戦の揃え | 既知の制限（日本では起きない）。日付は保存済みの dayKey で引くので記録自体は壊れない |

## 変更内容

### 1. データモデル（`FocusApp/Data/Schema.swift`）
- `enum SchemaV1: VersionedSchema`（version 1.0.0）に5つの `@Model` を置き、`typealias CategoryRecord = SchemaV1.CategoryRecord` などで外から使う
- `enum AppMigrationPlan: SchemaMigrationPlan`（schemas = [SchemaV1]、stages = []）。以後の変更は V2 と stage を足す
- **エンティティ間は UUID で参照し、`@Relationship` は使わない**。理由：data-model.md が UUID 参照で書かれている／スナップショットや段階4の同期で ID をそのまま運べる／関連の削除ルールで記録が消える事故を避ける（NFR-02）。ADR-0012 に残す
- `@Attribute(.unique)` は付けない（段階4の同期で制約になるため）。重複は Repository で防ぎ、読むときは決定的に1つ選ぶ（下記）
- `PersistentModel` がすでに持つ名前（`isDeleted` など）は使わない
- 全モデル共通：`id: UUID`、`createdAt: Date`、`updatedAt: Date`（Clock から）

| モデル | 項目（共通以外） |
|---|---|
| CategoryRecord | name, countsAsFocus, sortOrder, isArchived |
| ProjectRecord | name, categoryId, isArchived |
| DailyPlanRecord | dayKey, timeZoneId, statusRaw（draft / confirmed / skipped）, confirmedAt?, snapshotJSON?（Data） |
| PlanBlockRecord | planId, startAt, endAt, categoryId, projectId?, isRemoved |
| FocusSessionRecord | dayKey, timeZoneId, planBlockId?, categoryId, countsAsFocus（開始時の値、2026-09-30 決定）, projectId?, startAt, endAt?, plannedEndAt?, plannedDurationSec?, pausesJSON（Data）, originalEndAt?, note? |

- 状態は `String` の raw 値で保存する。**知らない値は confirmed（読み取り専用）として扱う**。朝の計画に出さず、上書きもしない（将来の版で書いた値を壊さないため）
- 数え方（カウントダウン／ストップウォッチ）は保存せず、`plannedEndAt`・`plannedDurationSec` から決める（二重に持つと食い違うため）
  - 計画ブロックから開始：`plannedEndAt` ＝ ブロックの終了時刻。一時停止しても動かない
  - 計画外で長さを決めた：`plannedDurationSec` ＝ 長さ。一時停止した分だけ終わりが後ろにずれる
  - ストップウォッチ：どちらも nil
- 一時停止は `[PauseInterval]`（start, end?）を JSON にして `pausesJSON` に入れる（Codable 配列の SwiftData 保存は版による挙動差があるため避ける）。読めない JSON は空配列として扱い、記録そのものは読める
- スナップショット（PLN-03）：`[PlanSnapshotBlock]`（blockId, startAt, endAt, categoryId, categoryName, projectId?, projectName?）の JSON。名前も残すのは、後でカテゴリ名を変えても朝の計画が読めるようにするため

### 2. ドメイン（`FocusApp/Domain/`、純粋な値と計算）
- `CategoryOption` に `id: UUID` を足し、同一性は id で判定する。`ProjectOption` にも `id` を足す
- `DefaultCategories.all` は初期データの元として残す（UUID は初回保存時に採番）
- `CategoryOption.unknown`：参照先のカテゴリが見つからないときの代わり（名前「不明」、集中に数えない）。記録は消さない
- `FocusSession`（値型）：id, category, project?, planBlockId?, startAt, endAt?, plannedEndAt?, plannedDurationSec?, pauses, originalEndAt?
  - `activeSeconds(at:)`：開始から（終了または now）までから一時停止を除いた秒数。now が開始より前なら0
  - `activeSegments(until:) -> [TimeSegment]`：一時停止で区切った区間。ホームの集計と対戦の曲線はこれで計算する
  - `isPaused`、`pauseCount`（＝中断回数、TMR-03）、`isCountdown`
  - `plannedEnd(at:)`：`plannedEndAt` があればそれ。`plannedDurationSec` があれば「開始＋長さ＋一時停止の合計（進行中の停止は now まで）」。どちらもなければ nil
  - `remainingSeconds(at:)`：`plannedEnd(at:) − now`（マイナスは超過）
  - `needsEndTimeCheck(at:calendar:)`：止め忘れの疑い。超過が30分以上／ストップウォッチで一時停止を除き3時間超／開始した日の翌日4:00を過ぎている、のどれか
  - `ending(at:reportedEnd:)`：終了した値を作る。`reportedEnd` は開始より後、now 以下でなければエラー（now ちょうどは可、開始ちょうどは不可）
    - `reportedEnd` が now より前なら `originalEndAt = now`（TMR-08）。now なら nil
    - **セッションは一時停止の途中では終わらない**：終わりが一時停止の中（停止中に今で終える場合を含む）なら、その停止の開始を終了にし、その停止は捨てる（中断に数えない）
    - 終了より後に始まった停止は捨てる
- `RunningTimer` は `FocusSession` ＋ `focusSecondsBefore` ＋ `ghost` を持つ形にし、経過・残り・差の計算は `FocusSession` に任せる
- `HomeSnapshot.make(now:calendar:todaySessions:plan:lastWeekSessions:categories:reviewTime:)`：実データからホームの表示を作る
  - 今日＝`dayKey` が今日のセッション（4:00 をまたいだセッションは開始した日に入る。data-model.md のとおり）
  - 先週＝`calendar.date(byAdding: .day, value: -7, to: dayStart)` の `dayKey` のセッション。`dayStart` からの経過時間で今日に揃える（GHO-02）。経過が24時間を超える部分は切る。0件なら `ghost = nil`（1重の円、GHO-03）
  - 計画ブロックは削除の印がないもの。計画がスキップなら `isNoPlanDay = true`

### 3. Repository（プロトコル `FocusApp/Data/Repositories/`、実装 `FocusApp/Data/SwiftData/`）
プロトコル（すべて `@MainActor`）と、それを1つで満たす `SwiftDataStore`（`ModelContext` と `AppClock` を持つ）。

| プロトコル | メソッド |
|---|---|
| CategoryRepository | `seedDefaultsIfNeeded()`、`categories()`（アーカイブ以外・並び順。選ぶ画面用）、`allCategories()`・`allProjects()`（アーカイブを含む。記録を読む用）、`projects()`、`createProject(name:category:)` |
| PlanRepository | `plan(dayKey:) -> StoredPlan?`、`saveDraft(_:dayKey:)`、`confirm(_:dayKey:)`、`skip(dayKey:)`、`saveChanges(_:dayKey:)`、`snapshot(dayKey:)` |
| SessionRepository | `runningSession()`、`start(_:)`、`pause(id:)`、`resume(id:)`、`end(id:reportedEnd:) -> EndResult`、`sessions(dayKey:)` |

- `StoredPlan` は状態（`PlanStatus`）と、既存の `PlanDraft` を持つだけの小さな型（新しい編集用の型は作らない）
- `seedDefaultsIfNeeded`：カテゴリが**アーカイブを含めて**0件のときだけ CAT-01 の7つを保存する
- `createProject`：前後の空白を除き、空なら nil。同じカテゴリに同じ名前（アーカイブ以外）があればそれを返す
- 計画の状態ごとに許す操作

| 今の状態 | saveDraft | confirm | skip | saveChanges |
|---|---|---|---|---|
| なし | draft を作る | confirmed を作る | skipped を作る | エラー |
| draft | 更新（消したブロックは物理削除） | confirmed にする | skipped にし、下書きのブロックは物理削除 | エラー |
| confirmed | 何もしない | 何もしない（スナップショットは上書きしない、PLN-03） | エラー | 更新（消したブロックは `isRemoved`） |
| skipped | 何もしない | confirmed にする（計画なし日にあとから計画を作る、2026-09-30 決定） | 何もしない | エラー |

- `start`：実行中のセッションがあれば `RecordError.alreadyRunning`（同時に動くタイマーは1つ）。`dayKey` は開始時刻から、`timeZoneId` はそのときの端末のタイムゾーン
- `pause`／`resume`：すでに止まっている／動いているなら何もしない（二重タップで壊れない）。終了済みなら何もしない
- `end`：`FocusSession.ending` で終了を決める。一時停止を除いて60秒未満なら**レコードを消して** `.discardedTooShort`、それ以外は `.saved`。終了済みなら何もせず `.saved`。id がなければ `RecordError.notFound`
- 重複の読み方：同じ `dayKey` の計画が複数あれば `updatedAt` が新しいもの、実行中が複数あれば `startAt` が新しいもの
- 変更は各メソッドの中身を `write { }` で包み、最後にまとめて保存する（テストと DEBUG の `-failSave` で失敗させられるよう差し替え口 `saveHook` を持つ）。途中の読み出しの失敗も含め、失敗したら `context.rollback()` して throw する。画面は「保存できませんでした」と出し、状態は保存前に戻る（終了に失敗したらタイマー画面のまま、もう一度押せる）

### 4. アプリ（`FocusApp/App/`）
- `FocusApp`：起動時に `ModelContainer` を作る
  - 通常：端末内の既定の場所（Application Support の `default.store`）。`AppMigrationPlan` を使う
  - DEBUG で `-seedDemoData [場面]` または `-inMemoryStore`：メモリ内（本物のデータに触れない）
  - DEBUG で `-storeName <名前>`：別名のファイル（UI テストで再起動をまたぐ確認に使う）。`-resetStore` でそのファイルを消してから開く
  - DEBUG で `-failStoreOpen`：開けなかったときの画面を撮るために、わざと失敗させる。`-failSave`：保存を毎回失敗させる
  - 開けなかったとき：**ファイルを消さずに**「記録を開けませんでした」の画面を出す。内容は「記録は消していません」、エラーの要約、「もう一度試す」ボタン（NFR-02）
- `AppModel`（`@Observable @MainActor`）：Repository・Clock・タイムゾーンの取得元（`() -> TimeZone`、既定は `TimeZone.current`。テストで差し替える）を持ち、画面が使う状態を作る
  - 状態：`snapshot: HomeSnapshot`、`running: RunningTimer?`、`plan: PlanDraft?`（nil＝計画なし日）、`morningPlan: MorningPlan?`（出すときだけ。dayKey と dayStart を持つ）、`projects`、`categories`、`notice: String?`（短い知らせ）、`errorMessage: String?`
  - `reload()`：そのときの端末のタイムゾーンで Calendar を作り直し、今日の `dayKey` で読み直す。朝の計画を出すのは、今日の計画がない、または下書きのとき。ただし実行中のタイマーがあればタイマーを優先し、終了後に出す
  - 朝の計画は開いた時点の `dayKey` と `dayStart` を持ち続ける。編集中に4:00を過ぎても、その日の計画として保存する（3:55 に開いた計画は前日のもの）。確定して閉じた後の `reload()` で、新しい日の計画がなければもう一度出る
  - 計画の変更はタイマー画面の裏になるので、実行中には開けない。実行中セッションの `planBlockId`・`plannedEndAt` は開始時の値のまま（ブロックを消しても `isRemoved` の行が残るので参照は切れない）
  - 操作：`startPlanned(block:)`、`startUnplanned(category:minutes:)`、`pause()`、`resume()`、`requestEnd()`、`end(reportedEnd:)`、`saveDraft(_:)`、`confirmPlan(_:)`、`skipPlan()`、`savePlanChanges(_:)`、`createProject(name:category:)`
  - `requestEnd()`：`needsEndTimeCheck` なら終了時刻の確認を出す。そうでなければすぐ `end`
  - 普通の終了は `end(reportedEnd: nil)`（保存する瞬間の時刻で終える。先に読んだ時刻を渡すと、わずかな差で「早めた」印が付いてしまうため）
  - `end` の結果が `.discardedTooShort` なら `notice` に「1分未満なので記録しませんでした」を入れ、ホームの上に2秒出す
  - 再計算のきっかけ：起動、前面に戻ったとき（scenePhase が active）、各操作の後、ホーム表示中は1分ごと。前面に戻ったときと1分ごとは読み出しに失敗してもアラートを出さない
  - `openPlanOnNoPlanDay()`：計画なし日にホームの「計画なし ›」から朝の計画画面を開く。閉じれば（skip は何もしない）計画なしのまま
- `ContentView`：`SampleHome` を消し、`AppModel` から `HomeView`・`DailyPlanView`・`TimerRunningView` を出す
- `HomeView`：`running` と開始シートの状態を自分で持たず、開始・終了は `AppModel` に頼む（引数をクロージャにする）。見た目は変えない
- `TimerRunningView`：一時停止・再開・終了を `AppModel` に頼む。一時停止中は円の中の見出しを「一時停止中」にする。数字は、計画外なら止まり、計画ブロックなら減り続ける（ブロックの終わりを過ぎたら超過）
- `EndTimeSheet`（新規・小さなシート）：題「いつやめましたか？」、説明「◯:◯◯ に開始してから ◯時間◯分たっています」、時刻の選択（開始〜今。初期値は予定の終了時刻、なければ今）、ボタン「この時刻で終了」。閉じると終了しない（タイマー画面に戻る）
- `DailyPlanView`：朝のモードでは計画が変わるたびに `saveDraft` を呼ぶ。カテゴリ・ブロック名は `AppModel` から受け取る
- `BlockEditorSheet`・`StartSheet`：`DefaultCategories.all` の直接参照をやめ、保存されたカテゴリの一覧を受け取る
- 各ボタンは処理中に二重に押せないようにする

### 5. デモデータ・検証用の起動引数（`FocusApp/Shared/`）
- `-seedDemoData [場面]`：メモリ内のストアに、Clock の今を基準に作る。乱数は使わず日付から決まる値にする。次の引数が場面名のときだけ場面として読む（`-seedDemoData -fixedNow …` を誤読しない）

| 場面 | 過去21日分 | 今日 |
|---|---|---|
| day（既定） | あり | 確定した計画＋今の時刻までのセッション |
| morning | あり | なし（朝の計画が出る） |
| noplan | あり | スキップ＋セッション少し |
| running | あり | day と同じ＋今の計画ブロックから23分前に開始した実行中のセッション（計画ブロックがなければ計画外25分） |
| forgot | あり | day と同じ＋5時間前に計画外25分で開始したまま実行中（止め忘れ） |
| firstweek | なし | day と同じ（先週がないので1重の円） |

- `-homeScene`・`-ghost` は廃止（実データで再現できるため）
- DEBUG の「見本 ▾」メニュー：`-seedDemoData` で起動したときだけ出す。場面を選ぶとメモリ内のストアを作り直して入れ直す。実データで使うときは出ない

### 変更ファイル一覧
| 区分 | ファイル |
|---|---|
| 追加 | `FocusApp/Data/Schema.swift`, `FocusApp/Data/Repositories/Repositories.swift`, `FocusApp/Data/SwiftData/SwiftDataStore.swift`, `FocusApp/Data/DemoData.swift`, `FocusApp/Domain/FocusSession.swift`, `FocusApp/Domain/PlanSnapshot.swift`, `FocusApp/App/AppModel.swift`, `FocusApp/Features/Timer/EndTimeSheet.swift`, `FocusAppUITests/RecordingFlowUITests.swift`, `FocusAppUITests/ScreenTourUITests.swift` |
| 変更 | `FocusApp/App/FocusApp.swift`, `FocusApp/App/ContentView.swift`, `FocusApp/Features/Home/HomeView.swift`, `FocusApp/Features/Home/HomeSnapshot.swift`, `FocusApp/Features/Timer/*.swift`, `FocusApp/Features/Plan/*.swift`, `FocusApp/Shared/DefaultCategories.swift`, `FocusApp/Shared/LaunchOptions.swift`, `project.yml`（UI テストのターゲット）, 既存テスト |
| 移動 | `FocusApp/Shared/DayBoundary.swift` → `FocusApp/Domain/`（architecture.md の構成に合わせる） |
| 削除 | `FocusApp/Features/Home/HomeSample.swift`, `FocusApp/Shared/DemoDataSeeder.swift`（`DemoData` に置き換え） |
| docs | `docs/design/data-model.md`（項目名・`plannedEndAt`・数え方の導出・`isRemoved`）, `docs/design/architecture.md`（構成図・起動引数）, `docs/decisions/0012-uuid-references-json-fields.md`（新規）, `docs/product/features/focus-timer.md`（一時停止・1分未満・止め忘れ）, `docs/product/features/daily-plan.md`（下書きの自動保存・計画なし日）, `docs/product/features/home.md`（1分未満の知らせ）, `docs/owner/open-questions.md`（決定済み表）, `docs/verification/acceptance/phase-1a.md`, `.claude/skills/verify-ios/SKILL.md`（撮影の起動引数）, `docs/reports/2026-09-30-recording.md` |

## 既存機能への影響・移行
- 保存データは今まで存在しないので、移行するデータはない。今回が SchemaV1
- 以後スキーマを変えるときは V2 と MigrationPlan の stage を足し、V1 のデータが読めることをテストする（NFR-02）
- 起動引数 `-homeScene`・`-ghost` を使った撮影手順（前回の報告）は、`-seedDemoData <場面>` と `-fixedNow` に置き換わる
- 見た目は変えない（増えるのは「一時停止中」の見出し、終了時刻の確認シート、1分未満の知らせ、開けなかったときの画面）。前回のスクリーンショットと並べて差がないことを確認する

## この PR で確認する受け入れ基準
- 確認する：1a-1, 1a-2（保存まで）, 1a-3, 1a-4, 1a-5（シミュレーター。実機はオーナー）, 1a-7, 1a-9（増えた画面）, 1a-11, 1a-12, 1a-13（終了時の救済のみ。タイムラインからは後の PR）
- しない：1a-6（通知、次の PR）, 1a-8（振り返り）, 1a-10（オーナーが実機で丸1日）

## UI 導線
新しい画面は、終了時刻の確認シートと、開けなかったときの画面だけ。どちらも自動で出る。
- 朝の計画：起動時／前面に戻ったとき、今日の計画がなければ自動で全画面
- 計画の変更：ホームの「今：〜 ›」
- タイマー：ホームの開始ボタン。実行中にアプリを閉じても、開けばタイマー画面に戻る
- 保存に失敗したとき：その画面の上にアラート「保存できませんでした」

## 操作台本
各行は「押す → その瞬間に見えるもの → 保存されるもの」。ラベルは現在の画面の文言。

### A. 朝の計画（初めて使う日、9:10 に起動）
1. アプリを開く → 全画面「今日の計画」、案内文、「この計画で始める」は押せない → カテゴリ7つ（初回のみ）
2. 「ブロックを追加」 → シート「ブロックを追加」。何をする＝勉強、開始 09:10、長さ 1時間 → なし
3. 勉強の行の「＋」 → 「新しいブロック名」、「ゼミ準備」と入れて「作成」 → ゼミ準備が選ばれた状態 → Project（ゼミ準備、勉強）
4. 「追加」 → シートが閉じ、一覧に「ゼミ準備 09:10–10:10 1時間」、上の合計「集中 1時間」 → DailyPlan（draft）＋PlanBlock 1件
5. （アプリを落として開き直す）→ 同じ「今日の計画」にゼミ準備のブロックが残っている → 変化なし
6. 「この計画で始める」 → 計画画面が閉じ、ホーム下に「今 ゼミ準備 09:10–10:10 ›」、ボタン「ゼミ準備を開始」 → DailyPlan が confirmed、confirmedAt とスナップショット
7. 開き直す → 計画画面は出ずホーム → 変化なし

### B. 計画しない日
1. 朝の計画で「今日は計画しない」 → ホーム、下に「計画なし ›」、ボタン「カテゴリを選んで開始」 → DailyPlan（skipped）
2. 開き直す → 計画画面は出ない
3. 「計画なし ›」 → 「今日の計画」が全画面で開く。「今日は計画しない」で閉じれば計画なしのまま／ブロックを入れて「この計画で始める」なら確定（スナップショットもこの時点のもの） → skipped のまま／confirmed

### C. 計画の変更（10:30、ブロック2つ）
1. ホームの「今：〜 ›」 → シート「計画を変更」、下に「朝に確定した計画は、振り返りのためにそのまま残ります。」
2. 2つめのブロックを左にスワイプして削除 → 一覧から消える → なし
3. 「保存」 → シートが閉じ、ホームの「次」が変わる → そのブロックは `isRemoved`、スナップショットは2つのまま

### D. 計画ブロックから開始して終える（ゼミ準備 09:10–10:10 を 09:20 に開始）
1. 「ゼミ準備を開始」 → 全画面のタイマー、「残り 50:00」、「09:20 開始・10:10 終了予定」 → FocusSession（endAt なし、planBlockId あり、plannedEndAt=10:10）
2. 「一時停止」（09:30） → ボタンが「再開」、見出しが「一時停止中」。残りは減り続ける → pauses に start のみ
3. 「再開」（09:35） → ボタンが「一時停止」、見出しが「残り」 → pauses の end が入る
4. 「終了」（09:50） → ホームに戻り、円の中の今日の集中が 25分 増えている（30分−停止5分） → endAt=09:50、中断1回

### E. 計画外で開始（長さを決める）
1. 「カテゴリを選んで開始」 → シート「計画外で開始」、長さ 25分、「〜 終了予定」
2. 「勉強を開始」 → タイマー「残り 25:00」 → FocusSession（planBlockId なし、plannedDurationSec=1500）
3. 「一時停止」を5分 → 数字が止まっている。「再開」 → 止めた時点から続き、終了予定が5分後ろに → pauses 1件
4. 「終了」 → ホーム → endAt

### F. デトックスは集中に入らない（CAT-02）
1. 計画外で「休み」を選んで開始 → 10分後に「終了」 → ホームの円の中の集中は変わらず、「デトックス」が10分増える

### G. アプリを閉じてもタイマーが正しい（TMR-02）
1. 10:00 に計画外・決めないで開始 → 「経過 00:00」
2. アプリを終了（スワイプで閉じる）
3. 10:30 に開く → ホームを経ずにタイマー画面、「経過 30:00」前後 → 変化なし

### H. 間違えて開始してすぐ終えた
1. 開始 → 10秒後に「終了」 → ホームに戻り、上に「1分未満なので記録しませんでした」が2秒出る。数字は変わらない → FocusSession は残らない

### I. 止め忘れ（計画外25分を 9:00 に開始し、14:00 に気づく）
1. アプリを開く → タイマー画面「超過 +4:35:00」
2. 「終了」 → シート「いつやめましたか？」、「9:00 に開始してから 5時間 たっています」、時刻の初期値 09:25
3. 「この時刻で終了」 → ホームに戻り、集中が 25分 増える → endAt=09:25、originalEndAt=14:00
4. （2 でシートを閉じた場合）→ タイマー画面のまま → 変化なし

### J. 実行中に4:00を過ぎる
1. 3:30 に計画外「決めない」で開始し、4:10 に「終了」 → 4:00 をまたいだので「いつやめましたか？」。そのまま「この時刻で終了」（初期値＝今） → ホームに戻った直後に今日の朝の計画が全画面で出る → セッションは前日の dayKey

### K. 保存できなかったとき
1. （`-failSave` で起動）「終了」 → アラート「保存できませんでした」。閉じるとタイマー画面のまま → 変化なし

## テスト計画

### 共通の前提
- 単体テストは Swift Testing（`FocusAppTests/`）。時刻は Asia/Tokyo。Calendar はテストで作って渡す（`TimeZone.current` を書き換えない。並列実行で他のテストを壊すため）
- `TestStore`（テスト用ヘルパー）：`ModelContainer`（メモリ内）と `SwiftDataStore` を一緒に持つ（コンテナが先に解放されるとクラッシュするため）。SwiftData を使うスイートは `@MainActor`
- ファイルに書くテストは UUID 入りの一時パスを使い、終わったら消す
- Repository の API では作れない状態（重複、知らない状態、壊れた JSON、カテゴリ名の変更）は `ModelContext` に直接入れて作る
- 時計：固定なら `FixedClock`、途中で進めるテストは `MutableClock`（テストターゲットに置く）
- 保存失敗：`SwiftDataStore.saveHook` で throw させる。偽物の Repository は作らない（AppModel のテストも本物の `SwiftDataStore` をメモリ内で使う）
- 既存テストの扱い：`HomeSnapshotTests` の HomeSample 前提のテストは、同じ数値を実データ（`FocusSession`）で作る形に置き換える（`currentAndNextBlock`・`plannedFocusExcludesDetoxBlocks`・`reviewEntryAppearsFrom22` は計画を `PlanDraft` から作って残す）。`RunningTimerTests` は `FocusSession` 版に置き換える。`LaunchOptionsTests` の日付の読み取り・`makeClock` は残し、`LaunchOptionsHomeTests` は消す

### 単体：FocusSession（`FocusSessionTests`）
| テスト名 | 検証内容 |
|---|---|
| activeSecondsExcludesPauses | 9:00開始・9:10〜9:15停止・9:30終了 → 25分、区間は 9:00–9:10 と 9:15–9:30、中断1回 |
| activeSecondsWhilePausedIsFrozen | 停止中は now が進んでも値が変わらない。now が開始より前なら0 |
| blockCountdownIgnoresPauses | plannedEndAt=10:10、5分停止しても残りは 10:10−now。停止中も減る |
| lengthCountdownShiftsByPauses | 25分・5分停止（終了済み） → 終了予定が開始+30分。停止中（進行中）は残りが減らず、終了予定が now に合わせて後ろへ |
| stopwatchHasNoPlannedEnd | plannedEnd も remaining も nil、isCountdown が false |
| overtimeIsNegativeRemaining | 予定の終了を3分過ぎ → −180 |
| endTimeCheckOvertimeBoundary | 超過 29分59秒 → false、30分ちょうど → true |
| endTimeCheckOvertimeWhilePaused | 計画ブロックで停止中に超過30分 → true（止め忘れの一時停止も救う） |
| endTimeCheckStopwatchBoundary | 停止を除いて3時間ちょうど → false、3時間1秒 → true。壁時計3時間30分・停止30分 → false |
| endTimeCheckDayBoundary | 3:30開始：3:59:59 → false、4:00:00 → true。4:30開始：翌3:59 → false、翌4:00 → true |
| endingAtNow | reportedEnd=now → endAt=now、originalEndAt=nil |
| endingEarlierKeepsOriginal | 9:00開始、reportedEnd=9:25、now=14:00 → endAt=9:25、originalEndAt=14:00 |
| endingInsidePauseUsesPauseStart | 9:10〜9:20停止、reportedEnd=9:15 → endAt=9:10、その停止は捨てる（中断0回） |
| endingWhilePausedUsesPauseStart | 9:30から停止中、now=9:40 で終える → endAt=9:30、停止は捨てる、originalEndAt=nil |
| endingDropsLaterPauses | reportedEnd より後に始まった停止は消える |
| endingBounds | reportedEnd=開始 → エラー、開始+1秒 → 可、now+1秒 → エラー |
| pausesJSONRoundTrip | [PauseInterval] の JSON を書いて読むと同じ。壊れた JSON → 空配列 |

### 単体：HomeSnapshot（`HomeSnapshotTests`）
| テスト名 | 検証内容 |
|---|---|
| focusExcludesDetoxAndCountsOnlyUntilNow | 実データで既存と同じ数値（集中90分・デトックス30分）。休みは集中に入らない（1a-7） |
| sessionInProgressCountsUpToNow | 実行中のセッションは now までを数える。停止中の分は入らない |
| ghostDiffComparesSameTimeOfDay | 7日前の同じ時刻のセッションから 65分・差 +25分（既存と同じ数値） |
| ghostNilWhenNoSessionsLastWeek | 7日前が0件 → ghost=nil、差も nil（GHO-03） |
| ghostExcludesPauses | 先週のセッションの停止中は先週の集中に入らない |
| ghostClipsAt24Hours | 先週 3:30 に開始（前日の dayKey なので対象外）／先週 4:30 開始〜翌 5:00 終了 → 翌 4:00（24時間）で切れる |
| currentAndNextBlock / plannedFocusExcludesDetoxBlocks / reviewEntryAppearsFrom22 | 既存どおり（計画は PlanDraft から） |
| removedBlocksAreHidden | isRemoved のブロックは今／次に出ない |
| skippedPlanIsNoPlanDay | skipped → isNoPlanDay |
| unknownCategoryFallsBack | 見つからない categoryId → 「不明」、集中に数えない、区間は残る |
| archivedCategoryStillResolves | アーカイブ済みカテゴリのセッションも名前と集中の判定が引ける |

### 単体：PlanSnapshot（`PlanSnapshotTests`）
| テスト名 | 検証内容 |
|---|---|
| snapshotRoundTrip | 書いて読むと同じ。プロジェクトなしのブロックは projectId・projectName が nil |
| unreadableSnapshotIsNil | 壊れた JSON → nil（計画そのものは読める） |

### 単体：カテゴリ（`CategoryRepositoryTests`）
| テスト名 | 検証内容 |
|---|---|
| seedsSevenDefaultsOnce | 空 → 7つ、並び順と countsAsFocus が CAT-01 どおり。2回呼んでも7つ |
| doesNotReseedWhenAllArchived | 全部アーカイブ済み → 追加しない |
| categoriesExcludeArchived | 選ぶ用はアーカイブを除く。読む用（allCategories）は含む |
| createProjectTrimsAndDedupes | 「 ゼミ準備 」→「ゼミ準備」、同じカテゴリの同名は同じ id。別カテゴリなら別。アーカイブ済みの同名があれば新しく作る |
| createProjectRejectsBlank | 空白だけ → nil、保存されない |

### 単体：計画（`PlanRepositoryTests`）
| テスト名 | 検証内容 |
|---|---|
| planTransitionTable | 状態（なし・draft・confirmed・skipped）× 操作（saveDraft・confirm・skip・saveChanges）の16通りをパラメータ化テストで総当たり。期待どおりの状態になるか、エラー／何もしない場合は状態・ブロック・スナップショットが変わらない |
| saveDraftCreatesAndUpdates | 1回目で draft と1ブロック、2回目で2ブロック、消すと物理削除 |
| confirmSavesSnapshot | confirmedAt=now、スナップショットにブロックと名前。ブロックの行も confirmed 後に残る |
| confirmTwiceKeepsFirstSnapshot | 2回目の confirm でスナップショットが変わらない |
| saveChangesKeepsSnapshot | 変更後もスナップショットは朝のまま（1a-3） |
| saveChangesMarksRemoved | 消したブロックは isRemoved=true で行が残り、plan() には出ない。時刻・カテゴリの変更は反映 |
| skipFromDraftDeletesBlocks | draft → skipped、ブロックは物理削除 |
| unknownStatusIsReadOnly | statusRaw="future" → confirmed 扱い。saveDraft・skip・confirm で何も変わらない |
| duplicatePlansPickNewest | 同じ dayKey が2件 → updatedAt が新しい方 |
| snapshotSurvivesCategoryRename | カテゴリ名を変えてもスナップショットの名前は朝のまま |
| saveFailureRollsBack | saveHook が throw → confirm が throw し、読み直すと draft のまま |

### 単体：セッション（`SessionRepositoryTests`）
| テスト名 | 検証内容 |
|---|---|
| startPlannedSavesRunning | endAt=nil、dayKey、timeZoneId（渡したタイムゾーン）、planBlockId、plannedEndAt |
| startUnplannedLengthAndStopwatch | plannedDurationSec=1500／どちらも nil |
| startWhileRunningThrows | alreadyRunning、2件目はできない |
| startDayKeyBoundary | 3:59:59 開始 → 前日、4:00:00 開始 → 当日 |
| pauseResumePersist | 停止・再開が保存され、読み直しても同じ |
| pauseResumeAreIdempotent | 二重の停止・停止していない再開・終了済みへの停止／再開 → 何も変わらない |
| endSaves | endAt が入り .saved、runningSession()=nil |
| endShortSessionDiscards | 停止を除き 59.5秒 → レコードが消え .discardedTooShort。60秒 → 保存。10分中9分半停止 → 消える |
| endWithReportedEnd | reportedEnd=9:25 → endAt=9:25、originalEndAt=now。早めた結果が1分未満 → 消える |
| endTwiceIsNoOp / endUnknownIdThrows | 終了済み → 変わらず .saved／ない id → notFound |
| saveFailureKeepsRunning | saveHook が throw → end が throw し、runningSession() は終了前のまま。saveHook を外して再度 end → 保存できる |
| sessionsByDayKey | その日のセッションだけ返る（4:00 をまたいだものは開始した日） |
| runningSurvivesNewContainer | 一時ファイルに開始 → コンテナを作り直して runningSession() が同じ id・開始時刻（TMR-02） |
| corruptPausesJSONReadsAsEmpty | 壊れた JSON でもセッションは読める |
| duplicateRunningPicksLatest | 実行中2件 → startAt が新しい方 |

### 単体：スキーマ（`SchemaTests`）
| テスト名 | 検証内容 |
|---|---|
| fileStoreRoundTripsAllModels | 一時ファイルに5モデルを1件ずつ書き、別のコンテナで開いて全項目が読める |
| openFailureKeepsFile | 壊れたファイル（ゴミのバイト列）を開く → throw し、ファイルは残っている（NFR-02） |

### 単体：AppModel（`AppModelTests`、本物の SwiftDataStore をメモリ内で使う）
| テスト名 | 検証内容 |
|---|---|
| morningPlanShownWhenNoneOrDraft | 今日の計画なし・下書き → morningPlan あり。confirmed・skipped → なし |
| morningPlanDayBoundary | 前日が確定済み：3:59 → 出ない、4:00 → 出る（1a-1） |
| morningPlanWaitsForRunning | 実行中のセッションがあれば出さず、end の後の reload で出る |
| morningPlanKeepsOpeningDayKey | MutableClock で 3:55 に開き 4:05 に確定 → 前日の dayKey に保存、その後 今日の朝の計画が出る |
| reloadUsesProvidedTimeZone | タイムゾーンの取得元を東京→ニューヨークに変えて reload → dayKey がそのタイムゾーンで出る |
| startPlannedUsesBlockEnd / startUnplannedUsesLength | plannedEndAt=ブロック終了／plannedDurationSec=分×60 |
| requestEndAsksOnlyWhenForgot | 条件を満たすと終了時刻の確認、満たさないとすぐ終了 |
| discardedShowsNotice | 1分未満 → notice「1分未満なので記録しませんでした」 |
| saveFailureShowsErrorAndAllowsRetry | saveHook が throw → errorMessage「保存できませんでした」、running はそのまま。外して再度 end → 保存 |
| createProjectUpdatesList | createProject 後に projects に出る |
| endAddsFocusToSnapshot | 23分動かして end → snapshot の集中が23分増える |

### 単体：起動引数・デモデータ（`LaunchOptionsTests`、`DemoDataTests`）
| テスト名 | 検証内容 |
|---|---|
| seedDemoDataSceneParsing | `-seedDemoData -fixedNow …` → 場面 day と fixedNow。`-seedDemoData running` → running。知らない名前は day で、その引数は次の処理に回る |
| storeOptions | `-inMemoryStore`・`-storeName x`・`-resetStore`・`-failSave`・`-failStoreOpen` |
| demoIsDeterministic | 同じ時刻で2回作ると同じ中身 |
| demoScene（場面ごとのパラメータ化） | 過去21日の有無、今日の計画の状態、実行中の有無。running のセッションは今日の他のセッションと重ならない。forgot は5時間前開始 |

### UI テスト（`FocusAppUITests`、再起動をまたぐものと画面のつながりに絞った5本）
時刻は `+09:00` つきで渡す。`-storeName` はテストごとに別の名前にし、最初の起動だけ `-resetStore` を付ける。待つときは `waitForExistence(timeout:)`。1本あたり30〜60秒、`scripts/test.sh` で単体と一緒に走る。

| テスト名 | 起動引数 | 検証内容 |
|---|---|---|
| testMorningPlanPersistsDraftAndConfirm | `-storeName ui-a -resetStore -fixedNow 2026-10-19T09:10:00+09:00` | 台本 A：「この計画で始める」が押せない → 「ブロックを追加」→ 勉強の「＋」で「ゼミ準備」を作成し選ばれている → 「追加」→ `app.terminate()` → 同じ store で再起動するとブロックが残る → 「この計画で始める」→ 再起動で計画画面が出ず「ゼミ準備を開始」が見える |
| testSkipPlanPersists | `-storeName ui-b -resetStore -fixedNow 2026-10-19T09:10:00+09:00` | 台本 B：「今日は計画しない」→「計画なし」→ 再起動しても計画画面が出ない |
| testRunningTimerSurvivesRelaunch | 1回目 `-storeName ui-g -resetStore -fixedNow 2026-10-19T10:00:00+09:00`、2回目 `-storeName ui-g -fixedNow 2026-10-19T10:30:30+09:00` | 台本 G：計画しない →「カテゴリを選んで開始」→「決めない」→ 開始 → `app.terminate()` → 再起動でホームを経ずにタイマー画面、「経過」の数字が `30:` で始まる（1a-5。30秒の余裕で起動の遅れを吸収） |
| testPauseResumeEnd | `-seedDemoData running -fixedNow 2026-10-19T11:20:00+09:00` | 台本 D の画面のつながり：タイマー画面 →「一時停止」→ 見出し「一時停止中」とボタン「再開」→「再開」→「終了」→ ホームの開始ボタンが見える（増えた時間は単体の endAddsFocusToSnapshot で確かめる。OffsetClock は実時間で進むので、UI テストでは5分の停止を再現しない） |
| testSaveFailureKeepsTimer | `-seedDemoData running -fixedNow 2026-10-19T11:20:00+09:00 -failSave` | 台本 K：「終了」→「保存できませんでした」→「OK」→ タイマー画面のまま（実装中に見つけた不具合の再発防止。修正を戻すと落ちることを確認済み） |

### シミュレーターで確かめて撮るもの（テストにしない）
`FocusAppUITests/ScreenTourUITests` が操作して撮る（環境変数 `SCREEN_TOUR=1` のときだけ動く）。
| 台本・画面 | 起動引数 | 見るもの |
|---|---|---|
| C 計画の変更 | `-seedDemoData day -fixedNow …T10:30:00+09:00` | 「今：〜 ›」→ スワイプで削除 →「保存」→ ホームの「次」が変わる |
| E 計画外の一時停止 | `-seedDemoData day`（実時間） | 一時停止で数字が止まり、再開で続く、終了予定が後ろにずれる |
| F デトックス | 単体（focusExcludesDetox…）で確かめる。画面は day 場面のスクショで「デトックス」表示を見る | |
| H 1分未満 | `-seedDemoData day` | 開始してすぐ終了 →「1分未満なので記録しませんでした」 |
| I 止め忘れ | `-seedDemoData forgot -fixedNow …T14:00:00+09:00` | 「いつやめましたか？」、初期値＝予定の終了、「この時刻で終了」でホームに戻り集中が増える |
| J 4:00 をまたぐ | `-seedDemoData forgot -fixedNow 2026-10-20T04:10:00+09:00` | 終了 → 確認 → ホームに戻った直後に朝の計画 |
| K 保存失敗 | `-seedDemoData running -failSave` | 「終了」→「保存できませんでした」、タイマー画面のまま |
| 開けないとき | `-failStoreOpen` | 「記録を開けませんでした」「記録は消していません」「もう一度試す」 |
| 見た目 | 各場面 | 前回と同じ（ライト・ダーク・文字サイズ最大）、「一時停止中」、終了時刻の確認シート、firstweek の1重の円 |

### 受け入れ基準との対応
| 基準 | 確かめるもの |
|---|---|
| 1a-1 | morningPlanDayBoundary、testMorningPlanPersistsDraftAndConfirm |
| 1a-2 | createProject*、planTransitionTable、testMorningPlanPersistsDraftAndConfirm（既存の PlanDraftTests で重なり・4:00） |
| 1a-3 | saveChangesKeepsSnapshot、confirmTwiceKeepsFirstSnapshot、画面 C |
| 1a-4 | startPlannedUsesBlockEnd、startUnplannedUsesLength、testRunningTimerSurvivesRelaunch、testPauseResumeEnd |
| 1a-5 | runningSurvivesNewContainer、testRunningTimerSurvivesRelaunch（実機はオーナー） |
| 1a-7 | focusExcludesDetoxAndCountsOnlyUntilNow |
| 1a-9 | 画面「見た目」 |
| 1a-11, 1a-12 | FocusSessionTests（lengthCountdown*、overtime*）、既存の LengthSliderTests |
| 1a-13 | ending*、endWithReportedEnd、画面 I（タイムラインからは後の PR） |

## 残る判断（オーナーへ）
- マージ前に、[data-model.md](../design/data-model.md) の保存項目で足りないものがないか確認してもらう（ADR-0010 の例外）

