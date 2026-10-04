import Foundation

/// 端末の設定（docs/product/features/settings.md）。記録（SwiftData）とは別に UserDefaults に置く。
@MainActor
protocol AppSettings: AnyObject {
    /// 振り返りの通知の時刻（0:00 からの分。初期値 22:00、REV-02）
    var reviewMinutes: Int { get set }
    /// 予定の時間の通知（TMR-05）
    var plannedEndNotifications: Bool { get set }
    /// 計画ブロックの前の通知を何分前に出すか（0 はちょうど、nil はオフ。初期値5分前、TMR-12）
    var blockNoticeMinutes: Int? { get set }
    /// 通知の説明を出したか（初めて朝の計画を確定した直後に1回だけ）
    var didShowNotificationIntro: Bool { get set }
    /// 掃除・料理・瞑想を家事・休みに組み替えたか（CAT-01、2026-10-03。それまでの「瞑想を足したか」の代わり）
    var didRegroupDetoxCategories: Bool { get set }
    /// 「理想の休日」のテンプレートを入れたか（PLN-07。消したあとに入れ直さない）
    var didSeedTemplates: Bool { get set }
    /// ホームで選んだ対戦相手（GHO-10）
    var opponent: Opponent { get set }
    /// アプリのブロックの説明を出したか（BLK-01。1回だけ）
    var didShowBlockingIntro: Bool { get set }
    /// ブロックの「始めた」を記録したか（BLK-11。この版の前から始めていた端末にも1回だけ書く）
    var didLogBlockStart: Bool { get set }
    /// 最後に見た Screen Time の許可（BLK-11。変わったら記録する）。nil はまだ見ていない
    var lastBlockingAuthorized: Bool? { get set }
    /// 最後に許可があると確かめた時刻（BLK-11。外れたときは、ここから外れていたとみなす）
    var lastBlockingAuthorizedAt: Date? { get set }
    /// 睡眠の時刻（0:00 からの分。初期値 0:00〜7:00、DTX-02）。ヘルスケアに記録がない日に使う
    var sleepStartMinutes: Int { get set }
    var sleepEndMinutes: Int { get set }
}

enum SettingsDefaults {
    static let reviewMinutes = 22 * 60
    static let sleepStartMinutes = 0
    static let sleepEndMinutes = 7 * 60
}

/// UserDefaults に保存する設定。項目がなければ初期値で読む。
@MainActor
final class UserDefaultsSettings: AppSettings {
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    private enum Key {
        static let reviewMinutes = "reviewMinutes"
        static let plannedEndNotifications = "plannedEndNotifications"
        static let blockNoticeMinutes = "blockNoticeMinutes"
        static let didShowNotificationIntro = "didShowNotificationIntro"
        static let didRegroupDetoxCategories = "didRegroupDetoxCategories"
        static let didSeedTemplates = "didSeedTemplates"
        static let opponent = "opponent"
        static let didShowBlockingIntro = "didShowBlockingIntro"
        static let didLogBlockStart = "didLogBlockStart"
        static let lastBlockingAuthorized = "lastBlockingAuthorized"
        static let lastBlockingAuthorizedAt = "lastBlockingAuthorizedAt"
        static let sleepStartMinutes = "sleepStartMinutes"
        static let sleepEndMinutes = "sleepEndMinutes"
    }

    var reviewMinutes: Int {
        get { (defaults.object(forKey: Key.reviewMinutes) as? Int).map { (($0 % 1440) + 1440) % 1440 } ?? SettingsDefaults.reviewMinutes }
        set { defaults.set(newValue, forKey: Key.reviewMinutes) }
    }

    var plannedEndNotifications: Bool {
        get { defaults.object(forKey: Key.plannedEndNotifications) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.plannedEndNotifications) }
    }

    /// オフは -1 で保存する（項目がないときの初期値5分前と分けるため）
    var blockNoticeMinutes: Int? {
        get {
            guard let stored = defaults.object(forKey: Key.blockNoticeMinutes) as? Int else { return BlockNotice.defaultLeadMinutes }
            return stored < 0 ? nil : stored
        }
        set { defaults.set(newValue ?? -1, forKey: Key.blockNoticeMinutes) }
    }

    var didShowNotificationIntro: Bool {
        get { defaults.bool(forKey: Key.didShowNotificationIntro) }
        set { defaults.set(newValue, forKey: Key.didShowNotificationIntro) }
    }

    var didRegroupDetoxCategories: Bool {
        get { defaults.bool(forKey: Key.didRegroupDetoxCategories) }
        set { defaults.set(newValue, forKey: Key.didRegroupDetoxCategories) }
    }

    var didSeedTemplates: Bool {
        get { defaults.bool(forKey: Key.didSeedTemplates) }
        set { defaults.set(newValue, forKey: Key.didSeedTemplates) }
    }

    var opponent: Opponent {
        get { defaults.string(forKey: Key.opponent).flatMap(Opponent.init(rawValue:)) ?? .lastWeek }
        set { defaults.set(newValue.rawValue, forKey: Key.opponent) }
    }

    var didShowBlockingIntro: Bool {
        get { defaults.bool(forKey: Key.didShowBlockingIntro) }
        set { defaults.set(newValue, forKey: Key.didShowBlockingIntro) }
    }

    var didLogBlockStart: Bool {
        get { defaults.bool(forKey: Key.didLogBlockStart) }
        set { defaults.set(newValue, forKey: Key.didLogBlockStart) }
    }

    var lastBlockingAuthorized: Bool? {
        get { defaults.object(forKey: Key.lastBlockingAuthorized) as? Bool }
        set { defaults.set(newValue, forKey: Key.lastBlockingAuthorized) }
    }

    var lastBlockingAuthorizedAt: Date? {
        get { defaults.object(forKey: Key.lastBlockingAuthorizedAt) as? Date }
        set { defaults.set(newValue, forKey: Key.lastBlockingAuthorizedAt) }
    }

    var sleepStartMinutes: Int {
        get { Self.minutes(defaults.object(forKey: Key.sleepStartMinutes)) ?? SettingsDefaults.sleepStartMinutes }
        set { defaults.set(newValue, forKey: Key.sleepStartMinutes) }
    }

    var sleepEndMinutes: Int {
        get { Self.minutes(defaults.object(forKey: Key.sleepEndMinutes)) ?? SettingsDefaults.sleepEndMinutes }
        set { defaults.set(newValue, forKey: Key.sleepEndMinutes) }
    }

    /// 0:00 からの分（1日の中に収める）
    private static func minutes(_ value: Any?) -> Int? {
        (value as? Int).map { (($0 % 1440) + 1440) % 1440 }
    }
}

/// メモリ内の設定（テスト・見本データ用）。
@MainActor
final class MemorySettings: AppSettings {
    var reviewMinutes = SettingsDefaults.reviewMinutes
    var plannedEndNotifications = true
    var blockNoticeMinutes: Int? = BlockNotice.defaultLeadMinutes
    var didShowNotificationIntro = false
    var didRegroupDetoxCategories = false
    var didSeedTemplates = false
    var opponent: Opponent = .lastWeek
    var didShowBlockingIntro = false
    var didLogBlockStart = false
    var lastBlockingAuthorized: Bool?
    var lastBlockingAuthorizedAt: Date?
    var sleepStartMinutes = SettingsDefaults.sleepStartMinutes
    var sleepEndMinutes = SettingsDefaults.sleepEndMinutes

    init(didShowNotificationIntro: Bool = false) {
        self.didShowNotificationIntro = didShowNotificationIntro
    }
}
