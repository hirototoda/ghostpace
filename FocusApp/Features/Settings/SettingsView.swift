import SwiftUI

/// 設定（docs/product/features/settings.md）。ホーム右上の歯車から開く。
/// 通知（振り返りの時刻・予定の時間）、アプリのブロック、カテゴリ（集中／デトックスに分けて並べる）。
struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var addsCategory = false
    /// ブロックするアプリ・集中中も使うアプリを選ぶ画面
    @State private var selectsBlockedApps: BlockSelectionRequest?
    @State private var path: [CategoryOption] = []
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack(path: $path) {
            List {
                notificationSection
                BlockingSettingsSection(model: model, notificationsOff: model.notificationStatus != .authorized) {
                    // 外せるものがないときは長押しを挟まない
                    selectsBlockedApps = BlockSelectionRequest(purpose: .blocked, requiresHold: model.hasBlockSelection)
                } onSelectFocusAllow: {
                    // タイマー中は設定を開けないので、長押しは要らない（app-blocking.md）
                    selectsBlockedApps = BlockSelectionRequest(purpose: .focusAllow, requiresHold: false)
                }
                sleepSection
                Section("集中に数える") {
                    ForEach(model.categories.filter(\.countsAsFocus)) { categoryRow($0) }
                }
                Section {
                    ForEach(model.categories.filter { !$0.countsAsFocus }) { categoryRow($0) }
                } header: {
                    Text("デジタルデトックス")
                } footer: {
                    Text("カテゴリを押すと、名前・数え方・ブロック名を直せます。")
                }
                Section {
                    Button {
                        addsCategory = true
                    } label: {
                        Label("カテゴリを追加", systemImage: "plus.circle.fill")
                    }
                    .accessibilityIdentifier("settingsAddCategoryButton")
                    NavigationLink("アーカイブしたもの") { ArchivedView(model: model) }
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: CategoryOption.self) { CategoryEditView(model: model, category: $0) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる", systemImage: "xmark") { dismiss() }
                }
            }
            .sheet(isPresented: $addsCategory) {
                AddCategorySheet { name, focus, group in model.createCategory(name: name, countsAsFocus: focus, detoxGroup: group) != nil }
                    .saveErrorAlert($model.errorMessage)
            }
        }
        // 名前の重なりなどの理由は、押し込んだ画面の上にも出るよう、いちばん外から出す
        .saveErrorAlert($model.errorMessage, when: !addsCategory && model.holdRequest == nil)
        .tint(Theme.focus)
        .holdUnlockCover(model: model, when: !addsCategory && selectsBlockedApps == nil)
        .sheet(item: $selectsBlockedApps) { request in
            BlockSelectionSheet(model: model, purpose: request.purpose, requiresHold: request.requiresHold)
        }
        .task { await model.refreshNotificationStatus() }
    }

    // MARK: 通知

    private var notificationSection: some View {
        Section {
            if model.notificationStatus != .authorized {
                permissionRow
            }
            DatePicker(selection: reviewTime, displayedComponents: .hourAndMinute) {
                Label("振り返りの通知", systemImage: "moon.stars")
            }
            .accessibilityIdentifier("reviewTimePicker")
            Toggle(isOn: Binding(get: { model.plannedEndNotifications }, set: { model.setPlannedEndNotifications($0) })) {
                Label("予定の時間の通知", systemImage: "bell")
            }
            Picker(selection: Binding(get: { model.blockNoticeMinutes }, set: { model.setBlockNoticeMinutes($0) })) {
                ForEach(BlockNotice.choices, id: \.self) { minutes in
                    Text(Self.blockNoticeLabel(minutes)).tag(minutes)
                }
            } label: {
                Label("計画の前の通知", systemImage: "calendar.badge.clock")
            }
            .accessibilityIdentifier("blockNoticePicker")
        } header: {
            Text("通知")
        } footer: {
            Text("夜の振り返りは、この時刻からホームにも出ます。予定の時間の通知は、カウントダウンが0になったときに知らせます。計画の前の通知は、計画ブロックが始まる前に「まもなく〜」と知らせます。")
        }
    }

    /// 計画の前の通知の選択肢の表示（TMR-12）
    private static func blockNoticeLabel(_ minutes: Int?) -> LocalizedStringKey {
        switch minutes {
        case nil: "オフ"
        case 0: "ちょうど"
        case let minutes?: "\(minutes)分前"
        }
    }

    private var permissionRow: some View {
        let denied = model.notificationStatus == .denied
        return ViewThatFits(in: .horizontal) {
            HStack {
                Text(denied ? "iPhone の設定アプリで通知を許可してください" : "通知はまだオフです")
                    .font(.subheadline)
                Spacer()
                permissionButton(denied: denied)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(denied ? "iPhone の設定アプリで通知を許可してください" : "通知はまだオフです")
                    .font(.subheadline)
                permissionButton(denied: denied)
            }
        }
    }

    private func permissionButton(denied: Bool) -> some View {
            Button(denied ? "設定を開く" : "オンにする") {
                if denied {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                } else {
                    Task { await model.enableNotifications() }
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .fixedSize()
            .accessibilityIdentifier("enableNotificationsButton")
    }

    /// 振り返りの時刻（0:00 からの分）を時刻の選択に合わせる
    private var reviewTime: Binding<Date> {
        let calendar = model.calendar
        let midnight = calendar.startOfDay(for: model.snapshot.dayStart)
        return Binding {
            calendar.date(byAdding: .minute, value: model.reviewMinutes, to: midnight) ?? midnight
        } set: { date in
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            model.setReviewMinutes((parts.hour ?? 22) * 60 + (parts.minute ?? 0))
        }
    }

    // MARK: 睡眠（DTX-02）

    private var sleepSection: some View {
        Section {
            sleepTimeRow("寝る", systemImage: "moon.zzz", start: true)
            sleepTimeRow("起きる", systemImage: "sunrise", start: false)
            if model.healthNeedsRequest {
                Button {
                    Task { await model.requestHealthAccess() }
                } label: {
                    Label("ヘルスケアから読む", systemImage: "heart.text.square")
                }
                .accessibilityIdentifier("settingsRequestHealthButton")
            }
        } header: {
            Text("睡眠")
        } footer: {
            Text("ヘルスケアに睡眠の記録がない日は、この時刻で寝ていたとみなします。ヘルスケアの許可は iPhone の設定 → ヘルスケア → データアクセスとデバイス → GhostPace で変えられます。")
        }
    }

    /// 5分刻み（朝の計画で直すときと同じ）
    private func sleepTimeRow(_ title: String, systemImage: String, start: Bool) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            StepTimePicker(date: minutesBinding(start: start), minuteInterval: PlanDraft.minuteStep)
                .accessibilityLabel(title)
                .accessibilityIdentifier(start ? "sleepStartPicker" : "sleepEndPicker")
        }
    }

    private func minutesBinding(start: Bool) -> Binding<Date> {
        let calendar = model.calendar
        let midnight = calendar.startOfDay(for: model.snapshot.dayStart)
        return Binding {
            midnight.addingTimeInterval(Double((start ? model.sleepStartMinutes : model.sleepEndMinutes) * 60))
        } set: { date in
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            let minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            model.setSleepSetting(startMinutes: start ? minutes : model.sleepStartMinutes,
                                  endMinutes: start ? model.sleepEndMinutes : minutes)
        }
    }

    // MARK: カテゴリ

    /// 行の右側：ブロック名の数と、デトックスのグループ（DTX-03、2026-10-03）
    @ViewBuilder
    private func categoryDetails(_ category: CategoryOption) -> some View {
        let count = model.projects.filter { $0.category == category }.count
        if count > 0 {
            Text("ブロック名 \(count)").font(.subheadline).foregroundStyle(.secondary)
        }
        if !category.countsAsFocus {
            Text(DetoxGroupSection.label(category.detoxGroup))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
                .accessibilityLabel("グループ \(DetoxGroupSection.label(category.detoxGroup))")
        }
    }

    private func categoryRow(_ category: CategoryOption) -> some View {
        NavigationLink(value: category) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(category.countsAsFocus ? Theme.focus : Theme.detox)
                    .frame(width: 4, height: 22)
                // 文字が大きいときは、ブロック名の数とグループを名前の下に出す（横に並べると1文字ずつ折り返すため）
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(category.name)
                        HStack(spacing: 8) { categoryDetails(category) }
                    }
                    Spacer()
                } else {
                    Text(category.name)
                    Spacer()
                    categoryDetails(category)
                }
            }
        }
    }
}

