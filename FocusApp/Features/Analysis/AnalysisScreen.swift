import Charts
import SwiftUI

#if DEBUG
extension EnvironmentValues {
    /// 見本の撮影用：自己ベストをこの期間で始める（`-openBest`）
    @Entry var bestStartsPeriod: BestPeriod? = nil
    /// 見本の撮影用：ポイントの推移を何期間前で始めるか（`-pointsPage`）
    @Entry var pointsStartsPage = 0
    /// 見本の撮影用：ラップ表の相手（`-lapTarget`）
    @Entry var lapStartsTarget: LapTarget? = nil
    /// 見本の撮影用：自己ベストを送る先（`-bestScroll`）
    @Entry var bestStartsScroll: String? = nil
}
#endif

/// 分析のタブで進む先
enum AnalysisRoute: Hashable {
    case points
    case timeline
    /// その日のグラフ（その日の 4:00。開いたまま4:00をまたいでも同じ日を指すよう日付で持つ）
    case day(Date)
    /// 自己ベストの画面（ベストの行・ベスト10）から開いたその日のグラフ。相手は今日（ANA-05、2026-10-11）
    case bestDay(Date)
    /// 自己ベスト（ANA-06）
    case best
    /// 時間帯の地図（ANA-07）
    case timeMap
}

/// 分析のタブ（NAV-01・ANA-03、2026-10-05 オーナー決定でタイムラインのタブを置き換え）。項目の一覧から進む
struct AnalysisScreen: View {
    @Bindable var model: AppModel
    @Binding var path: [AnalysisRoute]
    /// 昨日までの7日の平均（開いたとき・1分ごとの読み直しで数え直す。描き直すたびには数えない）
    @State private var average: Double?
    /// 時間帯の地図（行の下の「よく集中するのは〜」に使う）
    @State private var map: TimeMap?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                NavigationLink(value: AnalysisRoute.points) {
                    row("ポイントの推移", systemImage: "chart.xyaxis.line", detail: averageText)
                }
                .accessibilityIdentifier("analysisPointsRow")
                NavigationLink(value: AnalysisRoute.timeline) {
                    row("タイムライン", systemImage: "calendar.day.timeline.left",
                        detail: Text("今日の集中 \(DurationFormat.japanese(model.snapshot.focusSeconds))"))
                }
                .accessibilityIdentifier("analysisTimelineRow")
                Button {
                    model.showsReview = true
                } label: {
                    row("今日の振り返り", systemImage: "moon.stars", detail: Text("先週の自分との勝ち負けと、朝の計画とのズレ"))
                }
                .foregroundStyle(.primary)
                .accessibilityIdentifier("analysisReviewRow")
                NavigationLink(value: AnalysisRoute.best) {
                    row("自己ベスト", systemImage: "trophy", detail: model.snapshot.personalBest.map {
                        Text("集中 \(DurationFormat.japanese($0.focusSeconds))（\(TimeMapView.dayText($0.focusDay))）")
                    })
                }
                .accessibilityIdentifier("analysisBestRow")
                NavigationLink(value: AnalysisRoute.timeMap) {
                    row("時間帯の地図", systemImage: "square.grid.3x3.fill", detail: map.flatMap(TimeMapView.peakText).map { Text($0) })
                }
                .accessibilityIdentifier("analysisTimeMapRow")
            }
            .navigationTitle("分析")
            .task(id: model.snapshot.now) {
                average = PointsHistory.average(model.pointsHistory(days: 8))
                map = model.timeMap()
            }
            .navigationDestination(for: AnalysisRoute.self) { route in
                switch route {
                case .points: PointsHistoryView(model: model)
                case .timeline: TimelineScreen(model: model)
                case .day(let dayStart): DayGraphView(model: model, dayStart: dayStart)
                case .bestDay(let dayStart): DayGraphView(model: model, dayStart: dayStart, versusToday: true)
                case .best: PersonalBestView(model: model)
                case .timeMap: TimeMapView(map: map ?? model.timeMap())
                }
            }
        }
        .tint(Theme.focus)
    }

    /// 昨日までの7日の平均（今日は途中なので除く）
    private var averageText: Text? {
        average.map {
            Text("7日の平均 \(RaceChart.pointText($0))")
        }
    }

    private func row(_ title: LocalizedStringKey, systemImage: String, detail: Text?) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                if let detail { detail.font(.footnote).foregroundStyle(.secondary) }
            }
        } icon: {
            Image(systemName: systemImage).foregroundStyle(Theme.focus)
        }
        .padding(.vertical, 4)
        // 行の中で折り返しすぎないよう上限を付ける（タイムラインの日付の帯と同じ）
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }
}

