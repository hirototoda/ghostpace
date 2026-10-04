import SwiftUI

/// 止め忘れの疑いがあるときの終了時刻の確認（TMR-08、docs/product/features/focus-timer.md）。
/// 予定を30分以上超過／ストップウォッチで3時間超／朝4:00をまたいだ、のどれかで出る。閉じると終了しない。
struct EndTimeSheet: View {
    let check: EndTimeCheck
    let onEnd: (Date) -> Void

    @State private var end: Date
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(check: EndTimeCheck, onEnd: @escaping (Date) -> Void) {
        self.check = check
        self.onEnd = onEnd
        _end = State(initialValue: check.initialEnd)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(message).font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("やめた時刻").font(.subheadline.bold()).foregroundStyle(.secondary)
                    DatePicker("やめた時刻", selection: $end, in: check.range, displayedComponents: components)
                        .datePickerStyle(.compact)
                        .labelsHidden()
                        .environment(\.locale, Locale(identifier: "ja_JP"))
                        .accessibilityIdentifier("endTimePicker")
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    onEnd(end)
                } label: {
                    Text("この時刻で終了").font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.extraLarge)
                .padding(.horizontal, 20).padding(.bottom, 8)
                .accessibilityIdentifier("confirmEndTimeButton")
            }
            .navigationTitle("いつやめましたか？")
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

    /// 開始と今が同じ日なら時刻だけ、日をまたいでいれば日付も選ぶ
    private var components: DatePickerComponents { check.showsDate ? [.date, .hourAndMinute] : .hourAndMinute }

    private var message: String {
        let style = Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
        let elapsed = Int(check.askedAt.timeIntervalSince(check.startAt))
        return "\(check.startAt.formatted(style)) に開始してから \(DurationFormat.japanese(elapsed)) たっています。実際にやめた時刻を選んでください。"
    }
}
