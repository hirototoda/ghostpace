import SwiftUI
import WidgetKit

/// ホーム画面・ロック画面のウィジェット（WID-01、docs/product/features/home.md「ウィジェット」）。
/// 本体が App Group に書いたその日の材料（WidgetSnapshot）から、15分ごとの表示を作る。押すとアプリが開く。
struct GhostPaceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "GhostPaceWidget", provider: GhostPaceProvider()) { entry in
            GhostPaceFamilyView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("GhostPace")
        .description("次の予定と、先週の自分との差")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

struct GhostPaceProvider: TimelineProvider {
    private var snapshot: WidgetSnapshot? {
        WidgetSnapshot.load(from: UserDefaults(suiteName: WidgetSnapshot.appGroup))
    }

    func placeholder(in context: Context) -> GhostPaceEntry {
        GhostPaceEntry(date: SystemClock().now(), content: WidgetSnapshot.Entry(
            line: .next(.init(title: "ゼミ準備", start: SystemClock().now().addingTimeInterval(1800), end: SystemClock().now().addingTimeInterval(9000), isGameTime: false)),
            focusSeconds: 5100, ghostSeconds: 3900, isStale: false))
    }

    func getSnapshot(in context: Context, completion: @escaping (GhostPaceEntry) -> Void) {
        let now = SystemClock().now()
        completion(context.isPreview && snapshot == nil ? placeholder(in: context)
                   : GhostPaceEntry(date: now, content: snapshot?.entry(at: now)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GhostPaceEntry>) -> Void) {
        let now = SystemClock().now()
        guard let snapshot else {
            return completion(Timeline(entries: [GhostPaceEntry(date: now, content: nil)], policy: .never))
        }
        let entries = snapshot.entryDates(from: now).map { GhostPaceEntry(date: $0, content: snapshot.entry(at: $0)) }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

/// 置いた場所（大きさ）を読んで、共有の表示に渡す
struct GhostPaceFamilyView: View {
    let entry: GhostPaceEntry
    @Environment(\.widgetFamily) private var family

    var body: some View { GhostPaceWidgetView(entry: entry, family: family) }
}
