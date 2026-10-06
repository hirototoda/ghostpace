import SwiftUI

/// 1日の計画（docs/product/features/daily-plan.md）。
/// 朝は全画面で出て、「確定」か「今日は計画しない」を押すまで閉じない。日中は下の「計画」のタブで直す（NAV-01）。
struct DailyPlanView: View {
    enum Mode {
        /// その日最初の起動（4:00以降）。確定するとスナップショットを保存する（PLN-03）
        case morning
        /// 計画のタブ（PLN-04）。直すとすぐ保存する。朝のスナップショットは変わらない
        case tab
        /// 夜の振り返りから開く明日の計画（REV-01）。下書きとして保存し、翌朝の朝の計画に出る
        case tomorrow
    }

    let mode: Mode
    let dayStart: Date
    let now: Date
    @State var plan: PlanDraft
    let categories: [CategoryOption]
    let projects: [ProjectOption]
    /// ブロック名をその場で作る（CAT-03）
    let onCreateProject: (String, CategoryOption) -> ProjectOption?
    /// カテゴリをその場で作る（CAT-04）
    var onCreateCategory: ((String, Bool, DetoxGroup?) -> CategoryOption?)?
    /// 計画が変わるたびに呼ぶ（朝・明日は下書き、タブは計画を保存する）
    var onChange: (PlanDraft) -> Void = { _ in }
    var onConfirm: (PlanDraft) -> Void = { _ in }
    /// 朝：今日は計画しない（計画なし日、PLN-05。決めた目標を渡す）／明日：閉じる
    var onDismiss: (_ goalSeconds: Int?) -> Void = { _ in }
    /// 保存に失敗したときの知らせ。ブロックの追加シートを開いている間はシートの上に出す
    @Binding var errorMessage: String?
    /// タブ：保存されている計画。外で変わったら（朝の確定など）画面にも反映する
    var storedPlan: PlanDraft?
    /// ブロックがないときの、最初のブロックの開始の初期値（明日の計画は 8:00）
    var firstStart: Date?
    /// 今日の目標（GHO-10）の行を出すか
    var showsGoal = false
    /// 朝の計画で読み込めるテンプレート（PLN-07）
    var templates: [PlanTemplate] = []
    var calendar: Calendar = .app(timeZone: .current)
    /// 「この計画をテンプレートとして保存」（名前, 計画）。保存できたら true。nil なら出さない
    var onSaveAsTemplate: ((String, PlanDraft) -> Bool)?
    /// タブ：テンプレートを押したときに開く画面（名前と中身を直す）
    var templateEditor: ((PlanTemplate) -> AnyView)?
    /// その日の朝に終わった睡眠（DTX-02）。nil なら行を出さない
    var sleep: SleepRowModel?
    /// その日に当てはめた習慣（PLN-08）。テンプレートを読み込んでも残す
    var habitDraft = PlanDraft()
    /// 足せる候補（PLN-09）。今の計画を渡して求める
    var candidates: (PlanDraft) -> [PlanCandidate] = { _ in [] }
    /// タブ：「習慣」の行（中身と、押したときに開く画面）。nil なら出さない
    var habits: PlanHabits?
    var habitsEditor: (() -> AnyView)?
    /// 起きている時間（格子で寝ている時間を灰色にする、PLN-10）。nil なら1日全部
    var awake: ClosedRange<Date>?
    /// 押し忘れの申告（TMR-13、計画のタブだけ）：申告できない理由と、申告する操作
    var declarationProblem: ((PlanBlockDraft, Date) -> Declaration.Problem?)?
    var onDeclare: ((PlanBlockDraft, Date) -> Bool)?
    /// 終わったブロックを遅れて始める（TMR-15、計画のタブだけ）：始められるか、始める操作
    var canStartLate: ((PlanBlockDraft) -> Bool)?
    var onStartLate: ((PlanBlockDraft) -> Void)?
    @State private var gridProblem: String?
    @State private var editsSleep = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var editing: EditorTarget?
    @State private var undo: TemplateUndo?
    /// 計画のタブで押したテンプレート（中身と「今日はこれで進む」を出す）
    @State private var previewing: PlanTemplate?
    @State private var namesTemplate = false
    @State private var templateName = ""

