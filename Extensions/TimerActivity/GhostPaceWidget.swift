import SwiftUI
import WidgetKit

/// ホーム画面・ロック画面のウィジェット（WID-01、docs/product/features/home.md「ウィジェット」）。
/// 本体が App Group に書いたその日の材料（WidgetSnapshot）から、15分ごとの表示を作る。押すとアプリが開く。
struct GhostPaceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "GhostPaceWidget", provider: GhostPaceProvider()) { entry in
            GhostPaceWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("GhostPace")
        .description("次の予定と、先週の自分との差")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

struct GhostPaceEntry: TimelineEntry {
    var date: Date
    var content: WidgetSnapshot.Entry?
}

struct GhostPaceProvider: TimelineProvider {
    private var snapshot: WidgetSnapshot? {
        WidgetSnapshot.load(from: UserDefaults(suiteName: "group.com.hirototoda.focusapp"))
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

struct GhostPaceWidgetView: View {
    let entry: GhostPaceEntry
    @Environment(\.widgetFamily) private var family

    private static let time = Date.FormatStyle.dateTime.hour(.defaultDigits(amPM: .omitted)).minute(.twoDigits)

    var body: some View {
        switch family {
        case .accessoryInline: Text(lineText)
        case .accessoryRectangular: rectangular
        case .systemMedium: medium
        default: small
        }
    }

    /// 例：次 11:00 ゼミ準備／今 ゼミ準備 〜13:00
    private var lineText: String {
        guard let content = entry.content else { return "GhostPace を開くと今日の予定が出ます" }
        if content.isStale { return "GhostPace を開くと今日の予定が出ます" }
        switch content.line {
        case .now(let block): return "今 \(name(block)) 〜\(block.end.formatted(Self.time))"
        case .next(let block): return "次 \(block.start.formatted(Self.time)) \(name(block))"
        case .none: return "次の予定はありません"
        }
    }

    private func name(_ block: WidgetSnapshot.Block) -> String { block.isGameTime ? "🎮 ゲーム・SNS" : block.title }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("GhostPace").font(.caption2).foregroundStyle(.secondary)
            Text(lineText).font(.headline).lineLimit(2)
            if case .next(let block)? = entry.content?.line, entry.content?.isStale == false {
                Text("〜\(block.end.formatted(Self.time))").font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var diff: some View {
        if let content = entry.content, !content.isStale, let diff = content.diffSeconds {
            VStack(alignment: .leading, spacing: 0) {
                Text("先週より").font(.caption2).foregroundStyle(.secondary)
                Text(DurationFormat.signed(diff)).font(.title2.bold().monospacedDigit())
                    .foregroundStyle(Theme.diffColor(diff))
                    .minimumScaleFactor(0.6).lineLimit(1)
            }
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(lineText).font(.subheadline.bold()).lineLimit(3)
            Spacer(minLength: 0)
            diff
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(lineText).font(.headline).lineLimit(3)
                Spacer(minLength: 0)
                diff
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let content = entry.content, !content.isStale {
                VStack(alignment: .leading, spacing: 8) {
                    labeled("今日の集中", DurationFormat.japanese(content.focusSeconds), Theme.focus)
                    if let ghost = content.ghostSeconds { labeled("先週のこの時刻", DurationFormat.japanese(ghost), .secondary) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func labeled(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.bold().monospacedDigit()).foregroundStyle(color)
        }
    }
}
