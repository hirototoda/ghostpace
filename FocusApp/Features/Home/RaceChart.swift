import Charts
import SwiftUI

#if DEBUG
extension EnvironmentValues {
    /// 見本の撮影用：裏のグラフを1日全体で始める（`-raceWholeDay`）
    @Entry var raceStartsWholeDay = false
    /// 見本の撮影用：裏が見えたら［▶］で1日を流し始める（`-raceReplay`）
    @Entry var raceStartsReplay = false
}
#endif

/// 円の裏のグラフ（GHO-13）。横＝時刻、縦＝その時刻までにたまったポイント（集中＋デトックス）。
/// 自分は実線、相手は点線。相手の今より先は薄くする。2026-10-02 から時間の線はなくしてポイントだけ（オーナー決定、Q26）
/// 2026-10-03 から今の2時間前〜1時間先の3時間で始め、横にずらせて（2026-10-05 から離しても勢いで滑る）、［1日］で 4:00〜翌4:00。上の行に相手との差。
/// 起動したとき・ほかのアプリから戻ったときの最初の裏返しだけ、直前2時間の線が伸びる。［▶］で 4:00 から今までをゆっくり流す
/// （範囲と動きは RaceChartLayout）
struct RaceChart: View {
    let snapshot: HomeSnapshot
    let opponent: Opponent?
    /// 裏が見えているか（見えたときに動きを始める）
    var isShowing = true
    /// 過ぎた日のグラフ（分析、ANA-05）：4:00〜翌4:00 の1日で始め、開いたときの動きはない。上の行の名前は「この日」
    var isPastDay = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    #if DEBUG
    @Environment(\.raceStartsWholeDay) private var startsWholeDay
    @Environment(\.raceStartsReplay) private var startsReplay
    #endif
    /// 1日全体を出しているか
    @State private var showsWholeDay = false
    /// 3時間の窓の左端（横にずらすと動く）
    @State private var scrollStart: Date?
    /// 動き（開いたとき・［▶］）の進み（0〜1）。動いている間だけ `motion` があり、そのときの「今」の形を持つ
    @State private var motionProgress = 1.0
    @State private var motion: Motion?
    /// ［▶］で流している途中（止めるときに取り消す）
    @State private var replayTask: Task<Void, Never>?
    /// 指を離したあとの滑り（慣性）。触る・裏返すなどで取り消す
    @State private var glideTask: Task<Void, Never>?
    /// 起動したとき・ほかのアプリから戻ったときから、もう動いたか
    @State private var introPlayed = false
    /// 指で横にずらし始めた場所と、そのときの3時間の左端。始めた場所が変わったら新しいずらしとして取り直す
    /// （縦のスクロールに取られるなどで終わりが来なくても、次のずらしが前の位置から飛ばないように）
    @State private var dragAnchor: (location: CGPoint, start: Date)?
    @State private var curves: [RaceCurve] = []

    private var layout: RaceChartLayout {
        RaceChartLayout(dayStart: snapshot.dayStart, dayEnd: snapshot.dayEnd, now: snapshot.now)
    }

