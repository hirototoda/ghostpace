import SwiftUI

/// カテゴリ（集中・デジタルデトックス）とそのブロック名を選ぶ（計画外で開始・手動で記録で同じ形、TMR-01・TMR-13）。
/// まだ選んでいなければ最初のカテゴリ。その場でカテゴリ（CAT-04）・ブロック名（CAT-03）を作れる
struct CategoryProjectPicker: View {
    let categories: [CategoryOption]
    var projects: [ProjectOption] = []
    var onCreateProject: ((String, CategoryOption) -> ProjectOption?)?
    var onCreateCategory: ((String, Bool, DetoxGroup?) -> CategoryOption?)?
    /// 選んだカテゴリ。nil なら最初のカテゴリ（`resolved` で読む）
    @Binding var selected: CategoryOption?
    @Binding var project: ProjectOption?

    @State private var addedProjects: [ProjectOption] = []
    @State private var newProjectName = ""
    @State private var addsProject = false
    @State private var addsCategory = false
    @State private var addedCategories: [CategoryOption] = []

    /// 選んだカテゴリ。まだ選んでいなければ最初のカテゴリ
    static func resolved(_ selected: CategoryOption?, in categories: [CategoryOption]) -> CategoryOption? {
        selected ?? categories.first
    }

    private var category: CategoryOption? { Self.resolved(selected, in: categories) }

    var body: some View {
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
    }

    private func categorySection(_ title: LocalizedStringKey, focus: Bool) -> some View {
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

    private var shownCategories: [CategoryOption] {
        categories + addedCategories.filter { !categories.contains($0) }
    }

    private func createProject() {
        guard let category, let created = onCreateProject?(newProjectName, category) else { return }
        if !shownProjects.contains(created) { addedProjects.append(created) }
        project = created
    }
}
