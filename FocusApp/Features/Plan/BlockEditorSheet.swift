import SwiftUI
import UIKit

/// 計画ブロックの追加・編集（PLN-02）。
/// 何をするか（カテゴリ → そのカテゴリのブロック名）→ 開始時刻 → 長さ（スライダー）。
/// スクロールせずに長さまで届くよう、カテゴリは1つの流れに並べ、ブロック名は選んだカテゴリの分だけ出す（2026-10-01 決定）。
struct BlockEditorSheet: View {
    @State var block: PlanBlockDraft
    let isNew: Bool
    let plan: PlanDraft
    let dayStart: Date
    /// その日の区切り（一日の終わり）。nil なら24時間後
    var dayEnd: Date? = nil
    /// 区切りの時刻の表示（区切りをまたぐときの理由）
    var boundaryLabel: String? = nil
    var calendar: Calendar = .app(timeZone: .current)
    let categories: [CategoryOption]
    let projects: [ProjectOption]
    let onCreateProject: (String, CategoryOption) -> ProjectOption?
    /// カテゴリをその場で作る（CAT-04）。nil なら「＋ カテゴリ」を出さない
    var onCreateCategory: ((String, Bool, DetoxGroup?) -> CategoryOption?)?
    /// 「何をする」の最後に「ゲーム・SNS」を出す（BLK-10）
    var showsUnblock = false
    /// 確定した日（計画のタブ）。今その中にあるゲーム・SNS の時間は「今で終える」（BLK-10）
    var isConfirmedDay = false
    var now: Date = .distantPast
    /// 今その中にあるゲーム・SNS の時間を、今の時刻で終える
    var onEndNow: (() -> Void)?
    /// 保存できない理由（習慣の画面はほかのブロックの数も見る、PLN-08）。nil なら計画の決まり
    var problem: ((PlanBlockDraft) -> String?)?
    /// 手動の記録（TMR-13）。終わったブロックの時刻に記録のない部分があるときだけ渡す
    var manual: ManualOption?
    /// 終わったブロックを今から遅れて始める（TMR-15）。開始から1時間以内で記録がないときだけ渡す
    var onStartNow: (() -> Void)?

    let onSave: (PlanBlockDraft) -> Void
    let onDelete: () -> Void

