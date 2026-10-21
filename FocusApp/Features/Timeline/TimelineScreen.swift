import SwiftUI

/// タイムラインの画面。分析のタブの一覧から進む（NAV-01、2026-10-05 から。それまでは下のタブの1つ）
struct TimelineScreen: View {
    @Bindable var model: AppModel
    @State private var daysAgo = 0
    /// 出しているシート（終了時刻を早める・手動で記録・手動の記録を直す）
    @State private var sheet: TimelineSheet?
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
        .sheet(item: $sheet, onDismiss: { version += 1 }) { sheet in
            sheetContent(sheet)
                .saveErrorAlert($model.errorMessage)
        }
        .saveErrorAlert($model.errorMessage, when: sheet == nil)
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
            TimelineCardsView(day: day) { session in
                sheet = session.isDeclared ? .editManual(session) : .shorten(session)
            }
        }
        // 今日と昨日の画面の一番下に「＋ 手動で記録」（TML-06）
        if day.canAddManual {
            Button {
                sheet = .addManual(daysAgo: daysAgo)
            } label: {
                Label("手動で記録", systemImage: "plus").font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .padding(.top, 8)
            .accessibilityIdentifier("addManualButton")
        }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: TimelineSheet) -> some View {
        switch sheet {
        case .shorten(let session):
            ShortenEndSheet(session: session,
                            showsDate: model.crossesDate(from: session.startAt, to: session.endAt ?? session.startAt)) { newEnd in
                if model.shortenEnd(session, to: newEnd) { self.sheet = nil }
            }
        case .addManual(let daysAgo):
            ManualRecordSheet(mode: .choose(.init(categories: model.categories, projects: model.projects,
                                                  onCreateProject: { model.createProject(name: $0, category: $1) },
                                                  onCreateCategory: { model.createCategory(name: $0, countsAsFocus: $1, detoxGroup: $2) })),
                              initial: model.manualInitial(daysAgo: daysAgo), range: model.manualRange(),
                              problem: { model.manualProblem(start: $0, end: $1) }) { entry in
                guard let category = entry.category else { return false }
                return model.addManual(category: category, project: entry.project, start: entry.start, end: entry.end) == .saved
            }
        case .editManual(let session):
            ManualRecordSheet(mode: .edit(session),
                              initial: DateInterval(start: session.startAt, end: max(session.startAt, session.endAt ?? session.startAt)),
                              range: model.manualRange(),
                              problem: { model.manualProblem(start: $0, end: $1, editing: session.id) },
                              onSave: { model.updateManual(session, start: $0.start, end: $0.end) == .saved },
                              onDelete: { model.deleteManual(session) })
        }
    }
}

/// タイムラインから出すシート
private enum TimelineSheet: Identifiable {
    /// タイマーの記録の終了時刻を早める（TML-04）
    case shorten(FocusSession)
    /// 手動で記録（TML-06）。その日の画面から（今日は0、昨日は1）
    case addManual(daysAgo: Int)
    /// 手動の記録を直す・消す（TML-06）
    case editManual(FocusSession)

    var id: String {
        switch self {
        case .shorten(let session): "shorten-\(session.id)"
        case .addManual(let daysAgo): "add-\(daysAgo)"
        case .editManual(let session): "manual-\(session.id)"
        }
    }
}

// MARK: - 共通の部品

private func color(_ countsAsFocus: Bool) -> Color { countsAsFocus ? Theme.focus : Theme.detox }

private let hm = Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)

/// 記録の説明（時刻・集中した時間・中断回数・実行中・手動・修正済み）
func sessionCaption(_ s: FocusSession, now: Date) -> String {
    var parts = ["\(s.startAt.formatted(hm))–\(s.endAt.map { $0.formatted(hm) } ?? "")"]
    parts.append(DurationFormat.japanese(s.activeSeconds(at: now)))
    if s.pauseCount > 0 { parts.append("中断\(s.pauseCount)回") }
    if s.isRunning { parts.append("実行中") }
    // 手動の記録（TMR-13。2026-10-20 までの「申告」も同じ印なので「手動」と出す）
    if s.isDeclared { parts.append(String(localized: "手動")) }
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

    /// 記録の行。今日と昨日の終わった記録だけタップで直せる（「›」付き）。タイマーの記録は終了時刻を早め、手動の記録は直す・消す
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
            .accessibilityHint(session.isDeclared ? "手動の記録を直します" : "終了時刻を早めます")
            .accessibilityIdentifier(session.isDeclared ? "manualSessionRow" : "sessionRow")
        } else {
            caption
        }
    }
}