    struct TemplateUndo: Equatable {
        /// 例：「理想の休日」を読み込みました
        var message: String
        var previous: PlanDraft
    }

    private struct EditorTarget: Identifiable {
        var block: PlanBlockDraft
        var isNew: Bool
        var id: UUID { block.id }
    }

    var body: some View {
        // 候補は描くたびに1回だけ求める（昨日・先週の計画を読むため）
        let shown = self.candidates(plan)
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        card {
                            summary
                            if let sleep {
                                Divider()
                                sleepRow(sleep).padding(.vertical, 10)
                            }
                            if showsGoal {
                                Divider()
                                goalRow.padding(.vertical, 10)
                            }
                        }
                        if mode != .tab, !templates.isEmpty {
                            card(header: "テンプレートから") { templateBar }
                        }
                        planCard
                        if !shown.isEmpty { candidateSection(shown) }
                        if mode == .tab, let habits, let habitsEditor {
                            card {
                                NavigationLink {
                                    habitsEditor()
                                } label: {
                                    HStack {
                                        HabitsRow(habits: habits)
                                        Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .padding(.vertical, 8)
                                .accessibilityIdentifier("habitsRow")
                            }
                        }
                        if mode == .tab, templateEditor != nil { templateCard }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                }
                .background(Color(.systemGroupedBackground))
                .onAppear {
                    // 朝・明日は起きた時刻、計画のタブは今の時刻のあたりから見せる
                    proxy.scrollTo("hour-\(initialHour)", anchor: .center)
                }
            }
            .background {
                // シートは1つの View に1つまで。ブロックの編集とは別の階層から出す
                Color.clear.sheet(item: $previewing) { template in
                    TemplatePreviewSheet(template: template, plan: template.draft(dayStart: dayStart, calendar: calendar),
                                         now: now, editor: templateEditor) {
                        applyFuture(template)
                        previewing = nil
                    }
                }
            }
            .alert("テンプレートとして保存", isPresented: $namesTemplate) {
                TextField("名前（例：平日）", text: $templateName)
                Button("キャンセル", role: .cancel) {}
                Button("保存") { _ = onSaveAsTemplate?(templateName, plan) }
            } message: {
                Text("この計画の時刻と長さを、ほかの日にも使えるように残します。")
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(mode == .tab ? .inline : .large)
            .toolbar {
                if mode == .tomorrow {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("閉じる", systemImage: "xmark") { onDismiss(plan.goalSeconds) }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    if let gridProblem { problemBanner(gridProblem) }
                    if let undo { undoBanner(undo) }
                    if mode != .tab { bottomButtons }
                }
                .animation(.easeOut(duration: 0.25), value: undo)
                .animation(.easeOut(duration: 0.25), value: gridProblem)
            }
            .sheet(item: $editing) { target in
                BlockEditorSheet(block: target.block, isNew: target.isNew, plan: plan, dayStart: dayStart,
                                 categories: categories, projects: projects, onCreateProject: onCreateProject,
                                 onCreateCategory: onCreateCategory,
                                 showsUnblock: plan.remainingUnblocks > 0 || target.block.isUnblock,
                                 isConfirmedDay: mode == .tab, now: now,
                                 onEndNow: {
                                     plan.endUnblock(id: target.block.id, now: now)
                                     editing = nil
                                 },
                                 declaration: target.isNew ? nil : declarationOption(for: target.block),
                                 onStartNow: startLateAction(for: target)) { saved in
                    plan.upsert(saved)
                    editing = nil
                } onDelete: {
                    delete(target.block)
                    editing = nil
                }
                .saveErrorAlert($errorMessage)
            }
            .saveErrorAlert($errorMessage, when: editing == nil)
        }
        .tint(Theme.focus)
        .interactiveDismissDisabled(mode == .morning)
        .onChange(of: plan) { _, newValue in
            if newValue != storedPlan { onChange(newValue) }
        }
        .onChange(of: storedPlan) { _, newValue in
            if let newValue, newValue != plan { plan = newValue }
        }
    }