/// ポイントの推移（ANA-04）：日ごとの1日の合計と、先週の同じ曜日
struct PointsHistoryView: View {
    @Bindable var model: AppModel
    @State private var days = 7
    /// 何期間前か（0＝今日が右の端。‹ で1つ増え、› で減る、ANA-04）
    @State private var page = 0
    /// 表示している期間の数字。期間を変えたとき・1分ごとの読み直しで数え直す（30日分を描き直すたびに数えない）
    @State private var history: [DayPoints] = []
    @State private var canGoBack = false
    #if DEBUG
    @Environment(\.pointsStartsPage) private var startsPage
    #endif

    var body: some View {
        List {
            Section {
                Picker("期間", selection: $days) {
                    Text("7日").tag(7)
                    Text("30日").tag(30)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("pointsRangePicker")
                .onChange(of: days) { page = 0 }
                pager
                // グラフの目盛りと線の見分け方は、大きな文字だと重なるので裏のグラフと同じ上限にする
                Group {
                    chart(history)
                        .frame(height: 220)
                        .padding(.vertical, 8)
                    legend
                }
                .dynamicTypeSize(...DynamicTypeSize.xLarge)
            }
            Section("日ごと") {
                ForEach(history.reversed()) { day in
                    NavigationLink(value: AnalysisRoute.day(day.dayStart)) {
                        dayRow(day)
                    }
                    .disabled(day.points == nil)
                }
            }
        }
        .navigationTitle("ポイントの推移")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: Refresh(days: days, page: page, now: model.snapshot.now)) {
            history = model.pointsHistory(days: days, page: page)
            canGoBack = model.canGoBack(days: days, page: page)
        }
        #if DEBUG
        .onAppear { if startsPage > 0 { page = startsPage } }
        #endif
    }

    private struct Refresh: Equatable {
        var days: Int
        var page: Int
        var now: Date
    }

    /// 「‹ 9月23日〜9月29日 ›」。‹ で1期間前へ、› で新しいほうへ（2026-10-06 オーナー決定）
    private var pager: some View {
        HStack {
            Button { page += 1 } label: {
                Image(systemName: "chevron.left").frame(width: 44, height: 32)
            }
            .disabled(!canGoBack)
            .accessibilityLabel(Text("前の期間"))
            .accessibilityIdentifier("pointsPreviousPage")
            Spacer()
            if let first = history.first, let last = history.last {
                Text("\(TimeMapView.shortDayText(first.dayStart))〜\(TimeMapView.shortDayText(last.dayStart))")
                    .font(.subheadline.monospacedDigit())
                    .accessibilityIdentifier("pointsPageRange")
            }
            Spacer()
            Button { page -= 1 } label: {
                Image(systemName: "chevron.right").frame(width: 44, height: 32)
            }
            .disabled(page == 0)
            .accessibilityLabel(Text("次の期間"))
            .accessibilityIdentifier("pointsNextPage")
        }
        .buttonStyle(.borderless)
    }

