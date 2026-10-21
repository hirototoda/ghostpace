import SwiftUI

/// 「手動で記録」の画面（TMR-13、docs/product/features/focus-timer.md「手動の記録」）。
/// 入口は3つ（タイムライン・計画のタブ・タイマーの画面の「前の分を足す」）で中身は同じ。手動の記録を直すときも使う（TML-06）。
/// 記録できるのはアプリを使っていない時間だけ。できないときは理由を出して［記録する］を押せなくする
struct ManualRecordSheet: View {
    enum Mode {
        /// タイムラインから：カテゴリとブロック名を、計画外の開始と同じ形で選ぶ（計画外の記録）
        case choose(CategoryChoice)
        /// 計画のタブから：ブロックのカテゴリ・ブロック名で（ブロックの記録）
        case block(title: String, category: CategoryOption)
        /// タイマーの画面の「前の分を足す」：終わり（タイマーを始めた時刻）は変えられず、開始は遅くだけできる
        case previous(title: String, category: CategoryOption)
        /// 「手動の記録を直す」：開始・終わりを変える・消す。カテゴリ・ブロックは変えない
        case edit(FocusSession)
    }

    /// タイムラインから記録するときのカテゴリの材料
    struct CategoryChoice {
        var categories: [CategoryOption]
        var projects: [ProjectOption]
        var onCreateProject: ((String, CategoryOption) -> ProjectOption?)?
        var onCreateCategory: ((String, Bool, DetoxGroup?) -> CategoryOption?)?
    }

    /// 保存する中身。カテゴリ・ブロック名はタイムラインから記録するときだけ入る
    struct Entry {
        var category: CategoryOption?
        var project: ProjectOption?
        var start: Date
        var end: Date
    }

    let mode: Mode
    /// 選べる時刻（前の分を足すときは、ブロックの開始〜タイマーを始めた時刻）
    let range: ClosedRange<Date>
    /// 記録できない理由（開始, 終わり）。できるなら nil
    let problem: (Date, Date) -> ManualRecord.Problem?
    /// 保存する。できたら true（画面を閉じる）。できなければ呼ぶ側が理由・「保存できませんでした」を出す
    let onSave: (Entry) -> Bool
    /// 手動の記録を消す（直すときだけ）。消せたら true
    var onDelete: (() -> Bool)?

    @State private var start: Date
    @State private var end: Date
    @State private var selected: CategoryOption?
    @State private var project: ProjectOption?
    @State private var confirmsDelete = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(mode: Mode, initial: DateInterval, range: ClosedRange<Date>, problem: @escaping (Date, Date) -> ManualRecord.Problem?,
         onSave: @escaping (Entry) -> Bool, onDelete: (() -> Bool)? = nil) {
        self.mode = mode
        self.range = range
        self.problem = problem
        self.onSave = onSave
        self.onDelete = onDelete
        _start = State(initialValue: initial.start)
        _end = State(initialValue: initial.end)
    }

