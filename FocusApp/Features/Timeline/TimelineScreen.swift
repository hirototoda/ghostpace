import SwiftUI

/// タイムラインの画面。分析のタブの一覧から進む（NAV-01、2026-10-05 から。それまでは下のタブの1つ）
struct TimelineScreen: View {
    @Bindable var model: AppModel
    @State private var daysAgo = 0
    /// 終了時刻を早めている記録
    @State private var editing: FocusSession?
    /// 保存したら読み直す（タイムラインは開くたびに記録から作る）
    @State private var version = 0
    var body: some View {
        Group {
            let _ = version
            if let day = model.timelineDay(daysAgo: daysAgo) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        totals(day)
                        content(day)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
                .safeAreaInset(edge: .top) { dayPicker(day) }
            } else {
                ContentUnavailableView("記録を読めませんでした", systemImage: "exclamationmark.triangle")
            }
        }
        .sheet(item: $editing) { session in
            ShortenEndSheet(session: session,
                            showsDate: model.crossesDate(from: session.startAt, to: session.endAt ?? session.startAt)) { newEnd in
                if model.shortenEnd(session, to: newEnd) {
                    editing = nil
                    version += 1
                }
            }
            .saveErrorAlert($model.errorMessage)
        }
        .saveErrorAlert($model.errorMessage, when: editing == nil)
        .navigationTitle("タイムライン")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Theme.focus)
    }

    private func dayPicker(_ day: TimelineDay) -> some View {
        HStack {
            Button("前の日", systemImage: "chevron.left") { daysAgo += 1 }
                .accessibilityIdentifier("previousDayButton")
            Spacer()
            VStack(spacing: 2) {
                Text(day.dayStart.formatted(.dateTime.month().day().weekday(.abbreviated).locale(Locale(identifier: "ja_JP")))
                     + (day.isToday ? "（今日）" : ""))
                    .font(.headline)
                // その日に開けた時間と回数（TML-05）。日を切り替えるたびに日付と一緒に読めるよう、日付の下に置く（2026-10-03 オーナー決定、案C）
                if let opened = day.opened { OpenedLabel(opened: opened).accessibilityIdentifier("timelineOpenedLabel") }
            }
            // 上に固定する帯なので、大きな文字でも画面を取りすぎないよう上限を付ける（ホームの日付と同じ）
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            Spacer()
            Button("次の日", systemImage: "chevron.right") { daysAgo -= 1 }
                .disabled(daysAgo == 0)
                .accessibilityIdentifier("nextDayButton")
        }
        .labelStyle(.iconOnly)
        .font(.title3)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.bar)
    }

    private func totals(_ day: TimelineDay) -> some View {
        // 入りきらない文字サイズでは縦に並べる（朝の計画と同じ）
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) { totalLabels(day) }
            VStack(alignment: .leading, spacing: 4) { totalLabels(day) }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .padding(.top, 8)
    }

    @ViewBuilder
    private func totalLabels(_ day: TimelineDay) -> some View {
        StatLabel(title: "集中", seconds: day.focusSeconds, color: Theme.focus, systemImage: "circle.fill")
        // タイムラインは何をしていたかの記録なので、デトックスのカテゴリのタイマーの合計（ホームのデトックスはブロックの時間、DTX-04）
        StatLabel(title: "デトックスのタイマー", seconds: day.detoxSeconds, color: Theme.detox, systemImage: "leaf.fill")
    }

    @ViewBuilder
    private func content(_ day: TimelineDay) -> some View {
        if day.planBlocks.isEmpty && day.sessions.isEmpty {
            Text("この日の計画と記録はありません。").font(.subheadline).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.top, 40)
        } else {
            TimelineCardsView(day: day) { editing = $0 }
        }
    }
}

// MARK: - 共通の部品

private func color(_ countsAsFocus: Bool) -> Color { countsAsFocus ? Theme.focus : Theme.detox }

private let hm = Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)

/// 記録の説明（時刻・集中した時間・中断回数・実行中・申告・修正済み）
func sessionCaption(_ s: FocusSession, now: Date) -> String {
    var parts = ["\(s.startAt.formatted(hm))–\(s.endAt.map { $0.formatted(hm) } ?? "")"]
    parts.append(DurationFormat.japanese(s.activeSeconds(at: now)))
    if s.pauseCount > 0 { parts.append("中断\(s.pauseCount)回") }
    if s.isRunning { parts.append("実行中") }
    if s.isDeclared { parts.append("申告") }
    if s.originalEndAt != nil { parts.append("修正済み") }
    return parts.joined(separator: "・")
}

