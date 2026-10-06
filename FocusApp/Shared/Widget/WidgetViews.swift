import SwiftUI
import WidgetKit

/// ウィジェット（WID-01）の表示。拡張（TimerActivity）と、本体の DEBUG の見本（-widgetGallery）で共有する

struct GhostPaceEntry: TimelineEntry {
    var date: Date
    var content: WidgetSnapshot.Entry?
}

struct GhostPaceWidgetView: View {
    let entry: GhostPaceEntry
    /// 置いた場所（大きさ）。ウィジェットでは環境から、本体の見本では引数で渡す
    let family: WidgetFamily

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