    // MARK: 時間の格子（PLN-10）

    private var gridLayout: PlanGridLayout { PlanGridLayout(dayStart: dayStart, hourHeight: PlanGridLayout.hourHeight) }

    /// 開いたときに見せる時刻（4:00 からの時間）。朝・明日は起きた時刻、計画のタブは今の1時間前
    private var initialHour: Int {
        PlanGridLayout.initialHour(confirmedDay: mode == .tab, now: now, wake: awake?.lowerBound ?? dayStart, dayStart: dayStart)
    }

    private var planCard: some View {
        card(footer: mode == .tab ? "直すとすぐ保存します。朝に確定した計画は、振り返りのためにそのまま残ります。" : nil) {
            if plan.blocks.isEmpty {
                Text("空いた時間を押すか「ブロックを追加」で、今日やることを入れます。長押しで動かし、下の端で長さを変えます。")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 8)
            }
            Button {
                editing = newBlockTarget
            } label: {
                Label("ブロックを追加", systemImage: "plus.circle.fill").font(.headline)
            }
            .padding(.vertical, 10)
            .accessibilityIdentifier("addBlockButton")
            PlanGridView(blocks: plan.sortedBlocks, layout: gridLayout, now: now,
                         showsNow: mode != .tomorrow, awake: awake ?? dayStart...gridLayout.dayEnd,
                         confirmedDay: mode == .tab, isLocked: isLockedUnblock,
                         onTap: { editing = EditorTarget(block: $0, isNew: false) },
                         onTapEmpty: { start in
                             editing = EditorTarget(block: PlanBlockDraft(start: start, minutes: PlanDraft.defaultMinutes,
                                                                          category: categories.first ?? .unknown), isNew: true)
                         },
                         onCommit: commitFromGrid, calendar: calendar)
                .padding(.vertical, 8)
            if onSaveAsTemplate != nil, !plan.blocks.isEmpty, mode != .tab {
                Divider()
                saveAsTemplateButton.padding(.vertical, 10)
            }
        }
    }

    /// 終わったブロックを今から始めるボタン（計画のタブで、開始から1時間以内・記録なし）
    private func startLateAction(for target: EditorTarget) -> (() -> Void)? {
        guard mode == .tab, !target.isNew, let canStartLate, let onStartLate, canStartLate(target.block) else { return nil }
        return {
            editing = nil
            onStartLate(target.block)
        }
    }

    /// 押し忘れの申告を出すか（終わった朝の計画のブロックで記録がないとき。重なりなどで申告できないときも理由を出す）
    private func declarationOption(for block: PlanBlockDraft) -> DeclarationOption? {
        guard mode == .tab, let declarationProblem, let onDeclare else { return nil }
        let shown: Set<Declaration.Problem?> = [nil, .invalidEnd, .overlapsRecord, .opened]
        guard shown.contains(declarationProblem(block, block.end)) else { return nil }
        return DeclarationOption(problem: { declarationProblem(block, $0) }) { end in
            guard onDeclare(block, end) else { return false }
            editing = nil
            return true
        }
    }

    /// 格子で動かした・長さを変えたブロック。重なる・4:00 をまたぐときは元のまま理由を出す
    private func commitFromGrid(_ block: PlanBlockDraft) {
        if let reason = plan.problem(with: block, dayStart: dayStart) {
            gridProblem = reason
        } else {
            plan.upsert(block)
        }
    }

    private var templateCard: some View {
        card(header: "テンプレート",
             footer: "最大\(PlanTemplate.maxCount)つ（あと\(max(0, PlanTemplate.maxCount - templates.count))つ）。押すと中身を見て、今日はこれで進めるか、名前と中身を直せます。") {
            ForEach(Array(templates.enumerated()), id: \.element.id) { index, template in
                if index > 0 { Divider() }
                Button {
                    previewing = template
                } label: {
                    HStack {
                        TemplateRow(template: template)
                        Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 8)
            }
            if onSaveAsTemplate != nil, !plan.blocks.isEmpty {
                Divider()
                saveAsTemplateButton.padding(.vertical, 10)
            }
        }
    }

    /// 一覧の区切り（見出し・角丸の白い面・説明）
    private func card<Content: View>(header: String? = nil, footer: String? = nil,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let header {
                Text(header).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 16)
            }
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(.horizontal, 16).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
            if let footer {
                Text(footer).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 16)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 格子で置けなかった理由の帯（3秒）
    private func problemBanner(_ reason: String) -> some View {
        Label(reason, systemImage: "exclamationmark.circle")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color(.systemBackground))
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(.label).opacity(0.88)))
            .padding(.horizontal, 16).padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityIdentifier("gridProblem")
            .task(id: reason) {
                try? await Task.sleep(for: .seconds(3))
                gridProblem = nil
            }
    }

    private var title: String {
        switch mode {
        case .morning: "今日の計画"
        case .tab: "計画"
        case .tomorrow: "明日の計画"
        }
    }

    private var saveAsTemplateButton: some View {
        Button {
            templateName = ""
            namesTemplate = true
        } label: {
            Label(mode == .tab ? "今日の計画をテンプレートとして保存" : "この計画をテンプレートとして保存",
                  systemImage: "square.and.arrow.down")
                .font(.subheadline)
        }
        .accessibilityIdentifier("saveAsTemplateButton")
    }

    // MARK: 目標（GHO-10）

    private var goalSeconds: Int { max(plan.goalSeconds ?? plan.focusSeconds, plan.focusSeconds) }

    private var goalRow: some View {
        GoalStepper(seconds: goalSeconds, minimum: plan.focusSeconds,
                    caption: plan.goalSeconds == nil ? "計画の集中の合計に合わせて動きます"
                        : "計画より \(DurationFormat.japanese(goalSeconds - plan.focusSeconds)) 多い目標です") { seconds in
            // 計画の合計まで下げたら、計画に合わせて動く状態に戻す
            plan.goalSeconds = seconds > plan.focusSeconds ? seconds : nil
        }
    }

    // MARK: テンプレート（PLN-07）

    private var templateBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(templates) { template in
                    Button {
                        load(template)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(template.name).font(.subheadline.bold())
                            Text("集中 \(DurationFormat.japanese(template.focusSeconds))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.focus.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
    }

    private func load(_ template: PlanTemplate) {
        let previous = plan
        // 習慣のブロックは残す（PLN-08、2026-10-05 オーナー決定）
        var loaded = plan.loading(template.draft(dayStart: dayStart, calendar: calendar), keeping: habitDraft)
        loaded.goalSeconds = nil
        plan = loaded
        // 確認は出さず、「元に戻す」を6秒出す（Q17、2026-10-01 決定）
        if !previous.blocks.isEmpty {
            undo = TemplateUndo(message: "「\(template.name)」を読み込みました", previous: previous)
        }
    }

    /// 日中にテンプレートで進める：今から先だけを置き換える（2026-10-01 オーナー要望）
    private func applyFuture(_ template: PlanTemplate) {
        let previous = plan
        plan = plan.replacingFuture(with: template.draft(dayStart: dayStart, calendar: calendar), now: now, keeping: habitDraft)
        undo = TemplateUndo(message: "「\(template.name)」で進めます", previous: previous)
    }

    // MARK: 候補（PLN-09）

    /// 計画の下に、候補を1行ずつ（押すと足す。2026-10-05 オーナー決定：横に並べる案と比べた）
    private func candidateSection(_ candidates: [PlanCandidate]) -> some View {
        card(header: "候補から足す", footer: "昨日・先週の\(weekdayName)曜日・テンプレートから。押すと同じ時刻・長さで足します。") {
            ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                if index > 0 { Divider() }
                Button {
                    plan.upsert(candidate.blockToAdd)
                } label: {
                    HStack(spacing: 10) {
                        PlanBlockRow(block: candidate.block, isPast: false, note: candidate.sourceLabel)
                        Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(Theme.focus)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 6)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(candidate.block.title) \(timeRange(candidate.block.start, candidate.block.end))、\(candidate.sourceLabel)")
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("同じ時刻で計画に足します")
                .accessibilityIdentifier("candidate")
            }
        }
    }

    private var weekdayName: String {
        ["日", "月", "火", "水", "木", "金", "土"][(calendar.component(.weekday, from: dayStart) - 1) % 7]
    }

    // MARK: ゲーム・SNS の時間（BLK-10）

    private func isLockedUnblock(_ block: PlanBlockDraft) -> Bool {
        PlanDraft.isLocked(block, confirmedDay: mode == .tab, now: now)
    }

    private func delete(_ block: PlanBlockDraft) {
        plan.delete(id: block.id, confirmedDay: mode == .tab, now: now)
    }

    /// 「元に戻す」の帯。背景と同じ色だと気づかれないので、反対の色で目立たせる（2026-10-01 実機での指摘）
    private func undoBanner(_ undo: TemplateUndo) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
            Text(undo.message).font(.subheadline.weight(.semibold))
            Spacer(minLength: 8)
            Button {
                plan = undo.previous
                self.undo = nil
            } label: {
                Label("元に戻す", systemImage: "arrow.uturn.backward")
                    .font(.subheadline.bold())
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(Color(.systemBackground).opacity(0.2)))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("undoTemplateButton")
        }
        .foregroundStyle(Color(.systemBackground))
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.label).opacity(0.88)))
        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
        .padding(.horizontal, 16).padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .task(id: undo) {
            try? await Task.sleep(for: .seconds(6))
            self.undo = nil
        }
    }

    // MARK: 睡眠（DTX-02）

    /// 表示だけで、違うと思ったときだけ押して直す（確かめる操作は求めない）
    @ViewBuilder
    private func sleepRow(_ sleep: SleepRowModel) -> some View {
        Button {
            editsSleep = true
        } label: {
            Group {
                // 大きな文字では縦に並べる（横に並べると1文字ずつ折れるため）
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("睡眠", systemImage: "moon.zzz.fill").foregroundStyle(.secondary)
                        Text(timeRange(sleep.line.start, sleep.line.end)).fontWeight(.semibold).monospacedDigit()
                        Text(sleep.line.source.label).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "moon.zzz.fill").foregroundStyle(Theme.ghost)
                        Text("睡眠").foregroundStyle(.secondary)
                        Text(timeRange(sleep.line.start, sleep.line.end)).fontWeight(.semibold).monospacedDigit()
                        Spacer(minLength: 4)
                        Text(sleep.line.source.label).font(.caption).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
                    }
                }
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sleepRow")
        .accessibilityHint("寝た時刻と起きた時刻を直します")
        .sheet(isPresented: $editsSleep) {
            SleepEditSheet(line: sleep.line, onReread: sleep.onReread) { start, end in
                if sleep.onEdit(start, end) { editsSleep = false }
            }
        }
        if sleep.needsHealth {
            Button {
                sleep.onRequestHealth()
            } label: {
                Label("ヘルスケアから読む", systemImage: "heart.text.square")
                    .font(.subheadline)
            }
            .accessibilityIdentifier("requestHealthButton")
        }
    }

    private var newBlockTarget: EditorTarget {
        EditorTarget(
            block: PlanBlockDraft(start: plan.blocks.isEmpty ? (firstStart ?? plan.nextStart(now: now)) : plan.nextStart(now: now),
                                  minutes: PlanDraft.defaultMinutes,
                                  category: categories.first ?? .unknown),
            isNew: true)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(dayStart.formatted(.dateTime.month().day().weekday(.wide).locale(Locale(identifier: "ja_JP"))))
                .font(.headline)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) { totals }
                VStack(alignment: .leading, spacing: 4) { totals }
            }
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var totals: some View {
        StatLabel(title: "集中", seconds: plan.focusSeconds, color: Theme.focus, systemImage: "circle.fill")
        StatLabel(title: "デトックス", seconds: plan.detoxSeconds, color: Theme.detox, systemImage: "leaf.fill")
    }

    private var bottomButtons: some View {
        VStack(spacing: 8) {
            Button {
                onConfirm(plan)
            } label: {
                Text(mode == .morning ? "この計画で始める" : "保存").font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.extraLarge)
            .disabled(mode == .morning && plan.blocks.isEmpty)
            .accessibilityIdentifier("confirmPlanButton")
            if mode == .morning {
                Button("今日は計画しない") { onDismiss(plan.goalSeconds) }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("skipPlanButton")
            }
        }
        .padding(.horizontal, 20).padding(.bottom, 8)
        .background(.bar)
    }
}

