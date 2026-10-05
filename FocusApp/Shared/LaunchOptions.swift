import Foundation

/// 検証用の起動引数。Debug ビルドでのみ有効にする。
/// - `-fixedNow <日時>`: その時刻から時計を始める。例 `-fixedNow 2026-10-19T14:30`（タイムゾーン省略時は端末のタイムゾーン）
/// - `-seedDemoData [場面]`: メモリ内のストアにデモデータを入れる。場面は day（既定）/ morning / noplan / running / forgot / firstweek
/// - `-inMemoryStore`: メモリ内のストアを使う（本物のデータに触れない）
/// - `-storeName <名前>`: 別名のファイルに保存する（UI テストで再起動をまたぐ確認に使う）。`-resetStore` で開く前に消す
/// - `-failSave`: 保存を毎回失敗させる。`-failStoreOpen`: ストアを開けなかったことにする（画面の確認用）
/// - `-openAnalysis`: 起動したら分析のタブを開く。`-openTimeline`: 分析のタブのタイムラインを開く。`-openPoints`: 分析のタブのポイントの推移を開く（`-openDay <何日前>` でその日のグラフまで）
/// - `-openReview`: 起動したら夜の振り返りを開く。`-openSettings`: 設定を開く。`-openPlan`: 計画のタブを開く
/// - `-openStartSheet`: 起動したら計画外で開始のシートを開く
/// - `-flipRace`: ホームの円を裏（グラフ）で始める（GHO-13 の撮影用）
/// - `-goalMinutes <分>`: 見本データの今日の計画の目標（計画より多い目標の撮影用、GHO-10）
/// - `-opponent lastWeek|goal`: 見本データで比べる相手を選んで始める。`-raceWholeDay`: 裏のグラフを1日全体で始める。`-raceReplay`: 裏が見えたら［▶］で1日を流し始める（GHO-13 の撮影用）
/// - `-liveGallery`: 起動したらロック画面と画面上部の見本を出す（画面の確認用）
/// - `-openAddCategory`: 起動したら「カテゴリを追加」をデトックスで開く（グループの一覧の撮影用）
/// - `-noHealthSleep`: 見本のヘルスケアに睡眠の記録がないことにする（「ヘルスケアから読み直す」で記録がないときの撮影用、DTX-02）
/// - `-liveActivity`: 見本データでも本物のロック画面・画面上部に出す（シミュレーターでの確認用）
/// - `-openHold [unlocked]`: 起動したら長押しの画面を開く（`unlocked` なら15分開けたあと）。`-holdProgress 0.6`: 押している途中の見た目で始める
struct LaunchOptions: Hashable {
    var fixedNow: Date?
    /// nil ならデモデータを入れない
    var demoScene: DemoScene?
    var inMemoryStore = false
    var storeName: String?
    var resetStore = false
    var failSave = false
    var failStoreOpen = false
    var openTimeline = false
    var openAnalysis = false
    var openPoints = false
    /// ポイントの推移から開くその日のグラフ（何日前）
    var openDay: Int?
    var openReview = false
    var openSettings = false
    var openPlan = false
    /// 長押しの画面を開く
    var openHold = false
    /// 長押しの画面を、15分開けたあとの状態で開く
    var openHoldUnlocked = false
    var holdProgress: Double = 0
    /// ホームの円を裏（グラフ）で始める。nil なら表
    var raceStartsFlipped = false
    /// 見本データで比べる相手
    var opponent: Opponent?
    /// 見本データの今日の計画の目標（分）。nil なら計画の集中の合計
    var demoGoalMinutes: Int?
    /// 裏のグラフを1日全体で始める（撮影用）
    var raceStartsWholeDay = false
    /// 裏が見えたら［▶］で1日を流し始める（撮影用）
    var raceStartsReplay = false
    /// ロック画面と画面上部の見本を出す
    var liveGallery = false
    /// 「カテゴリを追加」をデトックスで開く（撮影用）
    var openAddCategory = false
    /// 見本のヘルスケアに睡眠の記録がないことにする（撮影用）
    var noHealthSleep = false
    /// 計画外で開始のシートを開く
    var openStartSheet = false
    /// 見本データでも本物のロック画面・画面上部に出す
    var liveActivity = false
    /// `-storeName` のファイルを置く場所（テストで一時フォルダに差し替える）
    var storeDirectory: URL = .applicationSupportDirectory