/// 記録の帯。一時停止していた時間は薄くする（TML-03）
private struct SessionBar: View {
    let session: FocusSession
    let now: Date
    /// 帯の左端と右端の時刻
    let range: ClosedRange<Date>

    var body: some View {
        GeometryReader { proxy in
            let length = proxy.size.width
            let offset = { (date: Date) in position(date, length: length) }
            let end = session.endAt ?? now
            let tint = color(session.category.countsAsFocus)
            ZStack(alignment: .leading) {
                block(from: offset(session.startAt), to: offset(end), in: proxy.size).fill(tint.opacity(0.25))
                ForEach(Array(session.activeSegments(now: now).enumerated()), id: \.offset) { _, segment in
                    block(from: offset(segment.start), to: offset(segment.end), in: proxy.size).fill(tint)
                }
            }
        }
    }

    /// 帯の中での位置（0〜length）
    private func position(_ date: Date, length: CGFloat) -> CGFloat {
        let total = max(range.upperBound.timeIntervalSince(range.lowerBound), 1)
        return CGFloat(min(max(date.timeIntervalSince(range.lowerBound), 0), total) / total) * length
    }

    private func block(from start: CGFloat, to end: CGFloat, in size: CGSize) -> some Shape {
        let length = max(end - start, 2)
        return Path(roundedRect: CGRect(x: start, y: 0, width: length, height: size.height), cornerRadius: 4)
    }
}

// MARK: - カード（2026-10-01 決定：時間軸・リストの案と比べて選んだ）

/// 計画ブロックごとのカード。予定の時間の中で、実際に動かした部分を塗る。計画外は最後にまとめる
private struct TimelineCardsView: View {
    let day: TimelineDay
    /// 直せる記録の行をタップしたとき
    let onEdit: (FocusSession) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if day.isNoPlanDay { Text("計画なし").font(.caption).foregroundStyle(.secondary) }
            ForEach(day.planBlocks) { block in card(block) }
            if !day.unplannedSessions.isEmpty {
                Text("計画外").font(.subheadline.bold()).foregroundStyle(.secondary).padding(.top, 8)
                ForEach(day.unplannedSessions) { session in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(session.title).font(.headline)
                        SessionBar(session: session, now: day.now, range: session.startAt...max(session.endAt ?? day.now, session.startAt))
                            .frame(height: 10)
                        sessionRow(session)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
                }
            }
        }
    }

    @ViewBuilder
    private func card(_ block: PlanBlockSummary) -> some View {
        if block.category.isUnblock { unblockCard(block) } else { blockCard(block) }
    }

    /// ゲーム・SNS の時間（BLK-10）。タイマーは始めないので、達成率と記録は出さない
    private func unblockCard(_ block: PlanBlockSummary) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "gamecontroller.fill").imageScale(.small)
            Text(block.title).font(.headline)
            Text("\(block.start.formatted(hm))–\(block.end.formatted(hm))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
        }
        .foregroundStyle(Theme.play)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.play.opacity(0.1)))
        .accessibilityElement(children: .combine)
    }

    private func blockCard(_ block: PlanBlockSummary) -> some View {
        let sessions = day.sessions(of: block)
        let percent = day.achievementPercent(of: block)
        let tint = color(block.countsAsFocus)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(block.title).font(.headline)
                Text("\(block.start.formatted(hm))–\(block.end.formatted(hm))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Text(percent.map { "\($0)%" } ?? "—").font(.headline.monospacedDigit())
                    .foregroundStyle((percent ?? 0) > 0 ? tint : .secondary)
                    .accessibilityLabel(percent.map { "達成率 \($0)%" } ?? "まだ始まっていません")
            }
            // ブロックの時間の中で、実際に動かした部分を塗る
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.1))
                ForEach(sessions) { session in
                    SessionBar(session: session, now: day.now, range: block.start...block.end)
                }
            }
            .frame(height: 12)
            if sessions.isEmpty {
                Text("記録なし").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(sessions) { sessionRow($0) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.35)))
    }

    /// 記録の行。今日と昨日の終わった記録だけタップで終了時刻を早められる（「›」付き）
    @ViewBuilder
    private func sessionRow(_ session: FocusSession) -> some View {
        let caption = Text(sessionCaption(session, now: day.now)).font(.caption).foregroundStyle(.secondary)
        if day.canEdit(session) {
            Button { onEdit(session) } label: {
                HStack(spacing: 4) {
                    caption
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption2.bold()).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("終了時刻を早めます")
            .accessibilityIdentifier("sessionRow")
        } else {
            caption
        }
    }
}