/// カテゴリの編集（名前・数え方・ブロック名・アーカイブ）。
struct CategoryEditView: View {
    @Bindable var model: AppModel
    let category: CategoryOption
    @State private var name: String
    @State private var renaming: ProjectOption?
    @State private var newProjectName = ""
    @State private var addsProject = false
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, category: CategoryOption) {
        self.model = model
        self.category = category
        _name = State(initialValue: category.name)
    }

    /// 保存されている今の値
    private var current: CategoryOption {
        model.categories.first { $0 == category } ?? category
    }

    var body: some View {
        List {
            Section("名前") {
                TextField("名前", text: $name)
                    .onSubmit(saveName)
                    .submitLabel(.done)
                    .accessibilityIdentifier("categoryNameField")
            }
            Section {
                Picker("数え方", selection: Binding(get: { current.countsAsFocus }, set: { focus in
                    model.updateCategory(current, name: current.name, countsAsFocus: focus)
                })) {
                    Text("集中").tag(true)
                    Text("デトックス").tag(false)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("countsAsFocusPicker")
            } header: {
                Text("数え方")
            } footer: {
                Text("変えると、これから始める記録から効きます。これまでの記録はそのままです。")
            }
            if !current.countsAsFocus {
                DetoxGroupSection(group: Binding(get: { current.detoxGroup }, set: { model.setCategoryGroup(current, $0) }),
                                  footer: "グループを変えると、これまでの点も新しいグループで数え直します。")
            }
            Section {
                ForEach(model.projects.filter { $0.category == category }) { project in
                    Button {
                        newProjectName = project.name
                        renaming = project
                    } label: {
                        HStack {
                            Text(project.name).foregroundStyle(.primary)
                            Spacer()
                            Text("名前を変える").font(.caption).foregroundStyle(Theme.focus)
                        }
                    }
                    .swipeActions {
                        Button("アーカイブ") { model.setProjectArchived(project, true) }
                            .tint(.gray)
                    }
                }
                Button {
                    newProjectName = ""
                    addsProject = true
                } label: {
                    Label("ブロック名を追加", systemImage: "plus.circle.fill")
                }
            } header: {
                Text("ブロック名")
            } footer: {
                Text("左にスワイプでアーカイブ。")
            }
            Section {
                Button("このカテゴリをアーカイブ") {
                    if model.setCategoryArchived(current, true) { dismiss() }
                }
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("archiveCategoryButton")
            } footer: {
                Text("アーカイブしても記録は消えません。選ぶ一覧に出なくなり、「アーカイブしたもの」から戻せます。")
            }
        }
        .navigationTitle(current.name)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear(perform: saveName)
        .alert("ブロック名を変える", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名前", text: $newProjectName)
            Button("キャンセル", role: .cancel) {}
            Button("変える") {
                if let renaming { model.renameProject(renaming, to: newProjectName) }
            }
        }
        .alert("新しいブロック名", isPresented: $addsProject) {
            TextField("例：ゼミ準備", text: $newProjectName)
            Button("キャンセル", role: .cancel) {}
            Button("作成") {
                if model.createProject(name: newProjectName, category: current) == nil, model.errorMessage == nil {
                    model.errorMessage = AppModel.emptyNameMessage
                }
            }
        } message: {
            Text("「\(current.name)」の中に作ります")
        }
    }

    private func saveName() {
        guard name != current.name else { return }
        if !model.updateCategory(current, name: name, countsAsFocus: current.countsAsFocus) {
            name = current.name
        }
    }
}

