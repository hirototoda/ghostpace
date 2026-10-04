import SwiftUI

/// 対戦相手（GHO-10）。先週の自分か、今日の目標。
enum Opponent: String, Hashable, CaseIterable {
    case lastWeek
    case goal

    var shortName: String {
        switch self {
        case .lastWeek: "先週"
        case .goal: "目標"
        }
    }

    var diffPrefix: String {
        switch self {
        case .lastWeek: "先週の自分より"
        case .goal: "目標より"
        }
    }

    var pickerName: String {
        switch self {
        case .lastWeek: "先週の自分"
        case .goal: "目標"
        }
    }
}

/// ホームの数字（リング式、2026-09-30 オーナー決定）。マラソン風に自分とゴーストが走る（GHO-12、2026-10-01）。
/// 外側の円＝今日、内側の円＝対戦相手（先週の同じ曜日、または目標）。1周＝相手の1日分の集中時間。
/// 円を押すと裏返って24時間のグラフ（GHO-13）。
/// 相手がいなければ、1周＝今日の計画の集中時間の1重の円にする。
/// 相手が2人以上いれば、円の中の「vs 先週の自分」を押すと「比べる相手」の一覧が出る（GHO-10、2026-10-01 オーナー案）。相手の時間はゴーストの吹き出し。
struct RingHero: View {
    let snapshot: HomeSnapshot
    @Binding var opponent: Opponent
    @State private var showsPicker = false
    /// 開いたときのアニメーションの進み（0〜1、GHO-12）
    @State private var runFraction = 0.0
    /// 0＝表（トラック）、180＝裏（グラフ、GHO-13）
    @State private var flipAngle = 0.0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    #if DEBUG
    /// 見本の撮影用に、裏（グラフ）から始める（`-flipRace`）
    @Environment(\.raceStartsFlipped) private var startsFlipped
    #endif

    /// 選べる相手（データのあるものだけ）
    private var available: [Opponent] {
        Opponent.allCases.filter { snapshot.opponentFocusSeconds($0) != nil }
    }

    private var current: Opponent? {
        available.contains(opponent) ? opponent : available.first
    }

    var body: some View {
        VStack(spacing: 20) {
            raceCard
            diffArea
            if let opened = snapshot.opened { OpenedLabel(opened: opened) }
        }
        .sheet(isPresented: $showsPicker) { opponentPicker }
        // アプリを開くたびに走ってくる。ほかのタブから戻ったときは走らない
        .onAppear {
            if runFraction == 0 {
                #if DEBUG
                if startsFlipped { flipAngle = 180 }
                #endif
                run()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                runFraction = 0
                flipAngle = 0
            case .active:
                if runFraction == 0 { run() }
            default:
                break
            }
        }
    }

