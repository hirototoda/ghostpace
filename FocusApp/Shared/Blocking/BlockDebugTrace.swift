import Foundation

/// 実機で流れを確かめるための記録（Debug の版だけ）。本体と拡張の両方から、App Group に最新30行を残す。
/// 2026-10-01：実機で「数え終わっても開かない」の原因を探すために追加。
enum BlockDebugTrace {
    private static let key = "blockDebugTrace"

    static func add(_ text: String, now: Date) {
        #if DEBUG
        guard let defaults = BlockShared.defaults else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        var lines = defaults.stringArray(forKey: key) ?? []
        lines.append("\(formatter.string(from: now)) \(text)")
        defaults.set(Array(lines.suffix(30)), forKey: key)
        #endif
    }

    static func lines() -> [String] {
        BlockShared.defaults?.stringArray(forKey: key) ?? []
    }
}