/// カテゴリを追加（CAT-04）。設定と、ブロックを追加・計画外で開始の画面から開く。
struct AddCategorySheet: View {
    /// 追加できたら true（閉じる）
    let onAdd: (_ name: String, _ countsAsFocus: Bool, _ group: DetoxGroup?) -> Bool
    @State private var name = ""
    @State private var countsAsFocus: Bool
    @State private var group: DetoxGroup?
    private let focusesName: Bool
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    init(startsDetox: Bool = false, focusesName: Bool = true,
         onAdd: @escaping (_ name: String, _ countsAsFocus: Bool, _ group: DetoxGroup?) -> Bool) {
        self.onAdd = onAdd
        self.focusesName = focusesName
        _countsAsFocus = State(initialValue: !startsDetox)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("名前") {
                    TextField("例：ピアノ", text: $name)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit(add)
                        .accessibilityIdentifier("newCategoryNameField")
                }
                Section {
                    Picker("数え方", selection: $countsAsFocus) {
                        Text("集中").tag(true)
                        Text("デトックス").tag(false)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("数え方")
                } footer: {
                    Text("集中：集中の時間と、先週の自分との対戦に数えます。\nデトックス：スマホから離れた時間として、別に数えます。")
                }
                if !countsAsFocus {
                    DetoxGroupSection(group: $group)
                }
            }
            .navigationTitle("カテゴリを追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("追加", action: add)
                        .fontWeight(.semibold)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("confirmAddCategoryButton")
                }
            }
            .onAppear { focused = focusesName }
        }
        .presentationDetents([.medium, .large])
        .tint(Theme.focus)
    }

    private func add() {
        if onAdd(name, countsAsFocus, countsAsFocus ? nil : group) { dismiss() }
    }
}