    var body: some View {
        VStack(spacing: 8) {
            header
            AnimatedProgress(progress: motionProgress) { progress in
                chart(motion: motion, progress: progress)
            }
            legend
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color(uiColor: .secondarySystemBackground)))
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("raceChart")
        .onAppear(perform: refreshCurves)
        .onChange(of: snapshot.now) { refreshCurves() }
        .onChange(of: opponent) { refreshCurves() }
        // 開いたまま朝4:00をまたいだら、新しい日の今のまわりの3時間に戻す
        .onChange(of: snapshot.dayStart) { reset() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            introPlayed = false
            stopReplay()
            stopGlide()
        }
        .task(id: isShowing) {
            if isShowing {
                await show()
            } else {
                reset()
            }
        }
    }

    private func refreshCurves() {
        curves = snapshot.raceCurves(opponent: opponent)
    }

    // MARK: - 上の行と下の行

    /// 今の値と差（グラフの上）。差は右に大きめに
    private var header: some View {
        let theirs = opponent.flatMap { snapshot.opponentPoints($0, at: snapshot.now) }
        return HStack(spacing: 10) {
            valueLabel(isPastDay ? Text("この日") : Text("今日"), Self.pointText(snapshot.points), Theme.focus)
            if let opponent, let theirs, let gap = RaceChartLayout.gap(mine: snapshot.points, theirs: theirs) {
                valueLabel(Text(verbatim: opponent.shortName), Self.pointText(theirs), Theme.ghost)
                Spacer(minLength: 0)
                Text(RaceChartLayout.gapText(gap))
                    .font(.subheadline.bold().monospacedDigit())
                    .foregroundStyle(RaceChartLayout.isAhead(gap) ? Theme.lead : Theme.behind)
                    .accessibilityIdentifier("raceGap")
            } else {
                Spacer(minLength: 0)
            }
        }
        .font(.footnote)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("raceSummary")
    }

    private func valueLabel(_ title: Text, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            title.foregroundStyle(.secondary)
            Text(value).fontWeight(.semibold).monospacedDigit()
        }
    }

    static func pointText(_ points: Double) -> String {
        "\(points.formatted(.number.precision(.fractionLength(1))))pt"
    }

    /// 3時間と1日の切り替え（下の行の右のボタン1つ）
    private var zoomButton: some View {
        Button(action: toggleWholeDay) {
            Label(showsWholeDay ? "3時間" : "1日",
                  systemImage: showsWholeDay ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                .font(.caption.bold())
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .disabled(motion != nil)
        .accessibilityLabel(showsWholeDay ? "3時間に戻す" : "1日全体を見る")
        .accessibilityIdentifier("raceZoomButton")
    }

    /// ［▶］1日を流す・［■］止める（下の行の［1日］の左）
    private var replayButton: some View {
        let replaying = motion?.kind == .replay
        return Button {
            if replaying { stopReplay() } else { startReplay() }
        } label: {
            Image(systemName: replaying ? "stop.fill" : "play.fill")
                .font(.caption.bold())
                .frame(minWidth: 14)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
        }
        .buttonStyle(.plain)
        // 4:00 ちょうど（まだ線がない）と、開いたときの動きの途中は押せない
        .disabled(!layout.playsIntro || motion?.kind == .opening)
        .accessibilityLabel(replaying ? Text("止める") : Text("1日を流す"))
        .accessibilityIdentifier("raceReplayButton")
    }

    private func toggleWholeDay() {
        stopGlide()
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) {
            showsWholeDay.toggle()
            if !showsWholeDay { scrollStart = layout.homeWindow.lowerBound }
        }
    }

    // MARK: - グラフ

    private func chart(motion: Motion?, progress: Double) -> some View {
        let intro = motion?.frame(progress)
        let pieces = pieces(intro: intro)
        let range = visibleRange(intro: intro)
        // 開いたときの動きは、縦の目盛りを止まったときと同じにしておく（線が伸びても目盛りは動かない）
        let scalePieces = motion?.kind == .opening ? self.pieces(intro: nil) : pieces
        let values = scalePieces.flatMap(\.values).filter { range.contains($0.date) }.map(\.value)
        // 見えている範囲の点と、その外の1つずつだけ描く（線が端まで届くように。外にはみ出た分は切り取る）
        let margin = HomeSnapshot.curveStep
        let shown = pieces.map { piece in
            var piece = piece
            piece.values = piece.values.filter {
                $0.date >= range.lowerBound.addingTimeInterval(-margin) && $0.date <= range.upperBound.addingTimeInterval(margin)
            }
            return piece
        }
        return Chart {
            ForEach(shown, id: \.name) { piece in
                ForEach(piece.values, id: \.date) { value in
                    LineMark(x: .value("時刻", value.date), y: .value("量", value.value),
                             series: .value("線", piece.name))
                        .foregroundStyle(color(piece.kind))
                        .lineStyle(piece.kind.isOpponent
                                   ? StrokeStyle(lineWidth: 2, dash: [4, 3])
                                   : StrokeStyle(lineWidth: 3, lineCap: .round))
                        .opacity(piece.isFuture ? 0.3 : 1)
                        .interpolationMethod(.linear)
                }
            }
            // 区間のカテゴリのアイコンと開けた鍵（自分の線の上、GHO-15）。動いている間は出さない
            if intro == nil, let mine = pieces.first(where: { !$0.kind.isOpponent }) {
                ForEach(markers(on: mine, in: range), id: \.id) { marker in
                    PointMark(x: .value("時刻", marker.date), y: .value("量", marker.value))
                        .symbol {
                            Image(systemName: marker.symbol)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(marker.isUnlock ? Theme.ghost : Theme.focus)
                                .padding(3)
                                .background(Circle().fill(Color(.systemBackground).opacity(0.9)))
                                .offset(y: -14)
                        }
                }
            }
            // ラップの旗：2時間の区切りと中間地点（GHO-06）
            if intro == nil {
                ForEach(flags(in: range), id: \.date) { flag in
                    RuleMark(x: .value("区切り", flag.date))
                        .foregroundStyle(Color.secondary.opacity(0.25))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                        .annotation(position: .top, alignment: .center, spacing: 2) {
                            HStack(spacing: 2) {
                                Image(systemName: "flag.fill").font(.system(size: 9))
                                if let text = flag.text { Text(text).font(.caption2.monospacedDigit()) }
                            }
                            .foregroundStyle(flag.color)
                            .dynamicTypeSize(...DynamicTypeSize.large)
                        }
                }
            }
            // 線の先に2人（今いる場所）。自分は走る人、相手はおばけ（表の円と同じ）
            ForEach(pieces.filter { !$0.isFuture }, id: \.name) { piece in
                if let last = piece.values.last, range.contains(last.date) {
                    PointMark(x: .value("時刻", last.date), y: .value("量", last.value))
                        .symbol {
                            if piece.kind.isOpponent {
                                GhostShape().fill(Theme.ghost).frame(width: 11, height: 13)
                            } else {
                                Image(systemName: "figure.run").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.focus)
                            }
                        }
                }
            }
            // 過ぎた日は「今」がないので線を引かない
            if snapshot.now > snapshot.dayStart, !isPastDay {
                RuleMark(x: .value("今", min(intro?.head ?? snapshot.now, motion?.now ?? snapshot.now)))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartXScale(domain: range)
        .chartYScale(domain: RaceChartLayout.yDomain(values: values, wholeDay: showsWholeDay && intro == nil))
        .chartPlotStyle { $0.clipped() }
        // 横にずらすのは Charts のスクロールを使わず、指の動きで範囲を動かす。
        // Charts のスクロールは3時間（中身が8画面ぶん）だと画面の部品の読み取りが止まり、切り替えの途中で落ちたため（2026-10-04）
        .chartOverlay { proxy in
            Rectangle().fill(.clear).contentShape(Rectangle())
                .gesture(pan(plotWidth: proxy.plotSize.width))
                // 滑っている途中に押したら止めるだけ（裏返さない）
                .gesture(glideTask == nil ? nil : TapGesture().onEnded { stopGlide() })
                .allowsHitTesting(intro == nil && !showsWholeDay)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: axisStepHours(range))) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted))))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(number.formatted(.number.precision(.fractionLength(0...1))))
                    }
                }
            }
        }
        .chartLegend(.hidden)
        // 線の先は1コマずつ作るので、グラフ自身の出入りのアニメーションは止める（新しい点が遅れて出るのを防ぐ）
        .transaction { if intro != nil { $0.animation = nil } }
        .frame(minHeight: 150)
        // 点（5分おき×2〜3本）を1つずつ読ませると数百になり VoiceOver でたどれないので、グラフは1つにまとめ、
        // 数字と差は上の行で読む（2026-10-04、Claude 補足）
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isPastDay ? Text("この日たまったポイントのグラフ") : Text("今日たまったポイントのグラフ"))
        .accessibilityValue(Self.rangeText(range))
    }

    /// 下の行：線の見分け方と［1日］。入りきるときだけ「横にずらせます」も出す
    private var legend: some View {
        HStack(spacing: 12) {
            legendItem(dashed: false, Text("自分"))
            if let opponent, snapshot.opponentPoints(opponent, at: snapshot.now) != nil {
                legendItem(dashed: true, Text(verbatim: opponent.pickerName))
            }
            Spacer(minLength: 0)
            if !showsWholeDay && motion == nil {
                ViewThatFits {
                    Label("横にずらせます", systemImage: "arrow.left.and.right")
                    Image(systemName: "arrow.left.and.right")
                }
                .foregroundStyle(.tertiary)
            }
            replayButton
            zoomButton
        }
        .font(.caption2)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    private func legendItem(dashed: Bool, _ title: Text) -> some View {
        HStack(spacing: 4) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 4))
                path.addLine(to: CGPoint(x: 16, y: 4))
            }
            .stroke(Color.secondary, style: StrokeStyle(lineWidth: 2, dash: dashed ? [3, 2] : []))
            .frame(width: 16, height: 8)
            title.foregroundStyle(.secondary)
        }
    }

    private func color(_ kind: RaceCurve.Kind) -> Color {
        switch kind {
        case .minePoints: Theme.focus
        case .opponentPoints: Theme.ghost
        }
    }

    // MARK: - 見えている範囲

    /// 指で横にずらす。10pt 動くまでは裏返すタップとして扱う
    private func pan(plotWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                // 触ったら滑りは止める
                stopGlide()
                // 縦の動きのほうが大きいときはずらさない（ホームの縦スクロールのため）
                guard abs(value.translation.width) >= abs(value.translation.height) else {
                    dragAnchor = nil
                    return
                }
                let anchor = dragAnchor.flatMap { $0.location == value.startLocation ? $0 : nil }
                    ?? (location: value.startLocation, start: scrollStart ?? layout.homeWindow.lowerBound)
                dragAnchor = anchor
                scrollStart = layout.panned(from: anchor.start, by: value.translation.width, plotWidth: plotWidth)
            }
            .onEnded { value in
                // このずらしで横に動かしていたときだけ滑らせる（前のずらしの残りでは滑らせない）
                let wasPanning = dragAnchor?.location == value.startLocation
                dragAnchor = nil
                guard wasPanning else { return }
                glide(velocity: value.velocity.width, plotWidth: plotWidth)
            }
    }

    /// 指を離したあと、はじいた勢いで滑ってだんだん止まる（2026-10-05）。端に着くか、残りがわずかになったら終わり
    private func glide(velocity: CGFloat, plotWidth: CGFloat) {
        stopGlide()
        guard !RaceChartLayout.glideIsOver(velocity: velocity, elapsed: 0) else { return }
        let layout = self.layout
        let start = scrollStart ?? layout.homeWindow.lowerBound
        glideTask = Task {
            let clock = ContinuousClock()
            let began = clock.now
            while !Task.isCancelled {
                let elapsed = began.duration(to: clock.now) / .seconds(1)
                let next = layout.glided(from: start, velocity: velocity, plotWidth: plotWidth, elapsed: elapsed)
                let stuck = next == scrollStart && elapsed > 0
                scrollStart = next
                if stuck || RaceChartLayout.glideIsOver(velocity: velocity, elapsed: elapsed) { break }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func stopGlide() {
        glideTask?.cancel()
        glideTask = nil
    }

    /// 見えている時間帯（例「13:20〜16:20」）。VoiceOver で読む
    static func rangeText(_ range: ClosedRange<Date>) -> String {
        "\(range.lowerBound.formatted(date: .omitted, time: .shortened))〜\(range.upperBound.formatted(date: .omitted, time: .shortened))"
    }

    /// 今見えている範囲（縦の目盛りをここに合わせる）
    private func visibleRange(intro: RaceChartLayout.Frame?) -> ClosedRange<Date> {
        intro?.domain ?? layout.visibleRange(wholeDay: showsWholeDay, scrollStart: scrollStart)
    }

    private func axisStepHours(_ range: ClosedRange<Date>) -> Int {
        let hours = range.upperBound.timeIntervalSince(range.lowerBound) / RaceChartLayout.hour
        if hours > 12 { return 4 }
        if hours > 4 { return 2 }
        return 1
    }

    // MARK: - 印と旗（GHO-06・15）

    private struct Marker {
        var id: String
        var date: Date
        var value: Double
        var symbol: String
        var isUnlock: Bool
    }

    private struct Flag {
        var date: Date
        var text: String?
        var color: Color
    }

    /// 自分の線の上のアイコン（タイマーを始めた所）と開けた鍵。線の値は近い点から取る
    private func markers(on mine: Piece, in range: ClosedRange<Date>) -> [Marker] {
        func value(at date: Date) -> Double? {
            mine.values.last(where: { $0.date <= date })?.value ?? mine.values.first?.value
        }
        let icons = snapshot.sessionIcons.filter { range.contains($0.start) && $0.start <= snapshot.now }.compactMap { icon in
            value(at: icon.start).map { Marker(id: "i\($0)\(icon.start)", date: icon.start, value: $0, symbol: icon.symbol, isUnlock: false) }
        }
        let unlocks = (snapshot.detox?.unlockStarts ?? []).filter { range.contains($0) && $0 <= snapshot.now }.compactMap { date in
            value(at: date).map { Marker(id: "u\(date)", date: date, value: $0, symbol: "lock.open.fill", isUnlock: true) }
        }
        return icons + unlocks
    }

    /// 2時間の区切り（そこまでの区間の差）と中間地点。見えている範囲だけ。3時間の窓では数字も出す
    private func flags(in range: ClosedRange<Date>) -> [Flag] {
        guard let opponent else { return [] }
        let laps = snapshot.laps(opponent).filter { !$0.isCurrent }
        let showsText = !showsWholeDay
        var result = laps.filter { range.contains($0.interval.end) }.map { lap in
            Flag(date: lap.interval.end, text: showsText && !lap.isEmpty ? DurationFormat.signed(lap.diff) : nil,
                 color: lap.isEmpty ? .secondary : Theme.diffColor(lap.diff))
        }
        if let half = snapshot.halfwayTime(opponent), range.contains(half) {
            result.append(Flag(date: half, text: showsText ? "中間" : nil, color: Theme.focus))
        }
        return result
    }

    // MARK: - 線のデータ

    private struct Piece {
        var name: String
        var kind: RaceCurve.Kind
        var values: [RaceCurve.Value]
        var isFuture: Bool
    }

    /// 相手の線は、今までと今より先（薄く）に分ける。動いている間は線の先まで描き、相手の先は出さない
    private func pieces(intro: RaceChartLayout.Frame?) -> [Piece] {
        let now = snapshot.now
        return curves.flatMap { curve -> [Piece] in
            let name = "\(curve.kind)"
            if let intro {
                // 動いている間は見えている範囲の点だけ描く（毎コマ描き直すので軽くする）
                let values = RaceChartLayout.cut(curve.values, at: min(intro.head, now))
                    .filter { $0.date >= intro.domain.lowerBound.addingTimeInterval(-HomeSnapshot.curveStep) }
                return [Piece(name: name, kind: curve.kind, values: values, isFuture: false)]
            }
            guard curve.kind.isOpponent else { return [Piece(name: name, kind: curve.kind, values: curve.values, isFuture: false)] }
            return [
                Piece(name: name, kind: curve.kind, values: curve.values.filter { $0.date <= now }, isFuture: false),
                Piece(name: name + "-future", kind: curve.kind, values: curve.values.filter { $0.date >= now }, isFuture: true),
            ]
        }
        .filter { !$0.values.isEmpty }
    }

    // MARK: - 開いたときの動き

    /// 裏が見えたとき。起動・ほかのアプリから戻ってから最初の1回だけ動く
    private func show() async {
        reset()
        #if DEBUG
        if startsWholeDay { showsWholeDay = true }
        if startsReplay {
            try? await Task.sleep(for: .seconds(RaceChartLayout.flipWaitSeconds))
            if !Task.isCancelled { startReplay() }
            return
        }
        #endif
        guard layout.playsIntro(alreadyPlayed: introPlayed, reduceMotion: reduceMotion, wholeDay: showsWholeDay) else { return }
        // 動いている間に「今」が進んでも、始めたときの今まで伸ばす
        let opening = Motion(kind: .opening, layout: layout)
        motion = opening
        motionProgress = 0
        // 裏返る途中から見え始めるので、回りきるのを少し待つ
        try? await Task.sleep(for: .seconds(RaceChartLayout.flipWaitSeconds))
        guard !Task.isCancelled else { return }
        let seconds = opening.layout.introSeconds
        withAnimation(.linear(duration: seconds)) {
            motionProgress = 1
        }
        try? await Task.sleep(for: .seconds(seconds))
        guard !Task.isCancelled, motion?.kind == .opening else { return }
        // 最後まで動いたときだけ「最初の1回」を済ませたことにする（途中で表に戻したら次も動く）
        introPlayed = true
        scrollStart = layout.homeWindow.lowerBound
        motion = nil
    }

    /// ［▶］：4:00 から押したときの今までを、3時間の幅で追いかけて流す（2026-10-05）。視差効果を減らす設定でも、自分で押したときは流す
    private func startReplay() {
        stopGlide()
        replayTask?.cancel()
        let replay = Motion(kind: .replay, layout: layout)
        showsWholeDay = false
        dragAnchor = nil
        motion = replay
        motionProgress = 0
        replayTask = Task {
            // 0 にした進みが描かれてから動かし始める
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            let seconds = replay.layout.replaySeconds
            withAnimation(.linear(duration: seconds)) {
                motionProgress = 1
            }
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            stopReplay()
        }
    }

    /// 流すのをやめて今のまわりの3時間に戻す（［■］・最後まで流れたとき・表に戻す・ほかのアプリへ行く）
    private func stopReplay() {
        replayTask?.cancel()
        replayTask = nil
        guard motion?.kind == .replay else { return }
        motion = nil
        motionProgress = 1
        scrollStart = layout.homeWindow.lowerBound
    }

    /// 裏返し直すと、［1日］やずらした位置は戻して今のまわりの3時間から。動いている・滑っている途中なら止める
    private func reset() {
        stopGlide()
        replayTask?.cancel()
        replayTask = nil
        dragAnchor = nil
        showsWholeDay = isPastDay
        scrollStart = layout.homeWindow.lowerBound
        motion = nil
        motionProgress = 1
    }
}

/// 動いている途中の種類と、始めたときの「今」の形（動いている間に今が進んでも、始めたときの今まで動かす）
private struct Motion {
    enum Kind { case opening, replay }

    var kind: Kind
    var layout: RaceChartLayout

    var now: Date { layout.now }

    func frame(_ progress: Double) -> RaceChartLayout.Frame {
        switch kind {
        case .opening: layout.introFrame(progress)
        case .replay: layout.replayFrame(progress)
        }
    }
}

/// 進み（0〜1）をアニメーションで1コマずつ渡す（線の先と見えている範囲をコマごとに作るため）
private struct AnimatedProgress<Content: View>: View, @MainActor Animatable {
    var progress: Double
    let content: (Double) -> Content

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View { content(progress) }
}