    private let hm = Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)

    var body: some View {
        let reason = problem(start, end)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if case .choose(let choice) = mode {
                        CategoryProjectPicker(categories: choice.categories, projects: choice.projects,
                                              onCreateProject: choice.onCreateProject, onCreateCategory: choice.onCreateCategory,
                                              selected: $selected, project: $project)
                    }
                    timeSection
                    if let reason {
                        Label(reason.message, systemImage: "exclamationmark.circle")
                            .font(.footnote).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("manualProblem")
                    }
                    Text(pointsNote)
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if onDelete != nil {
                        Button("この記録を消す", systemImage: "trash", role: .destructive) { confirmsDelete = true }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 8)
                            .accessibilityIdentifier("manualDeleteButton")
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .safeAreaInset(edge: .bottom) { saveButton(disabled: reason != nil || category == nil) }
            .navigationTitle(isEdit ? "手動の記録を直す" : "手動で記録")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("やめる") { dismiss() }
                        .accessibilityIdentifier("manualCancelButton")
                }
            }
            .confirmationDialog("この記録を消しますか？", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("消す", role: .destructive) {
                    if onDelete?() == true { dismiss() }
                }
                Button("キャンセル", role: .cancel) {}
            }
        }
        .presentationDetents(isChoosing || dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        // 終了時刻を早めるシートと同じ上限（日付と時刻の選択が画面に収まるように）
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
        .tint(Theme.focus)
    }

    private var isEdit: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var isChoosing: Bool {
        if case .choose = mode { return true }
        return false
    }

    private var isPrevious: Bool {
        if case .previous = mode { return true }
        return false
    }

    /// 記録するカテゴリ（タイムラインから記録するときは選んだもの）
    private var category: CategoryOption? {
        switch mode {
        case .choose(let choice): CategoryProjectPicker.resolved(selected, in: choice.categories)
        case .block(_, let category), .previous(_, let category): category
        case .edit(let session): session.category
        }
    }

    @ViewBuilder
    private var header: some View {
        switch mode {
        case .choose:
            Text("アプリを使っていなかった時間を、あとから記録します。")
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .block(let title, let category):
            titleLine(title, category: category)
        case .previous:
            // 例：11:00〜11:20 を手動で記録（点は0.8倍）
            Text("\(start.formatted(hm))〜\(end.formatted(hm)) を手動で記録（点は0.8倍）")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("previousPartTitle")
        case .edit(let session):
            titleLine(session.title, category: session.category)
        }
    }

    private func titleLine(_ title: String, category: CategoryOption) -> some View {
        HStack(spacing: 8) {
            // ブロック名がなければカテゴリの名前だけ（「勉強 勉強」と2回出さない）
            if title != category.name {
                Text(category.name)
                    .font(.caption.bold())
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.color(for: category).opacity(0.15)))
            }
            Text(title).font(.headline)
        }
    }

    // MARK: 時刻

    private var timeSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            timeRow("開始") {
                DatePicker("開始", selection: $start, in: startRange, displayedComponents: components)
                    .accessibilityIdentifier("manualStartPicker")
            }
            timeRow("終わり") {
                if isPrevious {
                    // タイマーを始めた時刻（変えられない）
                    Text(end.formatted(hm)).monospacedDigit()
                } else {
                    DatePicker("終わり", selection: $end, in: range, displayedComponents: components)
                        .accessibilityIdentifier("manualEndPicker")
                }
            }
        }
    }

    /// 前の分を足すときは、開始はブロックの開始より前にできず、終わりの1分前まで
    private var startRange: ClosedRange<Date> {
        guard isPrevious else { return range }
        return range.lowerBound...max(range.lowerBound, range.upperBound.addingTimeInterval(-FocusSession.minimumSeconds))
    }

    /// 今日と昨日のどちらの時刻か分かるよう日付も出す（前の分を足すときは日付が変わる場合だけ）
    private var components: DatePickerComponents {
        if isPrevious, Calendar.current.isDate(range.lowerBound, inSameDayAs: range.upperBound) { return .hourAndMinute }
        return [.date, .hourAndMinute]
    }

    /// 見出しと時刻の選択。入りきらない大きな文字では見出しを上に置く
    private func timeRow<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            Text(title).font(.subheadline.bold()).foregroundStyle(.secondary)
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
            content()
                .labelsHidden()
                .datePickerStyle(.compact)
                .environment(\.locale, Locale(identifier: "ja_JP"))
        }
    }

    /// 点の説明（集中は0.8倍、家事・運動・休みは10分0.6pt）
    private var pointsNote: LocalizedStringKey {
        if category?.countsAsFocus == false {
            return "アプリを使っていなかった時間だけ記録できます。点は10分0.6pt です（タイマーは0.75pt）。"
        }
        return "アプリを使っていなかった時間だけ記録できます。集中した時間に入り、点は0.8倍です。"
    }

    private func saveButton(disabled: Bool) -> some View {
        Button {
            if onSave(Entry(category: category, project: project, start: start, end: end)) { dismiss() }
        } label: {
            Text(isEdit ? "保存" : "記録する").font(.headline).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.extraLarge)
        .disabled(disabled)
        .padding(.horizontal, 20).padding(.bottom, 8)
        .accessibilityIdentifier("manualSaveButton")
    }
}