/// デトックスのグループを選ぶ一覧（DTX-03、CAT-04。2026-10-03 オーナー決定：各行に上限を書く案B）。
/// 家事・運動・休みは1日の上限まで1.5倍
struct DetoxGroupSection: View {
    @Binding var group: DetoxGroup?
    var footer = "家事・運動・休みは、1日の上限まで点が1.5倍になります。同じグループのカテゴリはまとめて数えます。"

    private let choices: [DetoxGroup?] = [.housework, .exercise, .rest, nil]

    var body: some View {
        Section {
            ForEach(choices, id: \.self) { choice in
                Button {
                    group = choice
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.label(choice)).foregroundStyle(.primary)
                            Text(Self.cap(choice)).font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if group == choice { Image(systemName: "checkmark").foregroundStyle(Theme.focus) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(group == choice ? .isSelected : [])
                .accessibilityIdentifier("detoxGroup-\(choice?.rawValue ?? "none")")
            }
        } header: {
            Text("グループ")
        } footer: {
            Text(footer)
        }
    }

    static func label(_ group: DetoxGroup?) -> String {
        switch group {
        case .housework: "家事"
        case .exercise: "運動"
        case .rest: "休み"
        case nil: "なし"
        }
    }

    /// 上限の説明（DetoxGroup.dailyCap から作る）
    static func cap(_ group: DetoxGroup?) -> String {
        guard let group else { return "上乗せなし（記録として使う）" }
        return "1日\(Int(group.dailyCap / 3600))時間まで1.5倍"
    }
}

/// アーカイブしたカテゴリ・ブロック名。戻せる。
struct ArchivedView: View {
    @Bindable var model: AppModel
    @State private var version = 0

    var body: some View {
        let _ = version
        let categories = model.archivedCategories()
        let projects = model.archivedProjects()
        List {
            if categories.isEmpty && projects.isEmpty {
                Text("アーカイブしたものはありません").foregroundStyle(.secondary)
            }
            if !categories.isEmpty {
                Section("カテゴリ") {
                    ForEach(categories) { category in
                        HStack {
                            Text(category.name)
                            Spacer()
                            Button("戻す") {
                                if model.setCategoryArchived(category, false) { version += 1 }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
            if !projects.isEmpty {
                Section("ブロック名") {
                    ForEach(projects) { project in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(project.name)
                                Text(project.category.name).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("戻す") {
                                if model.setProjectArchived(project, false) { version += 1 }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
        .navigationTitle("アーカイブしたもの")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// ブロックするアプリを選ぶ画面を出すときの値。
private struct BlockSelectionRequest: Identifiable, Hashable {
    var purpose: BlockSelectionPurpose
    var requiresHold: Bool
    var id: Self { self }
}
