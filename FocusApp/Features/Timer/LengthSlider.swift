import SwiftUI

/// 長さのスライダー（5分〜3時間、5分刻み）。計画外の開始と計画ブロックで共通。
struct LengthSlider: View {
    static let minuteRange: ClosedRange<Double> = 5...180
    static let minuteStep: Double = 5

    @Binding var minutes: Int
    /// 大きな数字の下に出す補足（例: 11:45 終了予定）
    var caption: String?

    var body: some View {
        VStack(spacing: 6) {
            DurationText(seconds: minutes * 60, size: 48)
                .accessibilityIdentifier("lengthMinutes")
            if let caption {
                Text(caption).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: Binding(get: { Double(minutes) }, set: { minutes = Int($0) }),
                   in: Self.minuteRange, step: Self.minuteStep) {
                Text("長さ")
            } minimumValueLabel: {
                Text("5分").font(.caption)
            } maximumValueLabel: {
                Text("3時間").font(.caption)
            }
            .accessibilityValue(DurationFormat.japanese(minutes * 60))
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
    }
}
