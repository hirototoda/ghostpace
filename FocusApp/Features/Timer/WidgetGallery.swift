#if DEBUG
import SwiftUI
import WidgetKit

/// ウィジェットの見本（画面の確認用、`-widgetGallery`、WID-01）。今の材料で4つの置き場所の見た目を並べる
struct WidgetGallery: View {
    let model: AppModel

    var body: some View {
        let now = model.clock.now()
        let entry = GhostPaceEntry(date: now, content: model.widgetSnapshot(now: now, isConfirmed: model.isPlanConfirmed).entry(at: now))
        ScrollView {
            VStack(spacing: 20) {
                Text("ホーム画面（小・中）とロック画面").font(.headline)
                HStack(spacing: 16) {
                    tile(GhostPaceWidgetView(entry: entry, family: .systemSmall), width: 160, height: 160)
                    tile(GhostPaceWidgetView(entry: entry, family: .accessoryRectangular), width: 160, height: 72, dark: true)
                }
                tile(GhostPaceWidgetView(entry: entry, family: .systemMedium), width: 338, height: 158)
                tile(GhostPaceWidgetView(entry: entry, family: .accessoryInline), width: 338, height: 32, dark: true)
            }
            .padding(20)
        }
        .background(LinearGradient(colors: [.indigo.opacity(0.5), .teal.opacity(0.5)], startPoint: .top, endPoint: .bottom))
    }

    private func tile(_ content: some View, width: CGFloat, height: CGFloat, dark: Bool = false) -> some View {
        content
            .padding(dark ? 8 : 14)
            .frame(width: width, height: height)
            .background(RoundedRectangle(cornerRadius: dark ? 12 : 22).fill(dark ? Color.black.opacity(0.35) : Color(.systemBackground)))
            .environment(\.colorScheme, dark ? .dark : .light)
    }
}
#endif
