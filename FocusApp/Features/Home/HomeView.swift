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
    /// 今のブロックを遅れて始めるとき「開始から始めていた」にできる開始（TMR-13）。nil なら聞かずに始める
    var lateStart: (PlanBlockSummary) -> Date? = { _ in nil }
    /// 「〜から始めていた（申告）」：ブロックの開始〜今を申告にして、今から始める
    var onStartFromBlockStart: (PlanBlockSummary) -> Void = { _ in }

    /// 円のカードの下と上に残す高さ：日付の行・差・予想ゴールの2行・開けた時間・間（実測で約240pt）。
    /// 下の帯（計画の行が最大3行）は safeAreaInset で別に引かれるので、ここでは数えない
    static let linesUnderCard: CGFloat = 240
    static let minCardHeight: CGFloat = 260

    @State private var showsStartSheet = false
    /// 遅れて始めるときに聞いているブロックと、その開始
    @State private var lateChoice: LateChoice?

    private struct LateChoice: Identifiable {
        var block: PlanBlockSummary
        var start: Date
        var id: UUID { block.id }
        /// 例：11:00
        var startText: String { start.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute(.twoDigits)) }
    }
    /// 見本の撮影用に、計画外で開始のシートを開いて始める（`-openStartSheet`）
    @Environment(\.opensStartSheet) private var opensStartSheet

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 24) {
                    header
                    Spacer(minLength: 0)
                    RingHero(snapshot: snapshot, opponent: $opponent,
                             maxCardHeight: max(Self.minCardHeight, proxy.size.height - Self.linesUnderCard))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .safeAreaInset(edge: .bottom) { footer }
        .onAppear { if opensStartSheet { showsStartSheet = true } }
        .confirmationDialog("いつから始めましたか？", isPresented: Binding(get: { lateChoice != nil }, set: { if !$0 { lateChoice = nil } }),
                            titleVisibility: .visible, presenting: lateChoice) { choice in
            Button("今から始める") { onStartBlock(choice.block) }
            Button("\(choice.startText) から始めていた（申告）") { onStartFromBlockStart(choice.block) }
            Button("キャンセル", role: .cancel) {}
        } message: { choice in
            Text("押し忘れていたときは、\(choice.startText) からの分を申告にできます（点は少し控えめ）。")
        }
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
                    // 開始から5分以上たって始めるときは「今から／開始から始めていた」を聞く（TMR-13、案A）
                    if let start = lateStart(block) {
                        lateChoice = LateChoice(block: block, start: start)
                    } else {
                        onStartBlock(block)
                    }
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
        } else {
            VStack(spacing: 8) {
                // さっき終わったブロックを遅れて始める（TMR-15）
                if let missed = snapshot.recentMissedBlock { actionLine("さっき", missed, identifier: "startMissedButton") }
                if let current = snapshot.currentBlock {
                    planButton { blockLine("今", current) }
                }
                if let early = snapshot.earlyStartBlock {
                    // 「次」の行の右に「今から始める」（前倒し、TMR-10。2026-10-03 案B。今のブロックの最中も、TMR-15）
                    actionLine("次", early, identifier: "startEarlyButton")
                } else if snapshot.currentBlock == nil {
                    planButton {
                        if let block = snapshot.nextBlock {
                            blockLine("次", block)
                        } else {
                            Text("今日の計画は終わりました").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    /// 押すと計画のタブへ（PLN-04）
    private func planButton<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Button(action: onTapPlan) {
            HStack(spacing: 6) {
                content()
                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("planLine")
        .accessibilityHint("計画を変更します")
    }

    /// 行の右に「今から始める」。入りきらない大きな文字では下に回す
    private func actionLine(_ prefix: String, _ block: PlanBlockSummary, identifier: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { actionContent(prefix, block, identifier: identifier) }
            VStack(spacing: 8) { actionContent(prefix, block, identifier: identifier) }
        }
    }

    @ViewBuilder
    private func actionContent(_ prefix: String, _ block: PlanBlockSummary, identifier: String) -> some View {
        planButton { blockLine(prefix, block) }
        Button("今から始める") { onStartBlock(block) }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(.subheadline.bold())
            .accessibilityIdentifier(identifier)
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