    /// 自分（実線）と先週の同じ曜日（点線）の2本（2026-10-05 オーナー決定、棒と比べて選んだ）。
    /// 今日はまだ途中なので、前の日から今日への線と今日の点は薄くする（Claude 補足）
    @ChartContentBuilder
    private func marks(_ history: [DayPoints]) -> some ChartContent {
        let past = history.filter { !$0.isToday }
        let today = history.last { $0.isToday }
        let yesterday = past.last
        ForEach(past) { day in
            if let points = day.points {
                LineMark(x: .value("日", day.dayStart, unit: .day), y: .value("ポイント", points), series: .value("線", "自分"))
                    .foregroundStyle(Theme.focus)
                    .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
                PointMark(x: .value("日", day.dayStart, unit: .day), y: .value("ポイント", points))
                    .foregroundStyle(Theme.focus)
            }
            if let lastWeek = day.lastWeek {
                LineMark(x: .value("日", day.dayStart, unit: .day), y: .value("先週", lastWeek), series: .value("線", "先週"))
                    .foregroundStyle(Theme.ghost)
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
            }
        }
        if let today {
            ForEach([yesterday, today].compactMap { $0 }) { day in
                if let points = day.points {
                    LineMark(x: .value("日", day.dayStart, unit: .day), y: .value("ポイント", points), series: .value("線", "自分・今日"))
                        .foregroundStyle(Theme.focus.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
                }
                if let lastWeek = day.lastWeek {
                    LineMark(x: .value("日", day.dayStart, unit: .day), y: .value("先週", lastWeek), series: .value("線", "先週・今日"))
                        .foregroundStyle(Theme.ghost.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
                }
            }
            if let points = today.points {
                PointMark(x: .value("日", today.dayStart, unit: .day), y: .value("ポイント", points))
                    .foregroundStyle(Theme.focus.opacity(0.35))
            }
        }
    }

    private func chart(_ history: [DayPoints]) -> some View {
        Chart {
            marks(history)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: days > 7 ? 7 : 1)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date.formatted(.dateTime.month(.defaultDigits).day()))
                    }
                }
            }
        }
        // 縦は裏のグラフと同じく、見えている値に合わせる（0から始めないので差が見える）
        .chartYScale(domain: RaceChartLayout.yDomain(values: history.flatMap { [$0.points, $0.lastWeek].compactMap { $0 } },
                                                     wholeDay: false))
        .chartLegend(.hidden)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("日ごとのポイントのグラフ"))
    }

    private var legend: some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 1).fill(Theme.focus).frame(width: 14, height: 3)
                Text("自分")
            }
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 1).fill(Theme.ghost).frame(width: 14, height: 3)
                Text("先週の同じ曜日")
            }
            Spacer(minLength: 0)
            if page == 0 { Text("今日は今まで（薄い色）") }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    /// 日付と、その日の合計・先週との差。大きな文字で入りきらなければ縦に並べる
    private func dayRow(_ day: DayPoints) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                dayTitle(day)
                Spacer()
                dayValues(day, alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 4) {
                dayTitle(day)
                dayValues(day, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func dayTitle(_ day: DayPoints) -> some View {
        Text(day.dayStart.formatted(.dateTime.month().day().weekday(.abbreviated).locale(Locale(identifier: "ja_JP")))
             + (day.isToday ? "（今日）" : ""))
    }

    @ViewBuilder
    private func dayValues(_ day: DayPoints, alignment: HorizontalAlignment) -> some View {
        if let points = day.points {
            VStack(alignment: alignment, spacing: 2) {
                Text(RaceChart.pointText(points)).monospacedDigit().fontWeight(.semibold)
                if let gap = day.gap {
                    Text("先週より \(RaceChartLayout.signedPoints(gap))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(RaceChartLayout.isAhead(gap) ? Theme.lead : Theme.behind)
                }
            }
        } else {
            Text("記録なし").foregroundStyle(.secondary)
        }
    }
}

/// その日のグラフ（ANA-05）：ホームの円の裏と同じグラフ。過ぎた日は 4:00〜翌4:00 の1日で始める。
/// 自己ベストから開いたとき（`versusToday`）は相手を今日にする（2026-10-11）。1分ごとの読み直しで今日を数え直し、
/// 4:00 を過ぎれば新しい今日と比べる
struct DayGraphView: View {
    @Bindable var model: AppModel
    let dayStart: Date
    var versusToday = false

    var body: some View {
        // 1分ごとの読み直し（model.snapshot.now）で描き直す
        let _ = model.snapshot.now
        Group {
            if let snapshot = model.daySnapshot(of: dayStart, versusToday: versusToday) {
                let rival: RaceRival = snapshot.todayRival != nil ? .today : .opponent(model.opponent)
                // 過ぎた日（翌4:00 まで数えた日）は1日で始める。今日はホームの裏と同じ。
                // ホームの裏と同じく、上の約6割がグラフ、下の残りがラップの一覧（その中でスクロール、2026-10-12）
                RaceChart(snapshot: snapshot, rival: rival, isPastDay: snapshot.now >= snapshot.dayEnd, showsLaps: true)
                    .padding(16)
                    .navigationTitle(Text(snapshot.dayStart.formatted(
                        .dateTime.month().day().weekday(.abbreviated).locale(Locale(identifier: "ja_JP")))))
            } else {
                ContentUnavailableView("記録を読めませんでした", systemImage: "exclamationmark.triangle")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 自己ベスト（ANA-06）：期間（全期間・今月・今週）の一番多い1日の集中した時間とポイント。押すとその日のグラフ。
/// 下に理論ベスト（ANA-11）、今日と相手（ベストの日・平均・区間ベスト）の比べ（今日の行と2時間ごとのラップ表）、ベスト10（ANA-09）
struct PersonalBestView: View {
    @Bindable var model: AppModel
    @State private var period: BestPeriod = .all
    /// ラップ表の相手。期間を変えても、ほかのタブへ行って戻ってもそのまま。開き直すとベストの日
    @State private var target: LapTarget = .bestDay
    /// 期間ごとのベスト。開いたとき・1分ごとの読み直しで数え直す（期間を切り替えるたびには数えない）
    @State private var bests: [BestPeriod: PeriodBest]?
    @State private var comparison: BestComparison?
    @State private var theoretical: Double?
    @State private var top: [DayPoints] = []
    #if DEBUG
    @Environment(\.bestStartsPeriod) private var startsPeriod
    @Environment(\.lapStartsTarget) private var startsTarget
    @Environment(\.bestStartsScroll) private var startsScroll
    #endif

    var body: some View {
        ScrollViewReader { proxy in
            list
            #if DEBUG
                .task(id: comparison != nil && !top.isEmpty) {
                    guard comparison != nil, let startsScroll else { return }
                    proxy.scrollTo(startsScroll == "top10" ? "bestTop10" : startsScroll == "table" ? "bestLapTable" : "bestTheoretical",
                                   anchor: .top)
                }
            #endif
        }
        .navigationTitle("自己ベスト")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: model.snapshot.now) { bests = model.periodBests() }
        // 期間の材料（理論ベスト・ベスト10）は期間が変わったとき・1分ごとの読み直しで。相手を切り替えたときはラップ表だけ
        .task(id: Refresh(day: bests?[period]?.pointsDay, now: model.snapshot.now, period: period)) {
            let has = bests?[period] != nil
            theoretical = has ? model.theoreticalBest(period: period) : nil
            top = has ? model.topDays(period: period) : []
        }
        .task(id: Refresh(day: bests?[period]?.pointsDay, now: model.snapshot.now, period: period, target: target)) {
            comparison = bests?[period] != nil ? model.lapComparison(target: target, period: period) : nil
        }
        #if DEBUG
        .onAppear {
            if let startsPeriod { period = startsPeriod }
            if let startsTarget { target = startsTarget }
        }
        #endif
    }

    private var list: some View {
        List {
            Section {
                Picker("期間", selection: $period) {
                    Text("全期間").tag(BestPeriod.all)
                    // 今週（今月）に記録のある日がない間は先週（先月）の日で出す（2026-10-11）
                    (isFallback(.month) ? Text("先月") : Text("今月")).tag(BestPeriod.month)
                    (isFallback(.week) ? Text("先週") : Text("今週")).tag(BestPeriod.week)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("bestPeriodPicker")
                if isFallback(period) {
                    Text(period == .week ? "今週はまだ記録がないので、先週と比べています" : "今月はまだ記録がないので、先月と比べています")
                        .font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("bestFallbackNote")
                }
                switch bests.map({ $0[period] }) {
                case .none:
                    ProgressView()
                case .some(.none):
                    Text(emptyText).foregroundStyle(.secondary)
                case .some(.some(let best)):
                    NavigationLink(value: AnalysisRoute.bestDay(best.pointsDay)) {
                        bestRow("ポイント", value: RaceChart.pointText(best.points), day: best.pointsDay)
                    }
                    .accessibilityIdentifier("bestPointsRow")
                    if let focus = best.focus {
                        NavigationLink(value: AnalysisRoute.bestDay(focus.focusDay)) {
                            bestRow("集中した時間", value: DurationFormat.japanese(focus.focusSeconds), day: focus.focusDay)
                        }
                    }
                    if let theoretical {
                        LabeledContent("理論ベスト", value: RaceChart.pointText(theoretical))
                            .font(.subheadline.monospacedDigit())
                            .accessibilityIdentifier("theoreticalBestRow")
                            .id("bestTheoretical")
                    }
                }
            }
            if let comparison {
                Section {
                    targetPicker
                    todayRow(comparison)
                } header: {
                    Text("今日と比べる")
                }
                if !comparison.rows.isEmpty {
                    Section {
                        BestLapTable(rows: comparison.rows, theirsName: theirsName(comparison))
                            .id("bestLapTable")
                    } header: {
                        Text("ラップ（2時間ごと・pt）")
                    } footer: {
                        Text("今日が\(plainName)を上回った数字は赤。区間ベストを超えた区間に★。今の区間は\(plainName)も同じ時刻まで")
                    }
                }
            }
            if !top.isEmpty {
                Section {
                    ForEach(Array(top.enumerated()), id: \.element.dayStart) { index, day in
                        NavigationLink(value: AnalysisRoute.bestDay(day.dayStart)) {
                            topRow(rank: index + 1, day: day)
                        }
                        .id(index == 0 ? "bestTop10" : "bestTop\(index + 1)")
                        .accessibilityIdentifier("bestTopDay")
                    }
                } header: {
                    Text("ベスト10")
                }
            }
        }
    }

    private struct Refresh: Equatable {
        var day: Date?
        var now: Date
        var period: BestPeriod
        var target: LapTarget?
    }

    /// 今週（今月）に記録のある日がないので、先週（先月）に代えているか
    private func isFallback(_ period: BestPeriod) -> Bool {
        bests?[period]?.isFallback == true
    }

    private var emptyText: String {
        switch period {
        case .all: "まだ記録がありません"
        case .month: "今月はまだ記録なし（今日が終わると入ります）"
        case .week: "今週はまだ記録なし（今日が終わると入ります）"
        }
    }

    /// 比べる相手：「今日と比べる」の一番上の［ベストの日｜平均｜区間ベスト］（2026-10-07 オーナーが画面の案から選んだ）
    private var targetPicker: some View {
        Picker("比べる相手", selection: $target) {
            Text("ベストの日").tag(LapTarget.bestDay)
            Text("平均").tag(LapTarget.average)
            Text("区間ベスト").tag(LapTarget.sectionBest)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("lapTargetPicker")
    }

    /// 相手の名前（見出し・今日の行）。平均は日数を添える
    private func theirsName(_ comparison: BestComparison) -> String {
        target == .average ? String(localized: "平均（\(comparison.days)日）") : plainName
    }

    private var plainName: String {
        switch target {
        case .bestDay: String(localized: "ベストの日")
        case .average: String(localized: "平均")
        case .sectionBest: String(localized: "区間ベスト")
        }
    }

    private func bestRow(_ title: String, value: String, day: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.title2.bold().monospacedDigit())
            Text(TimeMapView.dayText(day)).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    /// 「1　100.4pt　9月28日(月)」。順位・ポイント・日付を縦にそろえる（2026-10-11）：順位とポイントは、
    /// 一覧の中で一番長いものの幅に右寄せ（100.4pt と 99.0pt で日付がずれない）。文字が大きくて入らなければ日付を下に
    private func topRow(rank: Int, day: DayPoints) -> some View {
        let widestRank = "\(top.count)"
        let widestPoints = top.map { RaceChart.pointText($0.points ?? 0) }.max { $0.count < $1.count } ?? ""
        let points = ZStack(alignment: .trailing) {
            Text(widestPoints).hidden()
            Text(RaceChart.pointText(day.points ?? 0))
        }
        .font(.body.bold().monospacedDigit())
        .fixedSize()
        let date = Text(TimeMapView.dayText(day.dayStart)).font(.subheadline).foregroundStyle(.secondary)
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            ZStack(alignment: .trailing) {
                Text(widestRank).hidden()
                Text("\(rank)")
            }
            .font(.body.monospacedDigit()).foregroundStyle(.secondary)
            .fixedSize()
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) { points; date }
                VStack(alignment: .leading, spacing: 2) { points; date }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// 「今日 今まで 78.3pt」と、相手の同じ時刻までと差。上回っていれば赤
    private func todayRow(_ comparison: BestComparison) -> some View {
        let wins = comparison.wins
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                todayValue(comparison, wins: wins)
                Spacer()
                todayGap(comparison, wins: wins, alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 4) {
                todayValue(comparison, wins: wins)
                todayGap(comparison, wins: wins, alignment: .leading)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("bestTodayRow")
    }

    private func todayValue(_ comparison: BestComparison, wins: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("今日（今まで）").font(.subheadline).foregroundStyle(.secondary)
            Text(RaceChart.pointText(comparison.today)).font(.title2.bold().monospacedDigit())
                .foregroundStyle(wins ? Theme.record : .primary)
        }
    }

    private func todayGap(_ comparison: BestComparison, wins: Bool, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text("\(theirsName(comparison))の同じ時刻 \(RaceChart.pointText(comparison.theirsAtSameTime))")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text(RaceChartLayout.signedPoints(comparison.gap)).font(.headline.monospacedDigit())
                .foregroundStyle(wins ? Theme.record : Theme.behind)
        }
    }
}

/// 自己ベストのラップ表（ANA-06）：縦は2時間の区間、横は［今日｜今日の累計｜相手｜相手の累計｜累計の差］（オーナーの案）。
/// 見出しは「今日」「相手の名前」「差」と「区間・累計」の2段（1段の案と比べた）。
/// 今日が上回った数字と、前にいる累計の差は赤。区間ベストを超えた今日の区間に金の ★（ANA-11）。
/// 文字が大きくて入らないときは区間ごとに縦に並べる
struct BestLapTable: View {
    let rows: [BestLapRow]
    /// 相手の名前（「ベストの日」「平均（12日）」「区間ベスト」）
    let theirsName: String
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // ViewThatFits で選ぶと、リストの行の高さが表のぶん残って上に空白ができるので、文字サイズで分ける。
        // 5列が入るのは「特大」の一つ手前まで（iPhone の幅で確かめた）
        Group {
            if typeSize >= .xxxLarge {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(rows) { row in
                        stackedRow(row)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            // 今の区間のまとまりに薄い背景（2026-10-11）
                            .padding(row.isCurrent ? 6 : 0)
                            .background(RoundedRectangle(cornerRadius: 8).fill(row.isCurrent ? Self.currentFill : .clear))
                            .padding(row.isCurrent ? -6 : 0)
                    }
                }
            } else {
                grid
            }
        }
        .accessibilityIdentifier("bestLapTable")
    }

    /// 今の区間の行の背景。前向きな色・赤・金と紛れない薄い灰色（2026-10-11）
    static let currentFill = Color(.tertiarySystemFill)
    /// ★ の幅（列のあいだの 10pt に足して ★ が入る分）
    @ScaledMetric(relativeTo: .subheadline) private var starGap: CGFloat = 5

    private var grid: some View {
        // ★ は数字の左の空き（区間の時刻とのあいだ）に置き、列の幅に入れない。★ の分の空きを時刻の列の右に取る
        let hasGold = rows.contains(where: \.gold)
        return Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                Text("今日").gridCellColumns(2).gridCellAnchor(.center)
                Text(theirsName).gridCellColumns(2).gridCellAnchor(.center)
                Text("差")
            }
            .font(.caption.bold()).foregroundStyle(.secondary)
            GridRow {
                Text("区間").gridColumnAlignment(.leading)
                Text("区間")
                Text("累計")
                Text("区間")
                Text("累計")
                Text("累計")
            }
            .font(.caption2).foregroundStyle(.secondary)
            Divider()
            ForEach(rows) { row in
                GridRow {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(Self.startText(row))
                        if row.isCurrent { Text("途中").font(.caption2).foregroundStyle(.secondary) }
                    }
                    // ★ が区間の時刻に重ならないよう、★ があるときは時刻の列の右に少し空きを足す
                    // （隠した ★ で場所を取ると、リストの行の高さがずれて表の上に空白ができた）
                    .padding(.trailing, hasGold ? starGap : 0)
                    .currentRowBounds(row.isCurrent)
                    gridTodayNumber(row)
                    number(row.todayTotal, wins: row.totalWins)
                    number(row.theirs, wins: false).foregroundStyle(.secondary)
                    number(row.theirsTotal, wins: false).foregroundStyle(.secondary)
                    gap(row).currentRowBounds(row.isCurrent)
                }
                .font(.subheadline.monospacedDigit())
                .accessibilityElement(children: .combine)
            }
        }
        // 今の区間の行に薄い背景（2026-10-11）。行の左の端（時刻）と右の端（差）の位置から敷く
        .backgroundPreferenceValue(CurrentRowBoundsKey.self) { anchors in
            GeometryReader { proxy in
                if let first = anchors.first {
                    let rect = anchors.dropFirst().reduce(proxy[first]) { $0.union(proxy[$1]) }
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Self.currentFill)
                        .frame(width: rect.width + 12, height: rect.height + 6)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
        }
    }

    /// 表の今日の区間の数字。区間ベストを超えたら、数字の左に同じ大きさの金の ★（「★10.6」）。
    /// ★ は列の幅に入れず、数字の左の空きに重ねる（10pt 以上でも数字が切れず、右端が上下の行とそろう、2026-10-11）
    private func gridTodayNumber(_ row: BestLapRow) -> some View {
        number(row.today, wins: row.todayWins)
            .overlay(alignment: .leading) {
                if row.gold {
                    // 幅0の枠の右端に ★ の右端を合わせ、数字の左へはみ出させる（表の幅には入らない）
                    Text(verbatim: "★")
                        .foregroundStyle(Theme.gold)
                        .fixedSize()
                        .frame(width: 0, alignment: .trailing)
                        .offset(x: -1)
                        .accessibilityLabel(Text("区間ベスト更新"))
                        .accessibilityIdentifier("bestLapGold")
                }
            }
    }

    private func stackedRow(_ row: BestLapRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Self.rangeText(row) + (row.isCurrent ? "（途中）" : "")).font(.subheadline.bold())
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    pair(Text("今日"), todayNumber(row))
                    pair(Text("累計"), number(row.todayTotal, wins: row.totalWins))
                }
                VStack(alignment: .leading, spacing: 6) {
                    pair(Text("今日"), todayNumber(row))
                    pair(Text("今日の累計"), number(row.todayTotal, wins: row.totalWins))
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    pair(Text(theirsName), number(row.theirs, wins: false))
                    pair(Text("累計"), number(row.theirsTotal, wins: false))
                }
                VStack(alignment: .leading, spacing: 6) {
                    pair(Text(theirsName), number(row.theirs, wins: false))
                    pair(Text("\(theirsName)の累計"), number(row.theirsTotal, wins: false))
                }
            }
            pair(Text("累計の差"), gap(row))
        }
        .font(.subheadline.monospacedDigit())
        .accessibilityElement(children: .combine)
    }

    /// 見出しと数字の組。横に入らなければ見出しの下に数字（文字が大きいとき、見出しや数字を途中で折り返さない）
    private func pair(_ label: Text, _ value: some View) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                label.foregroundStyle(.secondary)
                value
            }
            VStack(alignment: .leading, spacing: 0) {
                label.foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                value
            }
        }
    }

    /// 縦に並べたときの今日の区間の数字。区間ベストを超えたら、数字の左に同じ大きさの金の ★（「今日 ★9.1」）
    @ViewBuilder
    private func todayNumber(_ row: BestLapRow) -> some View {
        if row.gold {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text("★").foregroundStyle(Theme.gold).accessibilityLabel("区間ベスト更新")
                number(row.today, wins: row.todayWins)
            }
        } else {
            number(row.today, wins: row.todayWins)
        }
    }

    /// 0.1pt の数字。空の欄（まだ来ていない区間）は「—」
    private func number(_ value: Double?, wins: Bool) -> some View {
        Text(value.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—")
            .foregroundStyle(wins ? Theme.record : value == nil ? .secondary : .primary)
            .fontWeight(wins ? .bold : .regular)
    }

    @ViewBuilder
    private func gap(_ row: BestLapRow) -> some View {
        if let gap = row.totalGap {
            Text(String(RaceChartLayout.signedPoints(gap).dropLast(2)))
                .foregroundStyle(row.totalWins ? Theme.record : Theme.behind)
                .fontWeight(row.totalWins ? .bold : .regular)
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }

    private static let timeStyle = Date.FormatStyle.dateTime.hour(.defaultDigits(amPM: .omitted)).minute(.twoDigits)

    /// 例：8:00
    static func startText(_ row: BestLapRow) -> String { row.section.start.formatted(timeStyle) }

    /// 例：8:00–10:00
    static func rangeText(_ row: BestLapRow) -> String {
        "\(row.section.start.formatted(timeStyle))–\(row.section.end.formatted(timeStyle))"
    }
}

/// 時間帯の地図（ANA-07）：曜日×2時間の区間。濃いほど集中している（直近4週の平均）
struct TimeMapView: View {
    let map: TimeMap
    static let weekdays = ["月", "火", "水", "木", "金", "土", "日"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                grid
                if let peak = Self.peakText(map) { Text(peak).font(.subheadline) }
                Text("直近4週の、曜日と時間帯ごとの集中の平均。濃いほど長く集中しています（今日は入れません）。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .navigationTitle("時間帯の地図")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var grid: some View {
        let maxValue = max(map.maxValue, 1)
        return Grid(horizontalSpacing: 3, verticalSpacing: 3) {
            GridRow {
                Text("")
                ForEach(Self.weekdays, id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary) }
            }
            ForEach(0..<Laps.count, id: \.self) { section in
                GridRow {
                    Text("\((DayBoundary.hour + section * 2) % 24):00").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        .lineLimit(1).fixedSize()
                        .gridColumnAlignment(.trailing)
                    ForEach(0..<7, id: \.self) { weekday in
                        let value = map.averages[weekday][section]
                        RoundedRectangle(cornerRadius: 3)
                            .fill(value == 0 ? Color.secondary.opacity(0.08) : Theme.focus.opacity(0.15 + 0.85 * Double(value) / Double(maxValue)))
                            .frame(height: 22)
                            .accessibilityLabel("\(Self.weekdays[weekday])曜 \((DayBoundary.hour + section * 2) % 24)時から")
                            .accessibilityValue(DurationFormat.japanese(value))
                    }
                }
            }
        }
        // マスの幅は変えないので、時刻と曜日は折り返さない大きさまで
        .dynamicTypeSize(...DynamicTypeSize.large)
        .accessibilityIdentifier("timeMapGrid")
    }

    /// 例：よく集中するのは 水曜の 10:00–12:00
    static func peakText(_ map: TimeMap) -> String? {
        map.peak.map { peak in
            let start = (DayBoundary.hour + peak.section * 2) % 24
            return "よく集中するのは \(weekdays[peak.weekday])曜の \(start):00–\((start + 2) % 24):00"
        }
    }

    /// 例：9月28日
    static func shortDayText(_ day: Date) -> String {
        day.formatted(.dateTime.month().day().locale(Locale(identifier: "ja_JP")))
    }

    /// 例：9月28日（日）
    static func dayText(_ day: Date) -> String {
        day.formatted(.dateTime.month().day().weekday(.abbreviated).locale(Locale(identifier: "ja_JP")))
    }
}

/// ラップ表の今の区間の行の、端のセルの位置（背景を敷くため）
private struct CurrentRowBoundsKey: PreferenceKey {
    static let defaultValue: [Anchor<CGRect>] = []
    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value += nextValue()
    }
}

private extension View {
    func currentRowBounds(_ isCurrent: Bool) -> some View {
        anchorPreference(key: CurrentRowBoundsKey.self, value: .bounds) { isCurrent ? [$0] : [] }
    }
}
