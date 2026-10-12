import SwiftUI

/// ラップの一覧（GHO-06）：ホームの裏とその日のグラフの、グラフの下（2026-10-12）。2時間ごとの自分・相手のポイントと差
/// （「10:00–12:00　+1.6pt」「9.5pt・先週 7.9pt」。相手が目標なら「目標」、今日なら「今日」）。
/// 一覧はその中で縦にスクロールし、初めは一番新しい行が見える位置。行が足されたら（［▶］で流している間）最新の行へ送る
struct RaceLapList: View {
    /// 出す行（Laps.listed で選んだもの）
    let laps: [Lap]
    let rival: RaceRival
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ラップ（2時間ごと）").font(.subheadline.bold()).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.7)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(laps) { lap in
                            row(lap)
                                .id(lap.id)
                                // 足すときはふわっと出す（動きは足す側の withAnimation で。視差効果を減らす設定なら動きなし）
                                .transition(.opacity)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // 初めは一番新しい行が見える位置（カードが伸び縮みしても下に合わせる）。行が少なく入りきるときは上から並べる
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                .defaultScrollAnchor(.top, for: .alignment)
                .scrollBounceBehavior(.basedOnSize)
                .onAppear {
                    if let last = laps.last?.id { proxy.scrollTo(last, anchor: .bottom) }
                }
                // 行を足したら、手でスクロールしていても最新の行へ送る
                .onChange(of: laps.last?.id) { _, last in
                    guard let last else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
        // 文字の大きい設定でも一覧に数行入る大きさまで（カードの下の5割に入れる）
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lapList")
    }

    /// 1行目に区間と差「10:00–12:00　+1.6pt」、2行目に「9.5pt・先週 7.9pt」（2026-10-12 オーナー決定。それまでは集中した時間）
    private func row(_ lap: Lap) -> some View {
        // 相手が今日なら差は今日−この日（ラップ表と同じ向き）。0.0 は前向きな色
        let gap = rival.lapGap(lap)
        return VStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(AppModel.lapRange(lap) + (lap.isCurrent ? "（途中）" : "")).font(.subheadline.monospacedDigit())
                    Spacer(minLength: 8)
                    Text(RaceChartLayout.signedPoints(gap)).font(.subheadline.bold().monospacedDigit())
                        .foregroundStyle(RaceChartLayout.isAhead(gap) ? Theme.lead : Theme.behind)
                }
                Text("\(RaceChart.pointText(lap.minePoints))・\(rival.shortName) \(RaceChart.pointText(lap.opponentPoints))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Divider()
        }
    }
}
