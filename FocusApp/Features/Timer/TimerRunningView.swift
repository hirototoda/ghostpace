import SwiftUI

/// タイマー実行中の全画面（docs/product/features/focus-timer.md）。
/// ホームと同じリング式。円は予定時間に対する進み具合（ストップウォッチは1時間で1周）。
struct TimerRunningView: View {
    let timer: RunningTimer
    /// ホームで選んだ相手（GHO-10）。いなければいる方と比べる
    var opponent: Opponent = .lastWeek
    let onPause: () -> Void
    let onResume: () -> Void
    /// 終了ボタン。止め忘れの疑いがあれば、呼び出し側が終了時刻の確認を出す
    let onEnd: () -> Void
    /// 計画外のタイマー中に始まった計画ブロックに切り替える（TMR-11）
    var onSwitch: ((PlanBlockSummary) -> Void)?
    @Environment(\.clock) private var clock

    private var isPaused: Bool { timer.session.isPaused }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let now = clock.now()
            VStack(spacing: 24) {
                header
                Spacer(minLength: 0)
                hero(now: now)
                if let shown = timer.effectiveOpponent(opponent), let diff = timer.opponentDiffSeconds(shown, at: now) {
                    GhostDiffLine(seconds: diff, prefix: shown.diffPrefix)
                }
                Spacer(minLength: 0)
                if let onSwitch, let block = timer.switchableBlock(at: now) {
                    switchCard(block, onSwitch)
                }
                buttons
            }
            .padding(20)
        }
        .background(Theme.focus.opacity(0.06).ignoresSafeArea())
        .tint(Theme.focus)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text(timer.categoryName)
                .font(.caption.bold())
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(Capsule().fill((timer.countsAsFocus ? Theme.focus : Theme.detox).opacity(0.15)))
            Text(timer.title).font(.title2.bold())
        }
        .padding(.top, 8)
    }

    /// 表示する数字：カウントダウンは残り（0を過ぎたら超過）、ストップウォッチは経過。
    /// 一時停止中は見出しを「一時停止中」にする。数字は計画外なら止まり、計画ブロックなら減り続ける。
    private func reading(at now: Date) -> (caption: String, seconds: Int, overtime: Bool) {
        let paused = isPaused ? "一時停止中" : nil
        if let remaining = timer.remainingSeconds(at: now) {
            return remaining >= 0 ? (paused ?? "残り", remaining, false) : (paused ?? "超過", -remaining, true)
        }
        return (paused ?? "経過", timer.elapsedSeconds(at: now), false)
    }

    private func hero(now: Date) -> some View {
        let r = reading(at: now)
        return VStack(spacing: 16) {
            ZStack {
                Ring(progress: progress(at: now), color: r.overtime ? Theme.lead : Theme.focus, lineWidth: 18)
                VStack(spacing: 4) {
                    Text(r.caption).font(.headline).foregroundStyle(r.overtime && !isPaused ? Theme.lead : .secondary)
                    Text((r.overtime ? "+" : "") + DurationFormat.clock(r.seconds))
                        .font(Theme.heroNumber(56))
                        .foregroundStyle(r.overtime ? Theme.lead : .primary)
                        .lineLimit(1).minimumScaleFactor(0.5)
                        .accessibilityIdentifier("timerReading")
                }
                .padding(40)
            }
            .frame(maxWidth: 300)
            .aspectRatio(1, contentMode: .fit)
            scheduleText(now: now)
        }
    }

    /// カウントダウンは予定に対する進み具合。ストップウォッチは1時間で1周。
    private func progress(at now: Date) -> Double {
        let elapsed = Double(timer.elapsedSeconds(at: now))
        if let remaining = timer.remainingSeconds(at: now) {
            return min(elapsed / max(elapsed + Double(max(remaining, 0)), 1), 1)
        }
        return elapsed.truncatingRemainder(dividingBy: 3600) / 3600
    }

    private func scheduleText(now: Date) -> some View {
        let style = Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
        let start = timer.session.startAt.formatted(style) + " 開始"
        let end = timer.session.plannedEnd(at: now).map { "・" + $0.formatted(style) + " 終了予定" } ?? "・ストップウォッチ"
        return Text(start + end).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
    }

    /// 計画の時刻になった：「11:00 から ゼミ準備の時間です」［ゼミ準備に切り替える］（TMR-11）
    private func switchCard(_ block: PlanBlockSummary, _ onSwitch: @escaping (PlanBlockSummary) -> Void) -> some View {
        let style = Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
        let color = Theme.color(for: block.category)
        return VStack(spacing: 10) {
            Text("\(block.start.formatted(style)) から\(block.title)の時間です")
                .font(.subheadline.bold())
                .multilineTextAlignment(.center)
            Button {
                onSwitch(block)
            } label: {
                Text("\(block.title)に切り替える").font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(color)
            .controlSize(.large)
            .accessibilityIdentifier("switchToBlockButton")
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(color.opacity(0.1)))
    }

    private var buttons: some View {
        HStack(spacing: 12) {
            Button {
                isPaused ? onResume() : onPause()
            } label: {
                Label(isPaused ? "再開" : "一時停止", systemImage: isPaused ? "play.fill" : "pause.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            Button {
                onEnd()
            } label: {
                Label("終了", systemImage: "stop.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("endButton")
        }
        .font(.headline)
        .controlSize(.extraLarge)
    }
}