    @State private var newProjectCategory: CategoryOption?
    @State private var newProjectName = ""
    @State private var addsCategory = false
    /// その場で作ったカテゴリ（親の一覧に反映されるまでのあいだも出す）
    @State private var addedCategories: [CategoryOption] = []
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let onStartNow {
                        Button(action: onStartNow) {
                            Label("今から始める（\(timeRange(now, now.addingTimeInterval(Double(original.minutes * 60)))))",
                                  systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .accessibilityIdentifier("startLateButton")
                    }
                    if let manual { ManualCard(block: original, option: manual) }
                    whatSection
                    timeSection
                    if isOngoingUnblock {
                        Button("今で終える", systemImage: "stop.circle", role: .destructive) { onEndNow?() }
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier("endUnblockNowButton")
                    } else if !isNew {
                        Button("このブロックを削除", systemImage: "trash", role: .destructive) { onDelete() }
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(20)
            }
            .safeAreaInset(edge: .bottom) { saveButton }
            .navigationTitle(isNew ? "ブロックを追加" : "ブロックを編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる", systemImage: "xmark") { dismiss() }
                }
            }
            .alert("新しいブロック名", isPresented: showsNewProjectAlert) {
                TextField("例：ゼミ準備", text: $newProjectName)
                Button("キャンセル", role: .cancel) {}
                Button("作成") { createProject() }
            } message: {
                Text("「\(newProjectCategory?.name ?? "")」の中に作ります")
            }
        }
        .tint(Theme.focus)
    }

    /// 確定した日の、今その中にあるゲーム・SNS の時間（開始は変えられず、消すと今で終える）
    private var isOngoingUnblock: Bool {
        !isNew && PlanDraft.isOngoing(original, confirmedDay: isConfirmedDay, now: now)
    }

    /// 開いたときのブロック
    private var original: PlanBlockDraft { plan.blocks.first { $0.id == block.id } ?? block }

    // MARK: 何をするか

    /// カテゴリを1つの流れに並べ、選んだカテゴリのブロック名だけを下に出す
    private var whatSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("何をする").font(.subheadline.bold()).foregroundStyle(.secondary)
            FlowLayout(spacing: 8) {
                ForEach(shownCategories) { category in
                    chip(category.name, color: color(category), selected: block.category == category, bold: true) {
                        if block.category != category { block.project = nil }
                        if block.isUnblock { block.minutes = PlanDraft.defaultMinutes }
                        block.category = category
                    }
                }
                if showsUnblock || block.isUnblock {
                    chip("🎮 ゲーム・SNS", color: Theme.play, selected: block.isUnblock, bold: true) {
                        block.category = .gameSNS
                        block.project = nil
                        block.minutes = PlanDraft.unblockMinutes
                    }
                    .accessibilityIdentifier("unblockChip")
                }
                if onCreateCategory != nil {
                    Button {
                        addsCategory = true
                    } label: {
                        Label("カテゴリ", systemImage: "plus").font(.subheadline)
                            .padding(.horizontal, 14).frame(minHeight: 36)
                            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                    }
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("addCategoryButton")
                }
            }
            if !block.isUnblock { projectRow }
        }
        .sheet(isPresented: $addsCategory) {
            AddCategorySheet { name, focus, group in
                guard let created = onCreateCategory?(name, focus, group) else { return false }
                if !shownCategories.contains(created) { addedCategories.append(created) }
                block.category = created
                block.project = nil
                return true
            }
        }
    }

    @ViewBuilder
    private var projectRow: some View {
        // 大きな文字では「ブロック名」を上に置く
        let projectLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        projectLayout {
            Text("ブロック名").font(.caption).foregroundStyle(.secondary)
            FlowLayout(spacing: 8) {
                chip("なし", color: color(block.category), selected: block.project == nil, bold: false) {
                    block.project = nil
                }
                ForEach(projects.filter { $0.category == block.category }) { project in
                    chip(project.name, color: color(block.category), selected: block.project == project, bold: false) {
                        block.project = project
                    }
                }
                Button {
                    newProjectName = ""
                    newProjectCategory = block.category
                } label: {
                    Image(systemName: "plus").padding(10).frame(minWidth: 36, minHeight: 36)
                        .foregroundStyle(color(block.category))
                        .overlay(Capsule().strokeBorder(color(block.category).opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                }
                .accessibilityLabel("\(block.category.name)に新しいブロック名を作る")
            }
        }
    }

    private var shownCategories: [CategoryOption] {
        categories + addedCategories.filter { !categories.contains($0) }
    }

    private func chip(_ title: String, color: Color, selected: Bool, bold: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(bold ? .subheadline.bold() : .subheadline)
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .foregroundStyle(selected ? .white : color)
                .background(Capsule().fill(selected ? color : color.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func color(_ category: CategoryOption) -> Color { Theme.color(for: category) }

    private var showsNewProjectAlert: Binding<Bool> {
        Binding(get: { newProjectCategory != nil }, set: { if !$0 { newProjectCategory = nil } })
    }

    private func createProject() {
        guard let category = newProjectCategory, let project = onCreateProject(newProjectName, category) else { return }
        block.category = category
        block.project = project
    }

    // MARK: 時間

    private var timeSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("開始").font(.subheadline.bold()).foregroundStyle(.secondary)
                Spacer()
                if isOngoingUnblock {
                    Text(block.start.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)))
                        .monospacedDigit()
                } else {
                    StepTimePicker(date: Binding(get: { block.start }, set: { block.start = fitted($0) }),
                                   minuteInterval: PlanDraft.minuteStep)
                        .accessibilityLabel("開始")
                }
            }
            Text("長さ").font(.subheadline.bold()).foregroundStyle(.secondary)
            if block.isUnblock {
                Text("30分（決まり）　\(timeRange(block.start, block.end))").font(.subheadline.monospacedDigit())
                Text("この30分はゲームと SNS を開けます。デトックスとしてはそのまま数えます。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                LengthSlider(minutes: $block.minutes, caption: timeRange(block.start, block.end))
            }
        }
        .onAppear { block.start = PlanDraft.roundedToStep(block.start) }
    }

    /// 選んだ時刻を、その日の中の同じ時刻にする（時刻だけを選ぶので、前の夜の 22:30 なども選べるように。PLN-11）
    private func fitted(_ start: Date) -> Date {
        let end = dayEnd ?? dayStart.addingTimeInterval(24 * 3600)
        guard start < dayStart || start >= end else { return start }
        return [-1, 1].compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
            .first { $0 >= dayStart && $0 < end } ?? start
    }

    // MARK: 保存

    private var saveButton: some View {
        let reason = isOngoingUnblock ? "今のゲーム・SNS の時間は動かせません。終えるときは「今で終える」" as String?
            : self.problem.map { $0(block) } ?? plan.problem(with: block, dayStart: dayStart, dayEnd: dayEnd, boundaryLabel: boundaryLabel)
        return VStack(spacing: 8) {
            if let reason {
                Label(reason, systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button {
                onSave(block)
            } label: {
                Text(isNew ? "追加" : "保存").font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.extraLarge)
            .disabled(reason != nil)
            .accessibilityIdentifier("blockSaveButton")
        }
        .padding(.horizontal, 20).padding(.bottom, 8)
    }
}


/// 分を刻みで選ぶ時刻のピッカー。SwiftUI の DatePicker は刻みを決められないので UIDatePicker を使う
struct StepTimePicker: UIViewRepresentable {
    @Binding var date: Date
    let minuteInterval: Int

    func makeUIView(context: Context) -> UIDatePicker {
        let picker = UIDatePicker()
        picker.datePickerMode = .time
        picker.preferredDatePickerStyle = .compact
        picker.minuteInterval = minuteInterval
        picker.accessibilityIdentifier = "blockStartPicker"
        picker.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        return picker
    }

    func updateUIView(_ picker: UIDatePicker, context: Context) {
        context.coordinator.date = $date
        if picker.date != date { picker.date = date }
    }

    /// コンパクト表示の UIDatePicker は自分の大きさを SwiftUI に伝えないので、ここで聞いて返す
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIDatePicker, context: Context) -> CGSize? {
        uiView.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
    }

    func makeCoordinator() -> Coordinator { Coordinator(date: $date) }

    @MainActor final class Coordinator: NSObject {
        var date: Binding<Date>
        init(date: Binding<Date>) { self.date = date }
        @objc func changed(_ picker: UIDatePicker) { date.wrappedValue = picker.date }
    }
}

/// 計画のタブの「やった（手動で記録）」（TMR-13）を出すときの値。
struct ManualOption {
    /// 初めの時刻：ブロックの時刻のうち記録のない一番長い部分
    var initial: DateInterval
    /// 選べる時刻（昨日の 4:00〜今）
    var range: ClosedRange<Date>
    var calendar: Calendar
    /// 記録できない理由（開始, 終わり）
    var problem: (Date, Date) -> ManualRecord.Problem?
    /// 「手動で記録」の画面を出しているか（下の画面は、その間は知らせを出さない）
    var isPresented: Binding<Bool>
    /// 保存できなかったときの知らせ（「手動で記録」の画面の上に出す）
    var errorMessage: Binding<String?>
    /// 記録する。できたら true（編集の画面も閉じる）
    var onRecord: (Date, Date) -> Bool
}

/// 編集の画面の上に出す「やった（手動で記録）」。押すと「手動で記録」の画面（そのブロックのカテゴリ・ブロック名で）
struct ManualCard: View {
    let block: PlanBlockDraft
    let option: ManualOption

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("記録のない時間があります", systemImage: "questionmark.circle")
                .font(.subheadline.bold())
            Text("タイマーを押し忘れたけれどやったときは、手動で記録できます。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                option.isPresented.wrappedValue = true
            } label: {
                Label("やった（手動で記録）", systemImage: "checkmark.circle.fill")
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityIdentifier("manualRecordButton")
        }
        // 大きな文字でもボタンが切れないよう上限を付ける（文字サイズ最大で「記録）」が切れていた）
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.focus.opacity(0.08)))
        .sheet(isPresented: option.isPresented) {
            ManualRecordSheet(mode: .block(title: block.title, category: block.category), initial: option.initial,
                              range: option.range, calendar: option.calendar, problem: option.problem) { entry in
                option.onRecord(entry.start, entry.end)
            }
            .saveErrorAlert(option.errorMessage)
        }
    }
}
