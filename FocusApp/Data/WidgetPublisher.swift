import Foundation
import WidgetKit

/// ウィジェット（WID-01）に材料を渡す。本物は App Group の UserDefaults に書き、ウィジェットに描き直しを頼む。
@MainActor
protocol WidgetPublishing: AnyObject {
    func publish(_ snapshot: WidgetSnapshot)
}

/// テスト・見本データ用。最後に渡したものを持つだけ
@MainActor
final class MemoryWidgetPublisher: WidgetPublishing {
    private(set) var published: [WidgetSnapshot] = []
    func publish(_ snapshot: WidgetSnapshot) { published.append(snapshot) }
}

@MainActor
final class AppGroupWidgetPublisher: WidgetPublishing {
    private let defaults: UserDefaults?
    private var lastKey: WidgetSnapshot?

    init(defaults: UserDefaults? = UserDefaults(suiteName: BlockShared.appGroup)) {
        self.defaults = defaults
    }

    /// 毎分の読み直しで描き直しを頼みすぎないよう、表示が変わるとき（予定・タイマー・先週の進み方、タイマーなしの集中）だけ頼む
    func publish(_ snapshot: WidgetSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults?.set(data, forKey: WidgetSnapshot.key)
        var key = snapshot
        key.generatedAt = .distantPast
        if snapshot.runningStart != nil { key.focusSeconds = 0; key.runningStart = .distantPast }
        guard key != lastKey else { return }
        lastKey = key
        WidgetCenter.shared.reloadAllTimelines()
    }
}
