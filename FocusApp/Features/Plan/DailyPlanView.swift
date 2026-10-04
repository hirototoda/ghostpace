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
        NavigationStack {
            List {
                Section {
                    summary
                    if let sleep { sleepRow(sleep) }
                    if showsGoal { goalRow }
                }
                if mode != .tab, !templates.isEmpty {
                    Section("テンプレートから") { templateBar }
                }
                Section {
                    if plan.blocks.isEmpty {
                        Text("「ブロックを追加」から、今日やることを時間帯ごとに入れます。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(plan.sortedBlocks) { block in
                        Button {
                            editing = EditorTarget(block: block, isNew: false)
                        } label: {
                            PlanBlockRow(block: block, isPast: block.end <= now)
                        }
                        .buttonStyle(.plain)
                        // 確定した日の終わったゲーム・SNS の時間は変えられない（BLK-10）
                        .disabled(isLockedUnblock(block))
                        .deleteDisabled(isLockedUnblock(block))
                    }
                    .onDelete { offsets in
                        let sorted = plan.sortedBlocks
                        offsets.forEach { delete(sorted[$0]) }
                    }
                    Button {
                        editing = newBlockTarget
                    } label: {
                        Label("ブロックを追加", systemImage: "plus.circle.fill").font(.headline)
                    }
                    .accessibilityIdentifier("addBlockButton")
                    if onSaveAsTemplate != nil, !plan.blocks.isEmpty, mode != .tab {
                        saveAsTemplateButton
                    }
                } footer: {
                    if mode == .tab {
                        Text("直すとすぐ保存します。朝に確定した計画は、振り返りのためにそのまま残ります。")
                    }
                }
                if mode == .tab, let templateEditor {
                    Section {
                        ForEach(templates) { template in
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
                        }
                        if onSaveAsTemplate != nil, !plan.blocks.isEmpty { saveAsTemplateButton }
                    } header: {
                        Text("テンプレート")
                    } footer: {
                        Text("最大\(PlanTemplate.maxCount)つ（あと\(max(0, PlanTemplate.maxCount - templates.count))つ）。押すと中身を見て、今日はこれで進めるか、名前と中身を直せます。")
                    }
                    .accessibilityIdentifier("templateSection")
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
                    if let undo { undoBanner(undo) }
                    if mode != .tab { bottomButtons }
                }
                .animation(.easeOut(duration: 0.25), value: undo)
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
                                 }) { saved in
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
        var loaded = template.draft(dayStart: dayStart, calendar: calendar)
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
        plan = plan.replacingFuture(with: template.draft(dayStart: dayStart, calendar: calendar), now: now)
        undo = TemplateUndo(message: "「\(template.name)」で進めます", previous: previous)
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
            SleepEditSheet(line: sleep.line) { start, end in
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
            if block.project != nil {
                Text(block.category.name).font(.caption).foregroundStyle(.secondary)
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
}

/// 寝た・起きた時刻を直す（DTX-02）。5分刻み。直すとヘルスケアで置き換えなくなる。
struct SleepEditSheet: View {
    @State var start: Date
    @State var end: Date
    let onSave: (Date, Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(line: SleepLine, onSave: @escaping (Date, Date) -> Void) {
        _start = State(initialValue: line.start)
        _end = State(initialValue: line.end)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    row("寝た", $start, shownDate: SleepLine.normalizedStart(start, end: end))
                    row("起きた", $end, shownDate: end)
                    Text("直すと、あとでヘルスケアに記録が入っても置き換えません。寝た時刻が起きた時刻より遅いときは、前の夜とみなします。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
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
