import SwiftUI

/// ロック画面と画面上部のタイマーの部品（focus-timer.md TMR-06）。本体と拡張（TimerActivity）の両方に入る。
/// 本体では DEBUG の見本（案の比較）に使う。

extension TimerActivityAttributes {
    var tint: Color { countsAsFocus ? Theme.focus : Theme.detox }
}

/// ロック画面と画面上部は iPhone が高さを決めていて広げられないので、文字の大きさに上限を付ける
let timerActivityMaxTypeSize = DynamicTypeSize.xxLarge

/// 大きな数字。動いている間は iPhone が自分で数える（0を過ぎたら超過を数え上げる）。
struct TimerReadingText: View {
    let reading: TimerActivityAttributes.Reading

    var body: some View {
        switch reading {
        case .countdown(let date):
            Text(date, style: .timer)
        case .countUp(let date):
            Text(date, style: .timer)
        case .fixed(let seconds, let overtime):
            Text((overtime ? "+" : "") + DurationFormat.clock(seconds))
        }
    }
}

/// 進み具合の円。ストップウォッチは円の代わりにストップウォッチの印。
struct TimerProgressRing: View {
    let progress: TimerActivityAttributes.Progress
    let tint: Color
    var lineWidth: CGFloat = 5

    var body: some View {
        switch progress {
        case .live(let start, let end):
            #if TIMER_WIDGET
            // ロック画面・画面上部では iPhone が時刻から円を進める
            ProgressView(timerInterval: start...max(start, end), countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .progressViewStyle(.circular)
            .tint(tint)
            #else
            // アプリの中（見本）では円の形にならないので、1秒ごとに描く
            TimelineView(.periodic(from: start, by: 1)) { context in
                let total = end.timeIntervalSince(start)
                ring(total > 0 ? context.date.timeIntervalSince(start) / total : 1)
            }
            #endif
        case .fixed(let value):
            ring(value)
        case .none:
            Image(systemName: "stopwatch").foregroundStyle(tint)
        }
    }

    private func ring(_ value: Double) -> some View {
        ZStack {
            Circle().stroke(tint.opacity(0.25), lineWidth: lineWidth)
            Circle().trim(from: 0, to: min(max(value, 0), 1))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
    }
}

/// ロック画面に出す1枚（2026-10-01 案B）：左に進み具合の円、名前と見出し、右に数字。
struct TimerLockScreenView: View {
    let attributes: TimerActivityAttributes
    let state: TimerActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            TimerProgressRing(progress: state.progress, tint: attributes.tint, lineWidth: 6)
                .frame(width: 52, height: 52)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(attributes.title).font(.headline).lineLimit(1)
                Text(attributes.categoryName + "・" + state.caption).font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            Spacer(minLength: 8)
            TimerReadingText(reading: state.reading)
                .font(Theme.heroNumber(34))
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 150, alignment: .trailing)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .dynamicTypeSize(...timerActivityMaxTypeSize)
    }
}