struct PlanBlockRow: View {
    let block: PlanBlockDraft
    let isPast: Bool
    /// 名前の下に添える出どころ（候補の「昨日」など、PLN-09）
    var note: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Theme.color(for: block.category))
                .frame(width: 4)
            // 大きな文字では、名前の下に時刻を置く（横に並べると名前が1文字ずつ折れるため）
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    names
                    times(alignment: .leading)
                }
            } else {
                names
                Spacer()
                times(alignment: .trailing)
            }
        }
        .padding(.vertical, 4)
        .opacity(isPast ? 0.5 : 1)
        .contentShape(Rectangle())
    }

    private var names: some View {
        VStack(alignment: .leading, spacing: 2) {
            if block.isUnblock {
                HStack(spacing: 6) {
                    Image(systemName: "gamecontroller.fill").imageScale(.small)
                    Text(block.title)
                }
                .font(.headline)
                .foregroundStyle(Theme.play)
            } else {
                Text(block.title).font(.headline)
            }
            if block.project != nil || note != nil {
                Text([block.project != nil ? block.category.name : nil, note].compactMap { $0 }.joined(separator: "・"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func times(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(timeRange(block.start, block.end)).font(.subheadline.monospacedDigit())
            Text(DurationFormat.japanese(block.minutes * 60)).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// 今日の目標（GHO-10）。− ＋ で15分ずつ（Q20）。下限は計画の集中の合計、上限は24時間。
struct GoalStepper: View {
    let seconds: Int
    let minimum: Int
    var caption: String?
    let onChange: (Int) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    static let step = 15 * 60
    static let maximum = 24 * 3600

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if dynamicTypeSize.isAccessibilitySize {
                // 大きな文字では、目標を上に、− ＋ を下に置く
                label
                stepper.labelsHidden()
            } else {
                stepper
            }
            if let caption {
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var label: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(spacing: 6))
        return layout {
            HStack(spacing: 6) {
                Image(systemName: "flag.fill").foregroundStyle(Theme.ghost)
                Text("今日の目標").foregroundStyle(.secondary)
            }
            Text(DurationFormat.japanese(seconds)).fontWeight(.semibold).monospacedDigit()
        }
        .font(.subheadline)
    }

    private var stepper: some View {
        Stepper {
            label
        } onIncrement: {
            onChange(min(seconds + Self.step, Self.maximum))
        } onDecrement: {
            onChange(max(seconds - Self.step, minimum))
        }
        .accessibilityLabel("今日の目標 \(DurationFormat.japanese(seconds))")
        .accessibilityIdentifier("goalStepper")
    }
}

/// 計画の画面に出す睡眠の行（DTX-02）。
struct SleepRowModel {
    var line: SleepLine
    /// ヘルスケアの許可をまだ聞いていない
    var needsHealth: Bool
    /// 寝た・起きた時刻を手で直す。直せたら true
    var onEdit: (Date, Date) -> Bool
    var onRequestHealth: () -> Void
    /// ヘルスケアから読み直す。記録がなかったら false（画面を開いたまま、ひとこと出す）、それ以外は true（閉じる）。
    /// ヘルスケアのない端末では nil（出さない）
    var onReread: (() async -> Bool)? = nil
}

/// 寝た・起きた時刻を直す（DTX-02）。5分刻み。直すとヘルスケアで置き換えなくなる。
struct SleepEditSheet: View {
    @State var start: Date
    @State var end: Date
    let onSave: (Date, Date) -> Void
    let onReread: (() async -> Bool)?
    private static let noRecordID = "sleepNoRecord"
    @State private var isRereading = false
    @State private var showsNoRecord = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(line: SleepLine, onReread: (() async -> Bool)? = nil, onSave: @escaping (Date, Date) -> Void) {
        _start = State(initialValue: line.start)
        _end = State(initialValue: line.end)
        self.onReread = onReread
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        row("寝た", $start, shownDate: SleepLine.normalizedStart(start, end: end))
                        row("起きた", $end, shownDate: end)
                        Text("直すと、あとでヘルスケアに記録が入っても置き換えません（「ヘルスケアから読み直す」を押したときは置き換えます）。寝た時刻が起きた時刻より遅いときは、前の夜とみなします。")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        // 下に固定すると、大きな文字で説明に重なるので中身の終わりに置く（保存の上）
                        if let onReread { rereadButton(onReread) }
                    }
                    .padding(20)
                }
                // 大きな文字では、出したひとことが保存の下に隠れるので、そこまで送る
                .onChange(of: showsNoRecord) { _, shows in
                    if shows { withAnimation { proxy.scrollTo(Self.noRecordID, anchor: .bottom) } }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    onSave(SleepLine.normalizedStart(start, end: end), end)
                } label: {
                    Text("保存").font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.extraLarge)
                .padding(.horizontal, 20).padding(.bottom, 8)
                .accessibilityIdentifier("sleepSaveButton")
            }
            .navigationTitle("睡眠")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる", systemImage: "xmark") { dismiss() }
                }
            }
        }
        .tint(Theme.focus)
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
    }

    /// ヘルスケアから読み直す（2026-10-03）。記録がなければひとこと出し、それ以外は閉じる（保存の失敗は手で直したときと同じく閉じてから知らせる）
    @ViewBuilder
    private func rereadButton(_ reread: @escaping () async -> Bool) -> some View {
        VStack(spacing: 4) {
            Button {
                isRereading = true
                showsNoRecord = false
                Task {
                    let closes = await reread()
                    isRereading = false
                    if closes { dismiss() } else { showsNoRecord = true }
                }
            } label: {
                HStack(spacing: 6) {
                    if isRereading { ProgressView().controlSize(.small) }
                    Label("ヘルスケアから読み直す", systemImage: "arrow.clockwise.heart")
                }
                .font(.subheadline)
            }
            .disabled(isRereading)
            .accessibilityIdentifier("sleepRereadButton")
            if showsNoRecord {
                Text("ヘルスケアに記録がありませんでした")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .id(Self.noRecordID)
                    .accessibilityIdentifier("sleepNoRecordText")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    /// `shownDate`：前の夜に合わせたあとの日付（23:30 を選ぶと前の日になる）
    @ViewBuilder
    private func row(_ title: String, _ date: Binding<Date>, shownDate: Date) -> some View {
        let day = Text(shownDate.formatted(.dateTime.month().day().locale(Locale(identifier: "ja_JP"))))
            .font(.caption).foregroundStyle(.secondary)
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title).font(.subheadline.bold()).foregroundStyle(.secondary)
                    day
                }
                StepTimePicker(date: date, minuteInterval: PlanDraft.minuteStep)
                    .accessibilityLabel(title)
            }
        } else {
            HStack {
                Text(title).font(.subheadline.bold()).foregroundStyle(.secondary)
                Spacer()
                day
                StepTimePicker(date: date, minuteInterval: PlanDraft.minuteStep)
                    .accessibilityLabel(title)
            }
        }
    }
}
