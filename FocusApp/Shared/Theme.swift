import SwiftUI
import UIKit

/// 色の意味を固定する（docs/product/features/home.md）。リード＝前向きな色、負け＝落ち着いた色。赤で責めない。
enum Theme {
    /// 集中（勉強・仕事・読書）
    static let focus = Color.indigo
    /// デジタルデトックス（掃除・休み・料理・運動）
    static let detox = Color.teal
    /// 先週の自分にリードしている
    static let lead = Color(light: UIColor(red: 0.72, green: 0.50, blue: 0.05, alpha: 1),
                            dark: UIColor(red: 0.96, green: 0.76, blue: 0.30, alpha: 1))
    /// 先週の自分に負けている
    static let behind = Color.secondary
    /// 先週の自分（ゴースト）
    static let ghost = Color.gray
    /// ゲーム・SNS の時間（BLK-10）。集中・デトックスと見分けがつく、明るい色
    static let play = Color.orange
    /// 自己ベストのラップ表で今日が上回った数字（ANA-06、2026-10-06 オーナー決定）。
    /// 陸上の速報で記録を赤く出すのと同じ「勝っている」の印。責める意味では使わない
    static let record = Color.red
    /// ラップ表で今日の区間が区間ベストを超えた印 ★ にだけ使う金（ANA-11、2026-10-07 オーナー決定）。数字の色には使わない
    static let gold = Color(light: UIColor(red: 0.85, green: 0.62, blue: 0.0, alpha: 1),
                            dark: UIColor(red: 1.0, green: 0.80, blue: 0.22, alpha: 1))

    static func diffColor(_ seconds: Int) -> Color {
        seconds >= 0 ? lead : behind
    }

    /// 大きな数字の書体。案どうしでそろえる。
    static func heroNumber(_ size: CGFloat) -> Font {
        .system(size: size, weight: .bold).monospacedDigit()
    }
}

extension Color {
    init(light: UIColor, dark: UIColor) {
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}
