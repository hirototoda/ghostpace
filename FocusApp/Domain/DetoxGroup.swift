import Foundation

/// デトックスのタイマーのグループ（DTX-03、digital-detox.md「タイマーの上限」）。グループごとに1日の上限まで1.5倍で数える。
enum DetoxGroup: String, Hashable, CaseIterable {
    case housework, exercise, rest

    /// 1.5倍で数える1日の上限（秒）
    var dailyCap: TimeInterval {
        switch self {
        case .housework: 3600
        case .exercise: 3 * 3600
        case .rest: 3600
        }
    }

    /// カテゴリのグループ（カテゴリに保存した値）。集中のカテゴリ・ゲーム・SNS・「なし」は nil（上乗せなし）
    static func of(_ category: CategoryOption) -> DetoxGroup? {
        category.countsAsDetox ? category.detoxGroup : nil
    }
}