    /// 比べる相手の一覧。相手を増やすときはここに行を足す（GHO-05）
    private var opponentPicker: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(available, id: \.self) { item in
                        Button {
                            opponent = item
                            showsPicker = false
                        } label: {
                            let layout = dynamicTypeSize.isAccessibilitySize
                                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 12))
                            layout {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 8) {
                                        Image(systemName: item == .goal ? "flag.fill" : "clock.arrow.circlepath")
                                            .foregroundStyle(Theme.ghost)
                                        Text(item.pickerName).font(.headline)
                                        Image(systemName: "checkmark").font(.subheadline.bold())
                                            .foregroundStyle(Theme.focus).opacity(item == current ? 1 : 0)
                                    }
                                    Text(opponentDetail(item)).font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                if let diff = snapshot.opponentDiffSeconds(item) {
                                    Text(DurationFormat.signed(diff)).font(.subheadline.bold().monospacedDigit())
                                        .foregroundStyle(Theme.diffColor(diff))
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("opponent-\(item.rawValue)")
                    }
                } footer: {
                    Text("＋−の数字は、今のあなたとの差です。")
                }
            }
            .navigationTitle("比べる相手")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private func opponentDetail(_ item: Opponent) -> String {
        let now = snapshot.opponentFocusSeconds(item).map(DurationFormat.japanese) ?? "—"
        let whole = snapshot.opponentWholeDaySeconds(item).map(DurationFormat.japanese) ?? "—"
        switch item {
        case .lastWeek: return "先週の同じ曜日。この時刻まで \(now)・1日で \(whole)"
        case .goal: return "今日の目標を計画どおりに。この時刻まで \(now)・1日で \(whole)"
        }
    }

    /// 表＝トラック、押すと裏返って24時間のグラフ（GHO-12・13）
    private var raceCard: some View {
        FlipCard(angle: flipAngle) {
            track(current)
        } back: {
            RaceChart(snapshot: snapshot, opponent: current, isShowing: flipAngle >= 90)
        }
        // 横幅いっぱいで、縦は横の1.25倍（グラフの差を大きく見せる。2026-10-03 オーナー決定、1.1倍と比べた）。
        // 文字の大きい設定では前の大きさ（正方形・最大320）に戻し、下の差の行がボタンの裏に隠れないようにする（Claude 補足）
        .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? 320 : 440)
        .aspectRatio(dynamicTypeSize.isAccessibilitySize ? 1 : 1 / 1.25, contentMode: .fit)
        .contentShape(Rectangle())
        .onTapGesture(perform: flip)
        .accessibilityAction(named: flipAngle < 90 ? "グラフに裏返す" : "円に戻す", flip)
    }

    private func flip() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.6)) {
            flipAngle = flipAngle < 90 ? 180 : 0
        }
    }

    /// 開いたときに、0から今の地点まで走ってくる（約1.2秒）。視差効果を減らす設定なら走らない
    private func run() {
        runFraction = 0
        if reduceMotion {
            runFraction = 1
        } else {
            withAnimation(.easeOut(duration: 1.2)) { runFraction = 1 }
        }
    }

    private func track(_ opponent: Opponent?) -> some View {
        ZStack {
            lanes(opponent)
            centerText(opponent)
                .padding(64)
        }
        // 円は今までの大きさのまま（横幅いっぱいにすると、左に来たゴーストの吹き出しが画面の端で切れる。Claude 補足）
        .frame(maxWidth: 320, maxHeight: 320)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("raceTrack")
    }

    private func centerText(_ opponent: Opponent?) -> some View {
        VStack(spacing: 4) {
            Text("今日の集中").font(.subheadline).foregroundStyle(.secondary)
            DurationText(seconds: snapshot.focusSeconds, size: 52)
                .accessibilityIdentifier("todayFocus")
            if let opponent, let now = snapshot.opponentFocusSeconds(opponent) {
                // 相手の時間はゴーストの吹き出しに出す。ここは相手の名前と切り替え
                let label = HStack(spacing: 4) {
                    Text("vs \(opponent.pickerName)")
                    if available.count > 1 {
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                    }
                }
                .font(.footnote).foregroundStyle(.secondary)
                .accessibilityLabel("\(opponent.shortName) \(DurationFormat.japanese(now))")
                .accessibilityIdentifier(opponent == .goal ? "goalFocus" : "ghostFocus")
                if available.count > 1 {
                    Button { showsPicker = true } label: {
                        label.padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Capsule().fill(Color.secondary.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("比べる相手を選びます")
                    .accessibilityIdentifier("opponentButton")
                } else {
                    label
                }
            } else if snapshot.plannedFocusSeconds > 0 {
                Text("計画 \(DurationFormat.japanese(snapshot.plannedFocusSeconds))")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }

    /// 外側のレーン＝自分、内側のレーン＝相手（2026-10-01 案A を選んだ）
    @ViewBuilder
    private func lanes(_ opponent: Opponent?) -> some View {
        let (me, ghost) = snapshot.raceProgress(opponent)
        let bubble = opponent.flatMap { o in snapshot.opponentFocusSeconds(o).map { (o.shortName, $0) } }
        let outer: CGFloat = 26, inner: CGFloat = 50
        ZStack {
            TrackLane(progress: 1, inset: outer).stroke(Theme.focus.opacity(0.15), lineWidth: 18)
            TrackLane(progress: me * runFraction, inset: outer)
                .stroke(Theme.focus, style: StrokeStyle(lineWidth: 18, lineCap: .round))
            if let ghost {
                TrackLane(progress: 1, inset: inner).stroke(Theme.ghost.opacity(0.15), lineWidth: 12)
                TrackLane(progress: ghost * runFraction, inset: inner)
                    .stroke(Theme.ghost.opacity(0.7), style: StrokeStyle(lineWidth: 12, lineCap: .round))
            }
            finishFlag
            if let ghost {
                TrackRunner(kind: .ghost, progress: ghost, fraction: runFraction, inset: inner,
                            bubbleTitle: bubble?.0, bubbleSeconds: bubble?.1 ?? 0)
            }
            TrackRunner(kind: .me, progress: me, fraction: runFraction, inset: outer)
        }
    }

    /// スタートとゴール（一番上）
    private var finishFlag: some View {
        GeometryReader { proxy in
            let rect = TrackLane.laneRect(CGRect(origin: .zero, size: proxy.size), inset: 0)
            Image(systemName: "flag.checkered")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .position(x: rect.midX - 16, y: rect.minY + 6)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var diffArea: some View {
        if let current, let diff = snapshot.opponentDiffSeconds(current) {
            GhostDiffLine(seconds: diff, prefix: current.diffPrefix)
        } else {
            Text("来週から先週の自分と対戦できます")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

/// 「先週の自分より +25分」。ホームとタイマー画面で共通。
struct GhostDiffLine: View {
    let seconds: Int
    var prefix = Opponent.lastWeek.diffPrefix

    var body: some View {
        HStack(spacing: 6) {
            Text(prefix).foregroundStyle(.secondary)
            Text(DurationFormat.signed(seconds)).fontWeight(.bold).monospacedDigit()
                .foregroundStyle(Theme.diffColor(seconds))
        }
        .font(.title3)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ghostDiff")
    }
}

struct Ring: View {
    let progress: Double
    let color: Color
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
    }
}

/// 表と裏を持つカード。`angle` が90度を超えたら裏を見せる（GHO-13）
struct FlipCard<Front: View, Back: View>: View, @MainActor Animatable {
    var angle: Double
    @ViewBuilder var front: Front
    @ViewBuilder var back: Back

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    var body: some View {
        ZStack {
            front.opacity(angle < 90 ? 1 : 0)
                .accessibilityHidden(angle >= 90)
                .allowsHitTesting(angle < 90)
            back.opacity(angle < 90 ? 0 : 1)
                .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
                .accessibilityHidden(angle < 90)
                .allowsHitTesting(angle >= 90)
        }
        .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
    }
}

#if DEBUG
extension EnvironmentValues {
    /// 見本の撮影用：裏（グラフ）から始める
    @Entry var raceStartsFlipped = false
}
#endif
