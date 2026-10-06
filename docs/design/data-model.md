---
status: draft
---
# データモデル

## 要点（オーナー向け）
- 端末に保存するのは、下の6種類（カテゴリ、ブロック名、1日の計画、計画ブロック、タイマーの記録、計画のテンプレート）。段階1a で保存を始めた（2026-09-30）
- 記録は消さない方針：日中に消した計画ブロックは「消した印」をつけて残す。アーカイブしたカテゴリの記録も読める
- 保存データの形は「版番号つき」。形を変えるときは次の版を足し、前の版のデータを読めることをテストしてから出す（NFR-02）
- 第2版（2026-10-01）：1日の計画に目標時間、計画のテンプレートを足した。第1版のデータはそのまま読める（移行テストで確認）。振り返りはメモを取らないので保存しない
- アプリのブロックの記録は、拡張機能と共有する場所に別のファイルで置く（下の「ブロックの共有データ」）。保存データの版は変えない
- 習慣（PLN-08、2026-10-05）は端末の設定（UserDefaults）に置く。保存データの版は変えない
- ゲーム・SNS の時間（BLK-10、2026-10-02）は、計画ブロックのカテゴリに決まった ID（カテゴリの行は作らない）を入れて表す。保存データの形は変えない
- 第3版（2026-10-02。マージ前にオーナー確認）：睡眠の記録（SleepRecord、DTX-02）を増やした。新しい種類を足すだけで、第2版のデータはそのまま読める（移行テストで確認）
- 第5版（2026-10-06。マージ前にオーナー確認）：タイマーの記録に「申告」の印（isDeclared、TMR-13）を足した。空を許す項目（空は申告ではない）で、第4版のデータはそのまま読める（移行テストで確認）
- 第4版（2026-10-03。マージ前にオーナー確認）：カテゴリにデトックスのグループ（detoxGroupRaw）、睡眠に手で直す前の時刻（originalStartAt・originalEndAt）を足した。どちらも空を許す項目で、第3版のデータはそのまま読める（移行テストで確認）。掃除・料理・瞑想の組み替えと記録の付け替えは、データの形の移行とは別に、起動したときに1回だけ行う（[settings.md](../product/features/settings.md)「カテゴリの組み替え」）

## 共通
全エンティティ：`id: UUID`、`createdAt`、`updatedAt`（UTC）。時刻はUTC保存、`timeZoneId` を別に持つ。
エンティティ間は UUID で参照する（[ADR-0012](../decisions/0012-uuid-references-json-fields.md)）。同じ日の計画が重複して保存されていたら、更新日時が新しいものを使う。

## Category（カテゴリ）
| 項目 | 型 | 説明 |
|---|---|---|
| name | String | 勉強、仕事 など |
| countsAsFocus | Bool | 集中時間に数えるか（CAT-02） |
| sortOrder | Int | 並び順 |
| isArchived | Bool | 削除せずアーカイブ |
| detoxGroupRaw | String? | デトックスのグループ（DTX-03、第4版）：housework（家事）／exercise（運動）／rest（休み）。nil は上乗せなし（集中のカテゴリと、「なし」を選んだもの）。知らない値は nil として読む。集中かどうか（countsAsFocus）と違い、タイマーの記録には写さない（変えると過去の点も数え直す。2026-10-03 オーナー決定） |

初回起動時、カテゴリが（アーカイブを含めて）1つもなければ CAT-01 の6つ（とブロック名：家事に掃除・料理・洗濯、休みに瞑想・休憩）を保存する。デトックスから集中に切り替えると detoxGroupRaw は nil に戻す

## Project（ブロック名）
| 項目 | 型 | 説明 |
|---|---|---|
| name | String | 例：ゼミ準備（前後の空白は除く） |
| categoryId | UUID | 属するカテゴリ（CAT-03）。選ぶとカテゴリも決まる |
| isArchived | Bool | |

同じカテゴリに同じ名前（アーカイブ以外）があれば、新しく作らずそれを使う。WorkType（作業種別）は段階1aでは作らない（段階3で検討）。

