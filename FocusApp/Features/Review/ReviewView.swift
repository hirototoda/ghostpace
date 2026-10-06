import SwiftUI

/// 夜の振り返り（REV-01、docs/product/features/review.md）。数字だけの1枚で、メモは取らない（2026-10-01 オーナー案）。
struct ReviewView: View {
    let content: ReviewContent
    let onPlanTomorrow: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    resultCard
                    verdictCard
                    if !content.opponents.isEmpty { opponentCard }
                    gapSection
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .safeAreaInset(edge: .bottom) {
                Button(action: onPlanTomorrow) {
                    Text("明日の計画を立てる").font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.extraLarge)
                .padding(.horizontal, 20).padding(.vertical, 8)
                .background(.bar)
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                .accessibilityIdentifier("planTomorrowButton")
            }
            .navigationTitle("今日の振り返り")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる", systemImage: "xmark") { dismiss() }
                }
            }
        }
        .tint(Theme.focus)
    }

    // MARK: 今日の結果

    private var resultCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(content.dayStart.formatted(.dateTime.month().day().weekday(.wide).locale(Locale(identifier: "ja_JP"))))
                .font(.headline)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 24) { totals }
                VStack(alignment: .leading, spacing: 8) { totals }
            }
            if !content.categories.isEmpty {
                let maxSeconds = max(content.categories.first?.seconds ?? 1, 1)
                VStack(spacing: 8) {
                    ForEach(content.categories) { item in
                        CategoryBar(item: item, maxSeconds: maxSeconds)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
    }

    @ViewBuilder
    private var totals: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("集中").font(.caption).foregroundStyle(.secondary)
            DurationText(seconds: content.focusSeconds, size: 34)
                .accessibilityIdentifier("reviewFocus")
        }
        if let opened = content.opened {
            VStack(alignment: .leading, spacing: 4) {
                Text("ゲーム・SNS").font(.caption).foregroundStyle(.secondary)
                OpenedLabel(opened: opened)
            }
        }
    }

    // MARK: 先週の自分との勝ち負け（GHO-04）

    private var verdictCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("先週の自分と").font(.headline)
                Spacer()
                Text("今のところ・確定は朝4:00").font(.caption2).foregroundStyle(.tertiary)
            }
            if content.verdicts.isEmpty {
                Text(content.hasOlderHistory ? "おかえりなさい。先週はお休みでした。来週から勝ち負けが出ます"
                                             : "先週の記録がないので、来週から勝ち負けが出ます")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(content.verdicts) { verdict in
                VerdictRow(verdict: verdict)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
        .accessibilityIdentifier("verdictCard")
    }

    // MARK: 目標との差

    private var opponentCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(content.opponents, id: \.opponent) { item in
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) { opponentLine(item) }
                    VStack(alignment: .leading, spacing: 2) { opponentLine(item) }
                }
                .accessibilityElement(children: .combine)
            }
            Text("確定は朝4:00です").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
    }

    @ViewBuilder
    private func opponentLine(_ item: ReviewContent.OpponentDiff) -> some View {
        Text(item.opponent.diffPrefix).foregroundStyle(.secondary)
        Text(DurationFormat.signed(item.diffSeconds)).font(.title3.bold().monospacedDigit())
            .foregroundStyle(Theme.diffColor(item.diffSeconds))
        Spacer(minLength: 0)
        Text("\(item.opponent.shortName) \(DurationFormat.japanese(item.theirSeconds))")
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
    }

    // MARK: 朝の計画とのズレ

    private var gapSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("朝の計画とズレたところ").font(.headline)
            if content.isNoPlanDay {
                Text("今日は計画なしの日でした").foregroundStyle(.secondary)
            } else if content.gaps.isEmpty {
                Text("大きなズレはありませんでした").foregroundStyle(.secondary)
            }
            ForEach(content.gaps) { gap in
                GapRow(gap: gap)
            }
        }
        .accessibilityIdentifier("reviewGaps")
    }
}

