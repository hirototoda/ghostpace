import Charts
import SwiftUI

/// 分析のタブで進む先
enum AnalysisRoute: Hashable {
    case points
    case timeline
    /// その日のグラフ（その日の 4:00。開いたまま4:00をまたいでも同じ日を指すよう日付で持つ）
    case day(Date)
}

/// 分析のタブ（NAV-01・ANA-03、2026-10-05 オーナー決定でタイムラインのタブを置き換え）。項目の一覧から進む
struct AnalysisScreen: View {
    @Bindable var model: AppModel
    @Binding var path: [AnalysisRoute]
    /// 昨日までの7日の平均（開いたとき・1分ごとの読み直しで数え直す。描き直すたびには数えない）
    @State private var average: Double?

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
            }
            .navigationTitle("分析")
            .task(id: model.snapshot.now) { average = PointsHistory.average(model.pointsHistory(days: 8)) }
            .navigationDestination(for: AnalysisRoute.self) { route in
                switch route {
                case .points: PointsHistoryView(model: model)
                case .timeline: TimelineScreen(model: model)
                case .day(let dayStart): DayGraphView(model: model, dayStart: dayStart)
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
                    .navigationTitle(Text(snapshot.dayStart.formatted(
                        .dateTime.month().day().weekday(.abbreviated).locale(Locale(identifier: "ja_JP")))))
            } else {
                ContentUnavailableView("記録を読めませんでした", systemImage: "exclamationmark.triangle")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}