## PlanTemplate（計画のテンプレート・PLN-07、第2版）
最大7つ（8つ目は保存しない）。記録ではないので、消すときは行ごと消す（「消した印」の方針の例外）。
| 項目 | 型 | 説明 |
|---|---|---|
| name | String | 例：理想の休日（前後の空白は除く。空にはできない） |
| sortOrder | Int | 作った順 |
| blocksJSON | Data | ブロックの一覧（開始の時・分、長さ（分）、categoryId、projectId?）の JSON。読めなければ空のテンプレートとして扱う |

## DailyPlan（1日の計画）
| 項目 | 型 | 説明 |
|---|---|---|
| dayKey | String | 日付境界適用後の日付（例：2026-10-19） |
| timeZoneId | String | |
| statusRaw | String | draft（下書き）／confirmed（確定）／skipped（計画なし日）。知らない値は確定済みとして読み、書き換えない |
| confirmedAt | Date? | |
| goalFocusSec, goalEdited | Int?, Bool | 目標のゴースト（GHO-10）の目標時間（秒）と、手で変えたか（第2版）。手で変えていなければ nil で、目標は計画の集中の合計。計画なし日（skipped）では目標時間そのもの（0 は「目標なし」として nil） |
| snapshotJSON | Data? | 確定時の計画ブロック一覧の写し（JSON、PLN-03）。以後変更しない。カテゴリ名・ブロック名も写すので、後で名前を変えても朝の計画が読める |

状態ごとにできる操作は [recording-spec.md](../plan/recording-spec.md) の表のとおり（例：確定後の「計画しない」はできない）。

## PlanBlock（計画ブロック）
| 項目 | 型 | 説明 |
|---|---|---|
| planId | UUID | |
| startAt / endAt | Date | 入力は開始時刻＋長さ（5分刻み） |
| categoryId | UUID | 必須。決まった ID `00000000-0000-0000-0000-000000000B10` ならゲーム・SNS の時間（BLK-10。カテゴリの行はなく、画面では「ゲーム・SNS」と出す。長さは30分、集中・デトックスの合計に入れず、タイマーは始めない）。テンプレートの blocksJSON と朝の写し snapshotJSON も同じ ID で見分ける |
| projectId | UUID? | 任意。指定したら categoryId はそのプロジェクトのカテゴリ |
| isRemoved | Bool | 日中の変更で消したブロック（予実分析用に残す）。下書きの段階で消したものは行ごと消す |

## SleepRecord（睡眠の記録・DTX-02、第3版）
1日に1つ。その日の朝に終わった睡眠。GhostPace を開いたときに、その日と前の6日のうちまだない日を設定の時刻で作る（[digital-detox.md](../product/features/digital-detox.md)）。
| 項目 | 型 | 説明 |
|---|---|---|
| dayKey | String | 4:00 区切りの日 |
| timeZoneId | String | |
| startAt / endAt | Date | 寝た・起きた時刻（UTC） |
| sourceRaw | String | health（ヘルスケア）／setting（設定の時刻）／manual（手で直した）。知らない値は manual として読む（置き換えない） |
| originalStartAt / originalEndAt | Date? | 手で直す前の時刻（第4版）。最初に手で直したときに、その直前の値（ヘルスケアか設定の時刻）を入れ、以後変えない。手で直していなければ nil。第4版より前に手で直した日は nil（比べられないので、直した時刻のまま数える） |

- その日のうち（翌朝4:00まで）だけ、health・setting をヘルスケアの値で置き換える。manual と、過ぎた日は置き換えない
- 同じ dayKey が2つあれば、更新日時が新しいものを使う

