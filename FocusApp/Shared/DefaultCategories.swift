import Foundation
import SwiftUI

/// カテゴリ。同じかどうかは id で決める（名前は後で変えられるため）。
struct CategoryOption: Identifiable, Hashable {
    var id: UUID
    var name: String
    /// 集中時間に数えるか。false ならデジタルデトックス（CAT-02）
    var countsAsFocus: Bool
    /// デトックスのグループ（DTX-03、2026-10-03）。nil は上乗せなし。集中のカテゴリは常に nil
    var detoxGroup: DetoxGroup?

    init(id: UUID = UUID(), name: String, countsAsFocus: Bool, detoxGroup: DetoxGroup? = nil) {
        self.id = id
        self.name = name
        self.countsAsFocus = countsAsFocus
        self.detoxGroup = countsAsFocus ? nil : detoxGroup
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// 参照先のカテゴリが見つからないときの代わり。記録は消さず、集中には数えない。
    static let unknown = CategoryOption(id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
                                        name: "不明", countsAsFocus: false)

    /// ゲーム・SNS の時間（BLK-10）。カテゴリの行は作らず、この決まった ID の計画ブロックをゲーム・SNS の時間とする。
    /// 集中にもデトックスにも数えず、タイマーは始めない（app-blocking.md）
    static let gameSNS = CategoryOption(id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x0b, 0x10)),
                                        name: "ゲーム・SNS", countsAsFocus: false)

    /// ゲーム・SNS の時間か
    var isUnblock: Bool { Self.isUnblock(id: id) }

    static func isUnblock(id: UUID) -> Bool { id == gameSNS.id }

    /// デトックスに数えるか（集中に数えず、ゲーム・SNS の時間でもない。計画の合計に使う）
    var countsAsDetox: Bool { !countsAsFocus && !isUnblock }
}

/// デフォルトのカテゴリ（CAT-01）。初回起動時に保存する元になる（UUID は保存時に採番）。
/// 2026-10-03 に掃除・料理・瞑想をブロック名に組み替えた（settings.md「カテゴリの組み替え」）
enum DefaultCategories {
    static let all: [CategoryOption] = [
        .init(name: "勉強", countsAsFocus: true),
        .init(name: "仕事", countsAsFocus: true),
        .init(name: "読書", countsAsFocus: true),
        .init(name: housework, countsAsFocus: false, detoxGroup: .housework),
        .init(name: rest, countsAsFocus: false, detoxGroup: .rest),
        .init(name: "運動", countsAsFocus: false, detoxGroup: .exercise),
    ]

    static let housework = "家事"
    static let rest = "休み"

    /// デフォルトのブロック名（カテゴリ名 → ブロック名）
    static let projects: [(category: String, names: [String])] = [
        (housework, ["掃除", "料理", "洗濯"]),
        (rest, ["瞑想", "休憩"]),
    ]
}

/// ブロック名（プロジェクト）。どれかのカテゴリに属し、選ぶとカテゴリも決まる（CAT-03）。
struct ProjectOption: Identifiable, Hashable {
    var id: UUID
    var name: String
    var category: CategoryOption

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension Theme {
    /// 計画ブロック・カテゴリの色（集中＝藍、デトックス＝青緑、ゲーム・SNS＝オレンジ）
    static func color(for category: CategoryOption) -> Color {
        category.isUnblock ? play : category.countsAsFocus ? focus : detox
    }
}
