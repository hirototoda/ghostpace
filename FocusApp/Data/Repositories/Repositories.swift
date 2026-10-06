import Foundation

/// データの読み書きの窓口（ADR-0002）。画面は SwiftData を直接触らず、ここを経由する。

enum RecordError: Error, Equatable {
    /// 同時に動くタイマーは1つだけ
    case alreadyRunning
    case notFound
    /// その計画の状態ではできない操作（docs/plan/recording-spec.md の表）
    case invalidPlanState
    /// 名前が空
    case emptyName
    /// 同じ名前がすでにある（アーカイブ以外）
    case duplicateName
    /// 最後のカテゴリはアーカイブできない
    case lastCategory
    /// テンプレートは最大7つ（PLN-07）
    case tooManyTemplates
}

/// タイマーを始めるときの値。
struct StartRequest {
    var category: CategoryOption
    var project: ProjectOption?
    var planBlockId: UUID?
    var plannedEndAt: Date?
    var plannedDurationSec: Int?
    /// 開始した日（dayKey）を決めるタイムゾーン。保存もする
    var timeZone: TimeZone
}

/// 押し忘れの申告（TMR-13）の値。
struct DeclareRequest {
    var category: CategoryOption
    var project: ProjectOption?
    var planBlockId: UUID
    var start: Date
    var end: Date
    /// ブロックの終わり（タイムラインでブロックの記録として出すため）
    var plannedEndAt: Date
    var timeZone: TimeZone
}

enum EndResult: Equatable {
    case saved
    /// 一時停止を除いて1分未満だったので記録しなかった
    case discardedTooShort
}

@MainActor
protocol CategoryRepository {
    /// カテゴリが（アーカイブを含めて）1つもなければ、デフォルトの8つを保存する（CAT-01）
    func seedDefaultsIfNeeded() throws
    /// 選ぶ画面用（アーカイブ以外、並び順）
    func categories() throws -> [CategoryOption]
    /// 記録を読む用（アーカイブを含む）
    func allCategories() throws -> [CategoryOption]
    func projects() throws -> [ProjectOption]
    func allProjects() throws -> [ProjectOption]
    /// 前後の空白を除き、空なら nil。同じカテゴリの同名（アーカイブ以外）があればそれを返す
    func createProject(name: String, category: CategoryOption) throws -> ProjectOption?

    // 設定（docs/product/features/settings.md）
    func archivedCategories() throws -> [CategoryOption]
    func archivedProjects() throws -> [ProjectOption]
    /// 前後の空白を除き、空なら nil。同名（アーカイブ以外）があればそれを返す（CAT-04）
    func createCategory(name: String, countsAsFocus: Bool, detoxGroup: DetoxGroup?) throws -> CategoryOption?
    /// 名前・数え方・グループを変える。数え方はこれから始める記録から効く（CAT-02）。グループは過去の点にも効く。集中ならグループは消す
    func updateCategory(id: UUID, name: String, countsAsFocus: Bool, detoxGroup: DetoxGroup?) throws
    func setCategoryArchived(id: UUID, _ archived: Bool) throws
    func renameProject(id: UUID, name: String) throws
    func setProjectArchived(id: UUID, _ archived: Bool) throws
    /// 掃除・料理・瞑想を家事・休みのブロック名に組み替え、記録を付け替える（1回だけ。settings.md「カテゴリの組み替え」）
    func regroupDetoxCategories() throws -> Bool
}

@MainActor
protocol PlanRepository {
    func plan(dayKey: String) throws -> StoredPlan?
    func snapshot(dayKey: String) throws -> [PlanSnapshotBlock]?
    func saveDraft(_ draft: PlanDraft, dayKey: String, timeZone: TimeZone) throws
    func confirm(_ draft: PlanDraft, dayKey: String, timeZone: TimeZone) throws
    /// 計画なし日にする。goalSeconds は計画なし日の目標（nil なら目標なし）。すでに計画なし日なら何もしない
    func skip(dayKey: String, timeZone: TimeZone, goalSeconds: Int?) throws
    func saveChanges(_ draft: PlanDraft, dayKey: String) throws
    /// 目標だけを変える（計画なし日の目標、GHO-10）。その日の計画（計画なしを含む）がなければ notFound
    func setGoal(_ seconds: Int?, dayKey: String) throws
}

extension PlanRepository {
    func skip(dayKey: String, timeZone: TimeZone) throws {
        try skip(dayKey: dayKey, timeZone: timeZone, goalSeconds: nil)
    }
}

@MainActor
protocol TemplateRepository {
    /// 作った順
    func templates() throws -> [PlanTemplate]
    /// 同じ id があれば上書き、なければ追加（8つ目は tooManyTemplates）。名前の前後の空白は除く
    func saveTemplate(_ template: PlanTemplate) throws
    func deleteTemplate(id: UUID) throws
    /// テンプレートが1つもなければ「理想の休日」を入れる。入れたら true
    func seedTemplatesIfNeeded() throws -> Bool
}

@MainActor
protocol SessionRepository {
    func runningSession() throws -> FocusSession?
    func start(_ request: StartRequest) throws -> FocusSession
    func pause(id: UUID) throws
    func resume(id: UUID) throws
    /// reportedEnd が nil なら今で終える
    func end(id: UUID, reportedEnd: Date?) throws -> EndResult
    func sessions(dayKey: String) throws -> [FocusSession]
    /// すべての記録（古い順）。自己ベスト・時間帯の地図（ANA-06・07）に使う
    func allSessions() throws -> [FocusSession]
    /// 保存するたびに増える番号。変わっていなければ数え直さなくてよい
    var revision: Int { get }
    /// 終わった記録の終了時刻を早める（TMR-08）。直せる日かどうかは呼ぶ側で確かめる
    func shortenEnd(id: UUID, to newEnd: Date) throws
    /// 押し忘れの申告（TMR-13）。申告の印を付けた終わった記録を足す
    func declare(_ request: DeclareRequest) throws -> FocusSession
}

/// 睡眠の記録（DTX-02、保存データ第3版）。
@MainActor
protocol SleepRepository {
    func sleep(dayKey: String) throws -> SleepLine?
    /// その日の睡眠を保存する（あれば上書き）
    func saveSleep(_ sleep: SleepLine, dayKey: String, timeZone: TimeZone) throws
}

typealias RecordStore = CategoryRepository & PlanRepository & SessionRepository & TemplateRepository & SleepRepository