## FocusSession（タイマーの記録）
| 項目 | 型 | 説明 |
|---|---|---|
| dayKey | String | 開始時刻から算出。4:00 をまたいでも開始した日のまま（タイムラインの日）。円の集中時間・ポイント・対戦は 4:00 で区切った時間で数える（2026-10-03） |
| timeZoneId | String | 開始したときの端末のタイムゾーン |
| planBlockId | UUID? | nilなら計画外 |
| categoryId / projectId | UUID / UUID? | 開始時のラベル |
| countsAsFocus | Bool | 開始したときにカテゴリが「集中に数える」だったか。後でカテゴリの設定を変えても、過去の記録の集中／デトックスは変わらない（2026-09-30 決定。確定した勝ち負けや金額を後から変えないため） |
| startAt / endAt | Date / Date? | endAtがnilなら実行中（同時に1つだけ） |
| plannedEndAt | Date? | 計画ブロックから開始したときのブロックの終了時刻。一時停止しても動かない |
| plannedDurationSec | Int? | 計画外で長さを決めたときの長さ。一時停止した分だけ終わりが後ろにずれる |
| pausesJSON | Data | 一時停止の区間（開始・終了）の一覧の JSON。個数＝中断回数（TMR-03）。読めなければ空として扱う |
| originalEndAt | Date? | 終了時刻を早めたときの元の終了時刻（TMR-08）。nilなら未修正 |
| note | String? | |
| isDeclared | Bool? | 押し忘れの申告（TMR-13、第5版）。true なら申告した記録（点は0.8倍）。nil・false はタイマーで計った記録 |

- 数え方は保存しない：`plannedEndAt` か `plannedDurationSec` があればカウントダウン、どちらもなければストップウォッチ（TMR-07）
- 一時停止を除いて1分未満のセッションは保存しない
- セッションは一時停止の途中では終わらない（終わりが一時停止の中なら、その一時停止の開始を終了にする）

## ブロックの共有データ（App Group、2026-10-01）
本体と拡張機能（別のプロセス）の両方が読み書きするので、SwiftData ではなく App Group（`group.com.hirototoda.focusapp`）に置く。SwiftData の版（SchemaV1/V2）とは別。アプリを消すと消える（記録と同じ）。

### BlockState（UserDefaults・App Group）
| 項目 | 型 | 説明 |
|---|---|---|
| selection | Data | iPhone 標準の選択画面で選んだ対象（FamilyActivitySelection を JSON にしたもの。中身は読めない印） |
| isEnabled | Bool | いつものブロックを始めたか |
| unlockedUntil | Date? | 開けている期限（UTC）。過ぎていればブロック中 |
| unlockRequestedAt | Date? | シールドの「開く」を押した時刻。2分以内に本体を開いたら長押しの画面を出す |
| isFocusBlocking | Bool | 集中のタイマーが動いていて一時停止していないか（BLK-04。ブロックを始めていなくても覚える）。拡張はタイマーを読めないので、これを決定表の入力にする。開けている間も覚えておき、戻すとき全部ブロックもかけ直す。シールドの見出しにも使う。前の版の状態にこの項目がなければ false として読む |
| unblockWindows | [{start, end}] | 今日の確定した計画のゲーム・SNS の時間（BLK-10、UTC。並べたものはつなげる）。本体が読み直すたびに計画から書き、変わったら iPhone のスケジュールを登録し直す。自動で切り替えるしくみ（拡張機能）はこれを正として決定表を計算する |
| isUnblocking | Bool | ゲーム・SNS の時間でいつものブロックを外しているか。変わったときだけ「外した／戻した」を記録する（本体と拡張の二重記録を防ぐ） |
| focusAllowSelection | Data? | 集中中も使うアプリ（BLK-02。FamilyActivitySelection の JSON）。nil なら全部ブロック |

### BlockEvent（JSON Lines・App Group の blockEvents.jsonl、足すだけで消さない）
| 項目 | 型 | 説明 |
|---|---|---|
| id | UUID | |
| occurredAt | Date | UTC |
| timeZoneId | String | |
| kind | enum | shieldShown / unlockRequested / holdCancelled / unlocked / reblocked / started / selectionLost / authorizationLost / authorizationRestored / unblockStarted / unblockEnded（started 以降は BLK-11、2026-10-01） |
| sinceAt | Date? | authorizationLost のとき、前に許可を確かめた時刻（そこから外れていたとみなす） |