private struct CategoryBar: View {
    let item: ReviewContent.CategoryTotal
    let maxSeconds: Int
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                // 大きな文字では、名前と時間を上に、棒を下に
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(item.name).font(.subheadline)
                        Spacer()
                        time
                    }
                    bar
                }
            } else {
                HStack(spacing: 8) {
                    Text(item.name).font(.subheadline).lineLimit(1).frame(minWidth: 48, alignment: .leading)
                    bar
                    time
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var bar: some View {
        GeometryReader { proxy in
            Capsule().fill(item.countsAsFocus ? Theme.focus : Theme.detox)
                .frame(width: max(4, proxy.size.width * Double(item.seconds) / Double(maxSeconds)))
        }
        .frame(height: 8)
    }

    private var time: some View {
        Text(DurationFormat.japanese(item.seconds)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            .lineLimit(1).fixedSize()
    }
}

private struct GapRow: View {
    let gap: ReviewGap

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                detail
                Spacer()
                diff
            }
            VStack(alignment: .leading, spacing: 6) {
                detail
                diff
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
        .accessibilityElement(children: .combine)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(gap.title).font(.headline)
                Text(timeRange(gap.block.startAt, gap.block.endAt)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text("予定 \(DurationFormat.japanese(gap.plannedSeconds)) → 実際 \(DurationFormat.japanese(gap.actualSeconds))")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var diff: some View {
        Text(DurationFormat.signed(gap.diffSeconds)).font(.title3.bold().monospacedDigit())
            .foregroundStyle(Theme.diffColor(gap.diffSeconds))
    }
}

/// 初めて朝の計画を確定した直後に1回だけ出す、通知の説明（TMR-05、2026-10-01 決定）。
struct NotificationIntroSheet: View {
    let reviewMinutes: Int
    let onEnable: () -> Void
    let onLater: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "bell.badge")
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.focus)
                    .padding(.top, 28)
                    .accessibilityHidden(true)
                Text("時間になったら知らせます").font(.title2.bold()).multilineTextAlignment(.center)
                VStack(alignment: .leading, spacing: 12) {
                    Label("計画ブロックが始まる前と終わりの時刻、計画外のタイマー中に次の計画の時刻が来たときに知らせます（アプリを閉じていても）",
                          systemImage: "timer")
                    Label("夜 \(String(format: "%d:%02d", reviewMinutes / 60, reviewMinutes % 60)) に「今日を振り返る」を知らせます",
                          systemImage: "moon.stars")
                    Label("ブロック中のアプリで「開く」を押したときに、長押しの画面へ案内します", systemImage: "lock.open")
                    Label("それ以外の通知は送りません", systemImage: "hand.raised")
                }
                .font(.subheadline)
                .padding(.horizontal, 8)
            }
            .padding(24)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                Button(action: onEnable) {
                    Text("通知をオンにする").font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.extraLarge)
                .accessibilityIdentifier("enableNotificationsIntroButton")
                Button("あとで", action: onLater)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityIdentifier("notificationsLaterButton")
            }
            .padding(.horizontal, 24).padding(.bottom, 8)
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled()
        .tint(Theme.focus)
    }
}

/// 勝ち負けの1行：項目、自分の値と先週の値、勝ち・負け・引き分け。リードは前向きな色、負けは落ち着いた色
private struct VerdictRow: View {
    let verdict: ReviewContent.Verdict
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        layout {
            Text(verdict.item.label).font(.subheadline.bold())
                .frame(minWidth: dynamicTypeSize.isAccessibilitySize ? nil : 72, alignment: .leading)
            values
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 4) }
            badge
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var values: some View {
        if let theirs = verdict.theirs {
            Text("\(text(verdict.mine))  vs 先週 \(text(theirs))")
                .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
        } else {
            Text("\(text(verdict.mine))  先週の記録なし").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var badge: some View {
        switch verdict.result {
        case .win: tag("勝ち", Theme.lead, filled: true)
        case .lose: tag("負け", Theme.behind, filled: false)
        case .draw: tag("引き分け", Theme.behind, filled: false)
        case .noRecord: EmptyView()
        }
    }

    private func tag(_ title: String, _ color: Color, filled: Bool) -> some View {
        Text(title).font(.caption.bold())
            .padding(.horizontal, 10).padding(.vertical, 3)
            .foregroundStyle(filled ? Color(.systemBackground) : color)
            .background(Capsule().fill(filled ? color : color.opacity(0.15)))
    }

    private func text(_ value: Double) -> String {
        verdict.item == .points ? RaceChart.pointText(value) : DurationFormat.japanese(Int(value))
    }
}
