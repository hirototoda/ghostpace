import SwiftUI

/// 数字を大きく、単位を小さく表示する。例: **1**時間**30**分
struct DurationText: View {
    let seconds: Int
    var signed = false
    var size: CGFloat = 96

    var body: some View {
        let parts = DurationFormat.parts(seconds)
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            if signed {
                Text(DurationFormat.sign(seconds))
                    .font(Theme.heroNumber(size * 0.8))
            }
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                Text(part.number)
                    .font(Theme.heroNumber(size))
                Text(part.unit)
                    .font(.system(size: size * 0.28, weight: .semibold))
                    .padding(.trailing, 4)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(signed ? DurationFormat.signed(seconds) : DurationFormat.japanese(seconds))
    }
}

/// 小さな数値の表示。例: デトックス 30分
struct StatLabel: View {
    let title: String
    let seconds: Int
    var color: Color = .secondary
    var systemImage: String?

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage).foregroundStyle(color)
            }
            Text(title).foregroundStyle(.secondary)
            Text(DurationFormat.japanese(seconds)).fontWeight(.semibold).monospacedDigit()
        }
        .font(.subheadline)
    }
}