- started は「ここからブロックが効いている」の印。前に selectionLost がなくても書くことがある（開こうとして選択が読めず、ブロックは残ったまま選び直したとき）
| unlockMinutes | Int? | 選んだ開ける長さ（kind が unlocked のとき。5〜60） |
| reblockReason | enum? | expired / manual / appForeground（kind が reblocked のとき） |
| activeSessionId | UUID? | 開けたときに動いていたタイマーの記録 |

- 分析（段階3、ANA-01）で SwiftData に取り込むかを決める。それまではこのファイルを正とする
- 知らない kind の行は読み飛ばす（壊れた行と同じ。消さない）
- 拡張機能は1行足すだけ（メモリの制限が厳しいため、読み込まない）

### ShieldRaceSnapshot（UserDefaults・App Group）
シールドに出す差の材料。本体が読み直すたび（起動・前面に来たとき・各操作の後・1分ごと）に書く。
| 項目 | 型 | 説明 |
|---|---|---|
| writtenAt | Date | |
| dayKey | String | 4:00 区切りの日。シールドを出す時刻の dayKey と違えば差を出さない |
| dayStart | Date | その日の 4:00 |
| focusSecAtWrite | Int | 書いた時点の今日の集中 |
| isFocusRunning | Bool | 書いた時点で集中のタイマーが動いていたか（一時停止中は false）。true なら書いた時刻からの分を足す |
| opponentPrefix | String | 「先週の自分より」「目標より」（ホームで選んだ相手。いなければいる方） |
| opponentCurve | [Int] | 相手の累積集中（日付の区切りから15分ごと、97点、秒）。相手がいなければ空。あいだは直線でつなぐ |

### 書き込みと時刻の決まり
- 記録のファイルには、1つの記録を1行として1回で書き足す（4つのプロセスが同時に書いても行が混ざらないように、追記モードで開いて1回で書く）
- 現在時刻は、本体は `AppClock`、拡張は `SystemClock` から取り、`BlockPolicy`・`ShieldRaceSnapshot` には引数で渡す
- 自動で戻すスケジュールは分単位なので、戻す時刻は期限を分に切り上げる（早く戻さない）。新しく開く・今すぐ戻すときは前のスケジュールを止めてから始める。戻すしくみは「今が期限以降で、まだ開けている」ときだけ戻す

## DailyReview（作らない・2026-10-01）
夜の振り返りは数字だけでメモを取らないので、保存しない。明日の計画は DailyPlan（draft）として保存する。

## 端末の設定（UserDefaults）
記録とは別に、通知の時刻・オンオフ、計画の前の通知の分（初期5分前、TMR-12）、通知の説明を出したか、瞑想を足したか（2026-10-03 から使わない）、カテゴリを組み替えたか、「理想の休日」を入れたか、選んだ対戦相手、睡眠の時刻（初期 0:00〜7:00）、習慣（PLN-08。テンプレートのブロックと同じ形 [TemplateBlockValue] の JSON。項目がなければ「まだ決めていない」で、すでに使っている端末は起動時に前の日から引き継いでいた時刻で作る）、習慣の最初の案内を出す途中か（[daily-plan.md](../product/features/daily-plan.md)「習慣」）を置く（[settings.md](../product/features/settings.md)）。版番号の対象外（項目がなければ初期値で読む）。

## 算出値（保存しない）
- 集中時間：countsAsFocus（記録に残した値）が true のセッションの、一時停止を除いた時間の合計
- ゴースト累積曲線：7日前の dayKey のセッションを、日付境界からの経過時間で今日に揃えて算出（24時間を超える部分は切る）
- デジタルデトックスの時間・ポイント（DTX-01・03）：ブロックの記録（始めた・許可・開けた・戻った）、計画のゲーム・SNS の時間、タイマーの記録、睡眠の区間から毎回計算する（[digital-detox.md](../product/features/digital-detox.md)）
- 参照先のカテゴリが見つからない記録は「不明」として表示し、記録は消さない（集中かどうかは記録に残した値のまま）

## 実装
- `FocusApp/Data/Schema.swift`（SchemaV1、SchemaV2、AppMigrationPlan。第1版→第2版は軽量の移行）
- 保存先：端末内の Application Support/default.store。iCloud 同期はしない（段階4）
