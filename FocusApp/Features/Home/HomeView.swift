import SwiftUI

/// ホーム画面。型は「大きな数字＋ボタンだけ」、数字はリング式（docs/product/features/home.md）。
struct HomeView: View {
    let snapshot: HomeSnapshot
    let categories: [CategoryOption]
    /// 「今：〜」のタップで計画の変更を開く（PLN-04）
    var onTapPlan: () -> Void = {}
    /// 今の計画ブロックから開始（ブロック終了までのカウントダウン）
    var onStartBlock: (PlanBlockSummary) -> Void = { _ in }
    /// 計画外で開始。分が nil ならストップウォッチ
    var onStartUnplanned: (CategoryOption, ProjectOption?, Int?) -> Void = { _, _, _ in }
    /// 右上の歯車で設定を開く
    var onOpenSettings: () -> Void = {}
    /// 「今日を振り返る」（REV-01）
    var onOpenReview: () -> Void = {}
    /// 円で比べる相手（GHO-10）
    @Binding var opponent: Opponent
    /// カテゴリをその場で作る（CAT-04）
    var onCreateCategory: ((String, Bool, DetoxGroup?) -> CategoryOption?)?
    /// ブロック名（CAT-03）。計画外の開始で選べる
    var projects: [ProjectOption] = []
    var onCreateProject: ((String, CategoryOption) -> ProjectOption?)?

    @State private var showsStartSheet = false
    /// 見本の撮影用に、計画外で開始のシートを開いて始める（`-openStartSheet`）
    @Environment(\.opensStartSheet) private var opensStartSheet

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 24) {
                    header
                    Spacer(minLength: 0)
                    RingHero(snapshot: snapshot, opponent: $opponent)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .safeAreaInset(edge: .bottom) { footer }
        .onAppear { if opensStartSheet { showsStartSheet = true } }
        .sheet(isPresented: $showsStartSheet) {
            StartSheet(now: snapshot.now, categories: categories, projects: projects, onCreateProject: onCreateProject,
                       onCreateCategory: onCreateCategory) { category, project, minutes in
                showsStartSheet = false
                onStartUnplanned(category, project, minutes)
            }
        }
    }

    private var header: some View {
        HStack {
            Text(snapshot.dayStart.formatted(.dateTime.month().day().weekday(.abbreviated).locale(Locale(identifier: "ja_JP"))))
                .font(.headline)
            Spacer()
            Button("設定", systemImage: "gearshape", action: onOpenSettings)
                .accessibilityIdentifier("settingsButton")
        }
        .labelStyle(.iconOnly)
        .font(.title3)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .padding(.top, 8)
    }

    private var footer: some View {
        VStack(spacing: 12) {
            planLine
            if snapshot.showsReviewEntry {
                Button(action: onOpenReview) {
                    Label("今日を振り返る", systemImage: "moon.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier("reviewButton")
            }
            Button {
                if let block = startableBlock {
                    onStartBlock(block)
                } else {
                    showsStartSheet = true
                }
            } label: {
                Text(startableBlock.map { "\($0.title)を開始" } ?? "カテゴリを選んで開始")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.extraLarge)
            .accessibilityIdentifier("startButton")
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .background(.background)
    }

    @ViewBuilder
    private var planLine: some View {
        if snapshot.isNoPlanDay {
            // あとから計画を作れる（2026-09-30 決定）
            Button(action: onTapPlan) {
                HStack(spacing: 6) {
                    Text("計画なし").font(.subheadline).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("planLine")
            .accessibilityHint("計画を作ります")
        } else if let early = snapshot.earlyStartBlock {
            // 「次」の行の右に「今から始める」（前倒し、TMR-10。2026-10-03 案B）。入りきらない大きな文字では下に回す
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { earlyLine(early) }
                VStack(spacing: 8) { earlyLine(early) }
            }
        } else {
            Button(action: onTapPlan) {
                HStack(spacing: 6) {
                    if let block = snapshot.currentBlock {
                        blockLine("今", block)
                    } else if let block = snapshot.nextBlock {
                        blockLine("次", block)
                    } else {
                        Text("今日の計画は終わりました").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("planLine")
            .accessibilityHint("計画を変更します")
        }
    }

    @ViewBuilder
    private func earlyLine(_ early: PlanBlockSummary) -> some View {
        Button(action: onTapPlan) {
            HStack(spacing: 6) {
                blockLine("次", early)
                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("planLine")
        .accessibilityHint("計画を変更します")
        Button("今から始める") { onStartBlock(early) }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(.subheadline.bold())
            .accessibilityIdentifier("startEarlyButton")
    }

    private func blockLine(_ prefix: String, _ block: PlanBlockSummary) -> some View {
        HStack(spacing: 8) {
            Text(prefix)
                .font(.caption.bold())
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(Capsule().fill(Theme.color(for: block.category).opacity(0.15)))
            if block.category.isUnblock {
                Image(systemName: "gamecontroller.fill").imageScale(.small).foregroundStyle(Theme.play)
            }
            Text(block.title).fontWeight(.semibold)
            Text(timeRange(block.start, block.end)).foregroundStyle(.secondary).monospacedDigit()
        }
        .font(.subheadline)
    }

    /// 今の計画ブロック。あれば1タップでブロック終了までのカウントダウンを始める。
    /// ゲーム・SNS の時間（BLK-10）はタイマーを始めないので、「カテゴリを選んで開始」のまま
    private var startableBlock: PlanBlockSummary? {
        guard !snapshot.isNoPlanDay, let block = snapshot.currentBlock, !block.category.isUnblock else { return nil }
        return block
    }
}

extension EnvironmentValues {
    @Entry var opensStartSheet = false
}

func timeRange(_ start: Date, _ end: Date) -> String {
    let style = Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
    return "\(start.formatted(style))–\(end.formatted(style))"
}
