import SwiftUI

/// テンプレートの行（名前、合計、1日の帯）。計画のタブで使う（PLN-07）。
struct TemplateRow: View {
    let template: PlanTemplate

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(template.name).font(.body.weight(.semibold))
            Text("集中 \(DurationFormat.japanese(template.focusSeconds))・デトックス \(DurationFormat.japanese(template.detoxSeconds))・\(template.blocks.count)ブロック")
                .font(.caption).foregroundStyle(.secondary)
            TemplateStrip(template: template)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// テンプレートの1日を帯で見せる（6:00〜24:00。紺＝集中、青緑＝デトックス）。
struct TemplateStrip: View {
    let template: PlanTemplate

    private static let startHour = 6
    private static let span = 18.0 * 60

    var body: some View {
        // GeometryReader はリストの行の中で配置が止まらなくなるため、Canvas で描く
        Canvas { context, size in
            context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2),
                         with: .color(.secondary.opacity(0.12)))
            for block in template.blocks {
                // 0:00〜3:59 は1日の終わり（朝4:00区切り）なので、24時より後ろに置く
                let hour = block.hour < DayBoundary.hour ? block.hour + 24 : block.hour
                let offset = max(0, Double((hour - Self.startHour) * 60 + block.minute))
                let rect = CGRect(x: size.width * offset / Self.span, y: 0,
                                  width: max(2, size.width * Double(block.minutes) / Self.span), height: size.height)
                context.fill(Path(roundedRect: rect, cornerRadius: 2),
                             with: .color(Theme.color(for: block.category)))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

/// テンプレートの名前と中身を直す（PLN-07）。中身は今日の日付に当てはめて、計画と同じ画面で直す。
struct TemplateEditView: View {
    @Bindable var model: AppModel
    let template: PlanTemplate
    @State private var name: String
    @State private var editing: EditorTarget?
    @Environment(\.dismiss) private var dismiss

    private struct EditorTarget: Identifiable {
        var block: PlanBlockDraft
        var isNew: Bool
        var id: UUID { block.id }
    }

    init(model: AppModel, template: PlanTemplate) {
        self.model = model
        self.template = template
        _name = State(initialValue: template.name)
    }

    /// 保存されている今のテンプレート
    private var current: PlanTemplate { model.templates.first { $0.id == template.id } ?? template }
    private var dayStart: Date { model.snapshot.dayStart }
    private var draft: PlanDraft { current.draft(dayStart: dayStart, calendar: model.calendar) }

    var body: some View {
        List {
            Section("名前") {
                TextField("名前", text: $name)
                    .onSubmit(saveName)
                    .submitLabel(.done)
                    .accessibilityIdentifier("templateNameField")
            }
            Section {
                ForEach(draft.sortedBlocks) { block in
                    Button {
                        editing = EditorTarget(block: block, isNew: false)
                    } label: {
                        PlanBlockRow(block: block, isPast: false)
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    var updated = draft
                    let sorted = updated.sortedBlocks
                    offsets.forEach { updated.remove(id: sorted[$0].id) }
                    save(updated)
                }
                Button {
                    let start = draft.blocks.isEmpty
                        ? (model.calendar.date(byAdding: .hour, value: 8 - DayBoundary.hour, to: dayStart) ?? dayStart)
                        : draft.nextStart(now: dayStart)
                    editing = EditorTarget(block: PlanBlockDraft(start: start, minutes: PlanDraft.defaultMinutes,
                                                                 category: model.categories.first ?? .unknown), isNew: true)
                } label: {
                    Label("ブロックを追加", systemImage: "plus.circle.fill")
                }
            } header: {
                Text("中身")
            } footer: {
                Text("集中 \(DurationFormat.japanese(current.focusSeconds))・デトックス \(DurationFormat.japanese(current.detoxSeconds))")
            }
            Section {
                Button("このテンプレートを消す", role: .destructive) {
                    if model.deleteTemplate(current) { dismiss() }
                }
                .accessibilityIdentifier("deleteTemplateButton")
            }
        }
        .navigationTitle(current.name)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear(perform: saveName)
        .sheet(item: $editing) { target in
            BlockEditorSheet(block: target.block, isNew: target.isNew, plan: draft, dayStart: dayStart,
                             categories: model.categories, projects: model.projects,
                             onCreateProject: { model.createProject(name: $0, category: $1) },
                             onCreateCategory: { model.createCategory(name: $0, countsAsFocus: $1, detoxGroup: $2) },
                             showsUnblock: draft.remainingUnblocks > 0 || target.block.isUnblock) { saved in
                var updated = draft
                updated.upsert(saved)
                if save(updated) { editing = nil }
            } onDelete: {
                var updated = draft
                updated.remove(id: target.block.id)
                if save(updated) { editing = nil }
            }
            .saveErrorAlert($model.errorMessage)
        }
    }

    @discardableResult
    private func save(_ plan: PlanDraft) -> Bool {
        var updated = PlanTemplate(name: current.name, plan: plan, calendar: model.calendar)
        updated.id = current.id
        return model.saveTemplate(updated)
    }

    private func saveName() {
        // 消したあと（一覧にもうない）は保存しない。保存すると消したテンプレートが戻ってしまう
        guard model.templates.contains(where: { $0.id == template.id }), name != current.name else { return }
        var updated = current
        updated.name = name
        if !model.saveTemplate(updated) { name = current.name }
    }
}

/// 計画のタブでテンプレートを押したときの中身（2026-10-01 オーナー要望）。
/// 「今日はこれで進む」で今から先だけを置き換える。右上の「編集」で名前と中身を直す。
struct TemplatePreviewSheet: View {
    let template: PlanTemplate
    /// 今日の日付に当てはめた中身
    let plan: PlanDraft
    let now: Date
    let editor: ((PlanTemplate) -> AnyView)?
    let onApply: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(plan.sortedBlocks) { block in
                        PlanBlockRow(block: block, isPast: block.start <= now)
                    }
                } footer: {
                    Text("集中 \(DurationFormat.japanese(template.focusSeconds))・デトックス \(DurationFormat.japanese(template.detoxSeconds))。今より前に始まるブロック（薄い行）は入りません。もう始まったブロックはそのまま残ります。")
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button(action: onApply) {
                    Text("今日はこれで進む").font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.extraLarge)
                .padding(.horizontal, 20).padding(.vertical, 8)
                .background(.bar)
                .accessibilityIdentifier("applyTemplateButton")
            }
            .navigationTitle(template.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる", systemImage: "xmark") { dismiss() }
                }
                if let editor {
                    ToolbarItem(placement: .primaryAction) {
                        NavigationLink("編集") { editor(template) }
                            .accessibilityIdentifier("editTemplateButton")
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .tint(Theme.focus)
    }
}
