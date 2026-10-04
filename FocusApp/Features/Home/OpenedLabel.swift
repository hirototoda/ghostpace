import SwiftUI

/// その日に開けた時間と回数（DTX-05）。ホームの小さい数字・振り返りの「今日の結果」・タイムラインの日付の下（TML-05）で同じ形にする。
/// 回数は札にする（2026-10-03 オーナー決定、案B）。開けていなければ前向きな色、開けたときは落ち着いた色（赤で責めない）。
struct OpenedLabel: View {
    let opened: OpenedTime

    var body: some View {
        // 大きな文字で1行に収まらなければ、「開けた」と時間・回数を2段にする（語の途中で折り返さない）
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { lead; amount }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) { lead }
                HStack(spacing: 6) { amount }
            }
        }
        .font(.subheadline)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(opened.text)
        .accessibilityIdentifier("openedLabel")
    }

    /// 鍵と「開けた」（開けていなければ「開けていない」）
    @ViewBuilder
    private var lead: some View {
        Image(systemName: opened.isNone ? "lock.fill" : "lock.open.fill")
            .foregroundStyle(opened.isNone ? Theme.detox : Theme.behind)
        if opened.isNone {
            Text(opened.text).fontWeight(.semibold).foregroundStyle(Theme.detox).fixedSize()
        } else {
            Text("開けた").foregroundStyle(.secondary).fixedSize()
        }
    }

    /// 時間と回数の札
    @ViewBuilder
    private var amount: some View {
        if !opened.isNone {
            Text(opened.durationText).fontWeight(.semibold).monospacedDigit().fixedSize()
            if opened.count > 0 {
                Text("\(opened.count)回").font(.caption.bold()).monospacedDigit().fixedSize()
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
        }
    }
}
