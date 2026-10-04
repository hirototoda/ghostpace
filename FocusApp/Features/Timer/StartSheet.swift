import SwiftUI

/// 計画外で開始するときのシート（TMR-01, TMR-07）。
/// カテゴリ（とそのブロック名）を選び、長さを 5分〜3時間（5分刻み）のスライダーで決めるか、決めずにストップウォッチで始める。
struct StartSheet: View {
    let now: Date
    let categories: [CategoryOption]
    /// ブロック名（CAT-03）。選んだカテゴリの分だけ出す
    var projects: [ProjectOption] = []
    /// ブロック名をその場で作る（CAT-03）
    var onCreateProject: ((String, CategoryOption) -> ProjectOption?)?
    /// カテゴリをその場で作る（CAT-04）
    var onCreateCategory: ((String, Bool, DetoxGroup?) -> CategoryOption?)?
    let onStart: (_ category: CategoryOption, _ project: ProjectOption?, _ plannedMinutes: Int?) -> Void

    @State private var selected: CategoryOption?
    @State private var project: ProjectOption?
    @State private var addedProjects: [ProjectOption] = []
    @State private var newProjectName = ""
    @State private var addsProject = false
    @State private var decidesLength = true
    @State private var addsCategory = false
    @State private var addedCategories: [CategoryOption] = []
    /// 初期位置は毎回25分
    @State var minutes = 25
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    categorySection("集中", focus: true)
                    categorySection("デジタルデトックス", focus: false)
                    if onCreateCategory != nil {
                        Button {
                            addsCategory = true
                        } label: {
                            Label("カテゴリ", systemImage: "plus").font(.subheadline)
                                .padding(.horizontal, 14).frame(minHeight: 36)
                                .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.4),
                                                                style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                        }
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("addCategoryButton")
                    }
                    if let category { projectSection(category) }
                    lengthSection
                }
                .padding(20)
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    if let category { onStart(category, project, decidesLength ? minutes : nil) }
                } label: {
                    Text("\(project?.name ?? category?.name ?? "")を開始").font(.headline).frame(maxWidth: .infinity)
                }
                .disabled(category == nil)
                .buttonStyle(.borderedProminent)
                .controlSize(.extraLarge)
                .padding(.horizontal, 20).padding(.bottom, 8)
                .accessibilityIdentifier("sheetStartButton")
            }
            .sheet(isPresented: $addsCategory) {
                AddCategorySheet { name, focus, group in
                    guard let created = onCreateCategory?(name, focus, group) else { return false }
                    if !shownCategories.contains(created) { addedCategories.append(created) }
                    selected = created
                    project = nil
                    return true
                }
            }
            .alert("新しいブロック名", isPresented: $addsProject) {
                TextField("例：ゼミ準備", text: $newProjectName)
                Button("キャンセル", role: .cancel) {}
                Button("作成") { createProject() }
            } message: {
                Text("「\(category?.name ?? "")」の中に作ります")
            }
            .navigationTitle("計画外で開始")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる", systemImage: "xmark") { dismiss() }
                }
            }
        }
        .tint(Theme.focus)
    }

    private func categorySection(_ title: String, focus: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.bold()).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 10)], spacing: 10) {
                ForEach(shownCategories.filter { $0.countsAsFocus == focus }) { option in
                    let isOn = option == category
                    let color = focus ? Theme.focus : Theme.detox
                    Button {
                        if option != category { project = nil }
                        selected = option
                    } label: {
                        Text(option.name)
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(isOn ? .white : color)
                            .background(RoundedRectangle(cornerRadius: 12).fill(isOn ? color : color.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
        }
    }

    /// 選んだカテゴリのブロック名（ブロックを追加と同じ形。初期は「なし」）
    private func projectSection(_ category: CategoryOption) -> some View {
        let color = Theme.color(for: category)
        return VStack(alignment: .leading, spacing: 10) {
            Text("ブロック名").font(.subheadline.bold()).foregroundStyle(.secondary)
            FlowLayout(spacing: 8) {
                chip("なし", color: color, selected: project == nil) { project = nil }
                ForEach(shownProjects.filter { $0.category == category }) { option in
                    chip(option.name, color: color, selected: project == option) { project = option }
                }
                if onCreateProject != nil {
                    Button {
                        newProjectName = ""
                        addsProject = true
                    } label: {
                        Image(systemName: "plus").padding(10).frame(minWidth: 36, minHeight: 36)
                            .foregroundStyle(color)
                            .overlay(Capsule().strokeBorder(color.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                    }
                    .accessibilityLabel("\(category.name)に新しいブロック名を作る")
                    .accessibilityIdentifier("addProjectButton")
                }
            }
        }
    }

    private func chip(_ title: String, color: Color, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .foregroundStyle(selected ? .white : color)
                .background(Capsule().fill(selected ? color : color.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var shownProjects: [ProjectOption] {
        projects + addedProjects.filter { !projects.contains($0) }
    }

    private func createProject() {
        guard let category, let created = onCreateProject?(newProjectName, category) else { return }
        if !shownProjects.contains(created) { addedProjects.append(created) }
        project = created
    }

    private var lengthSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("長さ").font(.subheadline.bold()).foregroundStyle(.secondary)
            Picker("長さ", selection: $decidesLength) {
                Text("時間を決める").tag(true)
                Text("決めない").tag(false)
            }
            .pickerStyle(.segmented)

            if decidesLength {
                LengthSlider(minutes: $minutes, caption: endText)
            } else {
                Text("ストップウォッチで数え続けます。予定時間の通知は出ません。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    /// 選んだカテゴリ。まだ選んでいなければ最初のカテゴリ
    private var category: CategoryOption? { selected ?? categories.first }

    private var shownCategories: [CategoryOption] {
        categories + addedCategories.filter { !categories.contains($0) }
    }

    private var endText: String {
        let end = now.addingTimeInterval(Double(minutes * 60))
        let style = Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
        return "\(end.formatted(style)) 終了予定"
    }
}