    static func parse(_ arguments: [String], timeZone: TimeZone = .current) -> LaunchOptions {
        var options = LaunchOptions()
        var index = 0
        func next() -> String? { index + 1 < arguments.count ? arguments[index + 1] : nil }
        while index < arguments.count {
            switch arguments[index] {
            case "-fixedNow":
                if let value = next() {
                    options.fixedNow = parseDate(value, timeZone: timeZone)
                    index += 1
                }
            case "-seedDemoData":
                // 次の引数が場面名のときだけ場面として読む（`-seedDemoData -fixedNow …` を誤読しない）
                if let value = next(), let scene = DemoScene(rawValue: value) {
                    options.demoScene = scene
                    index += 1
                } else {
                    options.demoScene = .day
                }
            case "-inMemoryStore":
                options.inMemoryStore = true
            case "-storeName":
                if let value = next() {
                    options.storeName = value
                    index += 1
                }
            case "-resetStore":
                options.resetStore = true
            case "-failSave":
                options.failSave = true
            case "-failStoreOpen":
                options.failStoreOpen = true
            case "-openTimeline":
                options.openTimeline = true
            case "-openAnalysis":
                options.openAnalysis = true
            case "-openPoints":
                options.openPoints = true
            case "-openDay":
                if let value = next(), let days = Int(value) {
                    options.openPoints = true
                    options.openDay = days
                    index += 1
                }
            case "-openReview":
                options.openReview = true
            case "-openSettings":
                options.openSettings = true
            case "-openPlan":
                options.openPlan = true
            case "-openHold":
                options.openHold = true
                if next() == "unlocked" {
                    options.openHoldUnlocked = true
                    index += 1
                }
            case "-flipRace":
                options.raceStartsFlipped = true
                // 前の版の `-flipRace points` も受け付ける
                if next() == "points" { index += 1 }
            case "-raceWholeDay":
                options.raceStartsWholeDay = true
            case "-raceReplay":
                options.raceStartsReplay = true
            case "-goalMinutes":
                if let value = next(), let minutes = Int(value) {
                    options.demoGoalMinutes = minutes
                    index += 1
                }
            case "-opponent":
                if let value = next(), let opponent = Opponent(rawValue: value) {
                    options.opponent = opponent
                    index += 1
                }
            case "-openStartSheet":
                options.openStartSheet = true
            case "-liveGallery":
                options.liveGallery = true
            case "-openAddCategory":
                options.openAddCategory = true
            case "-noHealthSleep":
                options.noHealthSleep = true
            case "-liveActivity":
                options.liveActivity = true
            case "-holdProgress":
                if let value = next(), let progress = Double(value) {
                    options.holdProgress = min(max(progress, 0), 1)
                    index += 1
                }
            default:
                break
            }
            index += 1
        }
        return options
    }

    /// 起動引数から時計を作る。`-fixedNow` がなければ実際の時刻。
    func makeClock(base: any AppClock = SystemClock()) -> any AppClock {
        guard let fixedNow else { return base }
        return OffsetClock(startingAt: fixedNow, base: base)
    }

    /// 保存先。nil ならメモリ内。
    var storeURL: URL? {
        if demoScene != nil || inMemoryStore { return nil }
        if let storeName { return storeDirectory.appending(path: "\(storeName).store") }
        return AppStore.defaultURL
    }

    static func parseDate(_ text: String, timeZone: TimeZone) -> Date? {
        if let date = try? Date.ISO8601FormatStyle().parse(text) {
            return date
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        for format in ["yyyy-MM-dd'T'HH:mm:ssXXX", "yyyy-MM-dd'T'HH:mmXXX", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) {
                return date
            }
        }
        return nil
    }
}
