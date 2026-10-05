import SwiftUI

/// 習慣の画面（PLN-08、docs/product/features/daily-plan.md「習慣」）。
/// 計画のタブから開くと直すたびに保存する。初めて使う端末では朝の計画の前に全画面で出し、「この習慣で始める」で決める。
struct HabitsView: View {
    @Bindable var model: AppModel
    /// 初めて使う端末の最初の案内
    var isIntro = false
    @State private var draft: PlanDraft
    @State private var editing: EditorTarget?

    private struct EditorTarget: Identifiable {
        var block: PlanBlockDraft
        var isNew: Bool
        var id: UUID { block.id }
    }

    init(model: AppModel, isIntro: Bool = false) {
        self.model = model
        self.isIntro = isIntro
        _draft = State(initialValue: model.habits.draft(dayStart: model.snapshot.dayStart, calendar: model.calendar))
    }

    private var dayStart: Date { model.snapshot.dayStart }
    private var otherCount: Int { draft.blocks.filter { !$0.isUnblock }.count }

    var body: some View {
        List {
            Section {
                // 最初の案内では見出しで同じことを説明している
                if draft.blocks.isEmpty, !isIntro {
                    Text("毎日決まった時刻にすることを入れておくと、毎朝の計画に最初から入ります。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
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
                    change(updated)
                }
                if otherCount < PlanHabits.blockLimit || draft.remainingUnblocks > 0 {
                    Button {
                        editing = EditorTarget(block: newBlock, isNew: true)
                    } label: {
                        Label("ブロックを追加", systemImage: "plus.circle.fill")
                    }
                    .accessibilityIdentifier("addHabitButton")
                }
            } header: {
                if isIntro {
                    Text("毎日決まった時刻にすること（ゲーム・SNS の時間や朝の瞑想など）を決めておくと、毎朝の計画に最初から入ります。あとから計画のタブで直せます。")
                        .font(.subheadline).foregroundStyle(.primary).textCase(nil)
                        .padding(.bottom, 8)
                }
            } footer: {
                Text("ブロックは\(PlanHabits.blockLimit)つまで（あと\(max(0, PlanHabits.blockLimit - otherCount))つ）、ゲーム・SNS の時間は\(PlanDraft.unblockLimit)つまで（あと\(draft.remainingUnblocks)つ）。"
                    + (isIntro ? "" : "直した習慣は、次に作る計画から入ります。今日の計画は変わりません。"))
            }
        }
        .navigationTitle(isIntro ? "毎日の習慣" : "習慣")
        .navigationBarTitleDisplayMode(isIntro ? .large : .inline)
        .safeAreaInset(edge: .bottom) {
            if isIntro { introButtons }
        }
        .sheet(item: $editing) { target in
            BlockEditorSheet(block: target.block, isNew: target.isNew, plan: draft, dayStart: dayStart,
                             categories: otherCount < PlanHabits.blockLimit || !target.block.isUnblock ? model.categories : [],
                             projects: model.projects,
                             onCreateProject: { model.createProject(name: $0, category: $1) },
                             onCreateCategory: { model.createCategory(name: $0, countsAsFocus: $1, detoxGroup: $2) },
                             showsUnblock: draft.remainingUnblocks > 0 || target.block.isUnblock,
                             problem: { PlanHabits.problem(with: $0, in: draft, dayStart: dayStart) }) { saved in
                var updated = draft
                updated.upsert(saved)
                change(updated)
                editing = nil
            } onDelete: {
                var updated = draft
                updated.remove(id: target.block.id)
                change(updated)
                editing = nil
            }
        }
    }

    /// 新しいブロック。ほかのブロックが3つあればゲーム・SNS の時間から。初めは 8:00、あれば最後のブロックの終わりから
    private var newBlock: PlanBlockDraft {
        let start = draft.blocks.isEmpty
            ? (model.calendar.date(byAdding: .hour, value: 8 - DayBoundary.hour, to: dayStart) ?? dayStart)
            : draft.nextStart(now: dayStart)
        if otherCount >= PlanHabits.blockLimit { return .unblock(start: start) }
        return PlanBlockDraft(start: start, minutes: PlanDraft.defaultMinutes, category: model.categories.first ?? .unknown)
    }

    /// 計画のタブからはすぐ保存する。最初の案内では「この習慣で始める」まで保存しない
    private func change(_ updated: PlanDraft) {
        draft = updated
        if !isIntro { model.saveHabits(PlanHabits(plan: updated, calendar: model.calendar)) }
    }

    private var introButtons: some View {
        VStack(spacing: 8) {
            Button {
                model.finishHabitIntro(PlanHabits(plan: draft, calendar: model.calendar))
            } label: {
                Text("この習慣で始める").font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.extraLarge)
            .disabled(draft.blocks.isEmpty)
            .accessibilityIdentifier("finishHabitsButton")
            Button("あとで") { model.finishHabitIntro(nil) }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("skipHabitsButton")
        }
        .padding(.horizontal, 20).padding(.bottom, 8)
        .background(.bar)
    }
}

/// 計画のタブの「習慣」の行（PLN-08）。中身の数と1日の帯
struct HabitsRow: View {
    let habits: PlanHabits

    var body: some View {
        let games = habits.blocks.filter(\.category.isUnblock).count
        let others = habits.blocks.count - games
        VStack(alignment: .leading, spacing: 6) {
            Text("習慣").font(.body.weight(.semibold))
            Text(habits.blocks.isEmpty ? "まだありません。毎日決まった時刻にすることを入れると、毎朝の計画に入ります"
                 : "ブロック \(others)つ・ゲーム・SNS \(games)つ。毎朝の計画に最初から入ります")
                .font(.caption).foregroundStyle(.secondary)
            if !habits.blocks.isEmpty { TemplateStrip(template: PlanTemplate(name: "", blocks: habits.blocks)) }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
