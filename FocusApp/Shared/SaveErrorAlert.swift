import SwiftUI

extension View {
    /// 保存に失敗したとき・操作できなかったときの知らせ。いちばん上に見えている階層だけが出す
    /// （下の階層から出すと、上に重なった全画面やシートが閉じてしまうため）。
    func saveErrorAlert(_ message: Binding<String?>, when isTopmost: Bool = true) -> some View {
        alert(message.wrappedValue ?? "", isPresented: Binding(get: { isTopmost && message.wrappedValue != nil },
                                                             set: { if !$0 { message.wrappedValue = nil } })) {
            Button("OK") {}
        } message: {
            if message.wrappedValue == AppModel.saveErrorMessage {
                Text("もう一度お試しください。")
            }
        }
    }
}
