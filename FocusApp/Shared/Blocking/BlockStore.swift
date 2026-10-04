import Foundation
import Synchronization

/// 本体と拡張で共有するブロックの置き場（data-model.md「ブロックの共有データ」）。
protocol BlockStoring: AnyObject, Sendable {
    var state: BlockState { get set }
    /// iPhone 標準の選択画面で選んだ対象（FamilyActivitySelection を JSON にしたもの）
    var selection: Data? { get set }
    var raceSnapshot: ShieldRaceSnapshot? { get set }
    /// 集中中も使うアプリ（BLK-02。FamilyActivitySelection を JSON にしたもの）。nil なら全部ブロック
    var focusAllowSelection: Data? { get set }
}

enum BlockShared {
    static let appGroup = "group.com.hirototoda.focusapp"
    /// シールドの「開く」で出す通知の種類（押すと長押しの画面を開く）
    static let holdNotificationKind = "holdUnlock"

    static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    static var eventLogURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appending(path: "blockEvents.jsonl")
    }
}

/// App Group の UserDefaults。値は JSON で置く。
final class UserDefaultsBlockStore: BlockStoring, @unchecked Sendable {
    // UserDefaults はスレッドをまたいで使ってよい
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    private enum Key {
        static let state = "blockState"
        static let selection = "blockSelection"
        static let raceSnapshot = "shieldRaceSnapshot"
        static let focusAllowSelection = "focusAllowSelection"
    }

    var state: BlockState {
        get { read(Key.state) ?? BlockState() }
        set { write(newValue, Key.state) }
    }

    var selection: Data? {
        get { defaults.data(forKey: Key.selection) }
        set { defaults.set(newValue, forKey: Key.selection) }
    }

    var raceSnapshot: ShieldRaceSnapshot? {
        get { read(Key.raceSnapshot) }
        set { write(newValue, Key.raceSnapshot) }
    }

    var focusAllowSelection: Data? {
        get { defaults.data(forKey: Key.focusAllowSelection) }
        set { defaults.set(newValue, forKey: Key.focusAllowSelection) }
    }

    private func read<T: Decodable>(_ key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private func write<T: Encodable>(_ value: T?, _ key: String) {
        defaults.set(value.flatMap { try? JSONEncoder().encode($0) }, forKey: key)
    }
}

/// メモリ内の置き場（テスト・見本データ・シミュレーター用）。
final class MemoryBlockStore: BlockStoring {
    private let values = Mutex<(BlockState, Data?, ShieldRaceSnapshot?, Data?)>((BlockState(), nil, nil, nil))

    init() {}

    var state: BlockState {
        get { values.withLock { $0.0 } }
        set { values.withLock { $0.0 = newValue } }
    }

    var selection: Data? {
        get { values.withLock { $0.1 } }
        set { values.withLock { $0.1 = newValue } }
    }

    var raceSnapshot: ShieldRaceSnapshot? {
        get { values.withLock { $0.2 } }
        set { values.withLock { $0.2 = newValue } }
    }

    var focusAllowSelection: Data? {
        get { values.withLock { $0.3 } }
        set { values.withLock { $0.3 = newValue } }
    }
}
