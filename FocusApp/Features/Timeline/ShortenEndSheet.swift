import SwiftUI

/// 終わった記録の終了時刻を早める（TMR-08・TML-04、docs/product/features/timeline.md）。
/// 選べるのは開始の1分後から今の終了時刻の1分前まで。延ばすことはできない。
struct ShortenEndSheet: View {
    let session: FocusSession
    /// 開始と終了で日付が変わる記録なら日付も選ぶ
    let showsDate: Bool
    let onSave: (Date) -> Void

    @State private var end: Date
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(session: FocusSession, showsDate: Bool, onSave: @escaping (Date) -> Void) {
        self.session = session
        self.showsDate = showsDate
        self.onSave = onSave
        _end = State(initialValue: Self.range(of: session).upperBound)
    }

    /// 開始の1分後〜今の終了時刻の1分前
    static func range(of session: FocusSession) -> ClosedRange<Date> {
        let upper = (session.endAt ?? session.startAt).addingTimeInterval(-60)
        return min(session.startAt.addingTimeInterval(60), upper)...upper
    }

    private let hm = Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("\(session.title)：\(session.startAt.formatted(hm)) 開始・\(session.endAt?.formatted(hm) ?? "") 終了")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("新しい終了時刻").font(.subheadline.bold()).foregroundStyle(.secondary)
                    DatePicker("新しい終了時刻", selection: $end, in: Self.range(of: session), displayedComponents: components)
                        .datePickerStyle(.compact)
                        .labelsHidden()
                        .environment(\.locale, Locale(identifier: "ja_JP"))
                        .accessibilityIdentifier("shortenEndPicker")
                    let actual = session.endIfShortened(to: end)
                    if actual != end {
                        Label("一時停止中なので \(actual.formatted(hm)) で終わります", systemImage: "pause.circle")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Text("終了時刻は早めることだけできます。元の終了時刻は記録に残ります。")
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    onSave(end)
                } label: {
                    Text("この時刻に早める").font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.extraLarge)
                .padding(.horizontal, 20).padding(.bottom, 8)
                .accessibilityIdentifier("shortenEndButton")
            }
            .navigationTitle("終了時刻を早める")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる", systemImage: "xmark") { dismiss() }
                }
            }
        }
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
        .tint(Theme.focus)
    }

    private var components: DatePickerComponents { showsDate ? [.date, .hourAndMinute] : .hourAndMinute }
}
