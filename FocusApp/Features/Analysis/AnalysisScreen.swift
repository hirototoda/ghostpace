import Charts
import SwiftUI

/// 分析のタブで進む先
enum AnalysisRoute: Hashable {
    case points
    case timeline
    /// その日のグラフ（その日の 4:00。開いたまま4:00をまたいでも同じ日を指すよう日付で持つ）
    case day(Date)
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
                case .best: PersonalBestView(model: model)
                case .timeMap: TimeMapView(map: model.timeMap())
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
    /// 表示している期間の数字。期間を変えたとき・1分ごとの読み直しで数え直す（30日分を描き直すたびに数えない）
    @State private var history: [DayPoints] = []

    var body: some View {
        List {
            Section {
                Picker("期間", selection: $days) {
                    Text("7日").tag(7)
                    Text("30日").tag(30)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("pointsRangePicker")
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
        .task(id: Refresh(days: days, now: model.snapshot.now)) { history = model.pointsHistory(days: days) }
    }

    private struct Refresh: Equatable {
        var days: Int
        var now: Date
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
            Text("今日は今まで（薄い色）")
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

/// その日のグラフ（ANA-05）：ホームの円の裏と同じグラフ。過ぎた日は 4:00〜翌4:00 の1日で始める
struct DayGraphView: View {
    @Bindable var model: AppModel
    let dayStart: Date

    var body: some View {
        ScrollView {
            if let snapshot = model.daySnapshot(of: dayStart) {
                // 過ぎた日（翌4:00 まで数えた日）は1日で始める。今日はホームの裏と同じ
                RaceChart(snapshot: snapshot, opponent: model.opponent, isPastDay: snapshot.now >= snapshot.dayEnd)
                    .aspectRatio(0.8, contentMode: .fit)
                    .padding(16)
                LapList(laps: snapshot.laps(model.opponent).filter { !$0.isEmpty }, opponent: model.opponent)
                    .padding(.horizontal, 16).padding(.bottom, 16)
                    .navigationTitle(Text(snapshot.dayStart.formatted(
                        .dateTime.month().day().weekday(.abbreviated).locale(Locale(identifier: "ja_JP")))))
            } else {
                ContentUnavailableView("記録を読めませんでした", systemImage: "exclamationmark.triangle")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// その日のラップの一覧（GHO-06）：2時間ごとの自分・相手の集中と差
struct LapList: View {
    let laps: [Lap]
    let opponent: Opponent

    var body: some View {
        if !laps.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("ラップ（2時間ごと）").font(.headline)
                ForEach(laps) { lap in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(AppModel.lapRange(lap) + (lap.isCurrent ? "（途中）" : "")).font(.subheadline.monospacedDigit())
                            Text("\(DurationFormat.japanese(lap.mine))・\(opponent == .goal ? "目標" : "先週") \(DurationFormat.japanese(lap.opponent))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(DurationFormat.signed(lap.diff)).font(.subheadline.bold().monospacedDigit())
                            .foregroundStyle(Theme.diffColor(lap.diff))
                    }
                    .accessibilityElement(children: .combine)
                    Divider()
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
            .accessibilityIdentifier("lapList")
        }
    }
}

/// 自己ベスト（ANA-06）：一番多い1日の集中した時間とポイント。押すとその日のグラフ
struct PersonalBestView: View {
    @Bindable var model: AppModel
    @State private var points: (points: Double, dayStart: Date)??

    var body: some View {
        List {
            if let best = model.snapshot.personalBest {
                NavigationLink(value: AnalysisRoute.day(best.focusDay)) {
                    bestRow("集中した時間", value: DurationFormat.japanese(best.focusSeconds), day: best.focusDay)
                }
            }
            switch points {
            case .some(.some(let best)):
                NavigationLink(value: AnalysisRoute.day(best.dayStart)) {
                    bestRow("ポイント", value: RaceChart.pointText(best.points), day: best.dayStart)
                }
            case .some(.none): EmptyView()
            case .none: ProgressView()
            }
            if model.snapshot.personalBest == nil, case .some(.none) = points {
                Text("まだ記録がありません").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("自己ベスト")
        .navigationBarTitleDisplayMode(.inline)
        .task { points = .some(model.bestPointsDay()) }
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

    /// 例：9月28日（日）
    static func dayText(_ day: Date) -> String {
        day.formatted(.dateTime.month().day().weekday(.abbreviated).locale(Locale(identifier: "ja_JP")))
    }
}
