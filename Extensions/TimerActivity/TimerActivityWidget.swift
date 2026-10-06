import ActivityKit
import SwiftUI
import WidgetKit

/// ロック画面と画面上部（Dynamic Island）のタイマー（focus-timer.md TMR-06）。
/// 見るだけ。押すとアプリのタイマー画面が開く。
@main
struct TimerActivityBundle: WidgetBundle {
    var body: some Widget {
        TimerActivityWidget()
        GhostPaceWidget()
    }
}

struct TimerActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TimerActivityAttributes.self) { context in
            TimerLockScreenView(attributes: context.attributes, state: context.state)
                .padding(16)
        } dynamicIsland: { context in
            let tint = context.attributes.tint
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    TimerProgressRing(progress: context.state.progress, tint: tint, lineWidth: 5)
                        .frame(width: 44, height: 44)
                        .font(.title3)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TimerReadingText(reading: context.state.reading)
                        .font(Theme.heroNumber(32))
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 140, alignment: .trailing)
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .dynamicTypeSize(...timerActivityMaxTypeSize)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.title).font(.headline).lineLimit(1)
                        .dynamicTypeSize(...timerActivityMaxTypeSize)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.attributes.categoryName + "・" + context.state.caption)
                        .font(.subheadline).foregroundStyle(.secondary)
                        .dynamicTypeSize(...timerActivityMaxTypeSize)
                }
            } compactLeading: {
                TimerProgressRing(progress: context.state.progress, tint: tint, lineWidth: 3)
                    .frame(width: 20, height: 20)
                    .font(.caption)
            } compactTrailing: {
                TimerReadingText(reading: context.state.reading)
                    .font(.callout.bold().monospacedDigit())
                    .foregroundStyle(tint)
                    .multilineTextAlignment(.trailing)
                    .frame(minWidth: 40, maxWidth: 80, alignment: .trailing)
                    .dynamicTypeSize(...DynamicTypeSize.large)
            } minimal: {
                TimerProgressRing(progress: context.state.progress, tint: tint, lineWidth: 3)
                    .frame(width: 20, height: 20)
                    .font(.caption)
            }
            .keylineTint(tint)
        }
    }
}
