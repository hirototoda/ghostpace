import SwiftUI

/// 計画の時間の格子（PLN-10、docs/product/features/daily-plan.md「時間の格子」）。
/// 縦に 4:00〜翌4:00。寝ている時間は灰色。長押しのドラッグで動かす、下の端で長さを変える（:00/:30 に吸い付く）、空いた所を押して足す
struct PlanGridView: View {
    let blocks: [PlanBlockDraft]
    let layout: PlanGridLayout
    let now: Date
    /// 今の時刻に線を引くか（今日だけ）
    let showsNow: Bool
    let awake: ClosedRange<Date>
    /// 確定した日（計画のタブ）。始まった・終わったブロックは動かさない
    let confirmedDay: Bool
    /// 編集もできないブロック（終わったゲーム・SNS の時間、BLK-10）
    let isLocked: (PlanBlockDraft) -> Bool
    let onTap: (PlanBlockDraft) -> Void
    let onTapEmpty: (Date) -> Void
    /// 動かした・長さを変えたブロックを渡す。保存できなければ呼ぶ側で理由を出し、元のまま
    let onCommit: (PlanBlockDraft) -> Void
    /// 目盛りの時刻を出す暦（アプリの暦を渡す）
    var calendar: Calendar = .app(timeZone: .current)

    /// ドラッグ中のブロックと動かした量（離すまで計画は変えない）。取り消されたら自動で消える
    @GestureState private var moving: (id: UUID, dy: CGFloat)?
    @GestureState private var resizing: (id: UUID, dy: CGFloat)?

    /// ドラッグ中の見た目
    private func preview(_ block: PlanBlockDraft) -> PlanBlockDraft? {
        if let moving, moving.id == block.id { return layout.moved(block, by: moving.dy) }
        if let resizing, resizing.id == block.id { return layout.resized(block, by: resizing.dy) }
        return nil
    }

    static let rulerWidth: CGFloat = 48

    var body: some View {
        ZStack(alignment: .topLeading) {
            ruler
            sleepShade(from: layout.dayStart, to: awake.lowerBound)
            sleepShade(from: awake.upperBound, to: layout.dayEnd)
            // 空いた所を押すと、その時刻から足す
            Color.clear
                .contentShape(Rectangle())
                .padding(.leading, Self.rulerWidth)
                .onTapGesture(coordinateSpace: .local) { location in onTapEmpty(layout.tapStart(y: location.y)) }
                .accessibilityHidden(true)
            ForEach(blocks) { block in
                blockView(preview(block) ?? block, original: block)
            }
            if showsNow, (layout.dayStart..<layout.dayEnd).contains(now) { nowLine }
        }
        .frame(height: layout.totalHeight)
        .coordinateSpace(name: "grid")
    }

    // MARK: 目盛り

    /// 1時間ごとの線と時刻。各時刻は `hour-<4:00 からの時間>` の ID を持つ（開いたときにそこへ送る）
    private var ruler: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { index in
                HStack(alignment: .top, spacing: 6) {
                    Text(hourLabel(index))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(width: Self.rulerWidth - 6, alignment: .trailing)
                        .offset(y: -7)
                        // 目盛りの幅は変えないので、大きな文字でも折り返さない大きさまで
                        .dynamicTypeSize(...DynamicTypeSize.large)
                    Rectangle().fill(Color.secondary.opacity(0.2)).frame(height: 0.5)
                }
                .frame(height: layout.hourHeight, alignment: .top)
                .id("hour-\(index)")
            }
        }
        .accessibilityHidden(true)
    }

    /// 4:00 から index 時間後の時刻（夏時間の切り替えの日も実際の時刻）
    private func hourLabel(_ index: Int) -> String {
        let date = layout.dayStart.addingTimeInterval(Double(index * 3600))
        return "\(calendar.component(.hour, from: date)):00"
    }

    private func sleepShade(from start: Date, to end: Date) -> some View {
        let height = max(0, layout.y(for: end) - layout.y(for: start))
        return Rectangle()
            .fill(Color.secondary.opacity(0.1))
            .overlay(alignment: .topLeading) {
                if height >= 24 {
                    Label("睡眠", systemImage: "moon.zzz.fill").font(.caption).foregroundStyle(.secondary).padding(6)
                        .dynamicTypeSize(...DynamicTypeSize.xLarge)
                }
            }
            .frame(height: height)
            .padding(.leading, Self.rulerWidth)
            .offset(y: layout.y(for: start))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var nowLine: some View {
        HStack(spacing: 0) {
            Circle().fill(Theme.focus).frame(width: 8, height: 8)
            Rectangle().fill(Theme.focus).frame(height: 1.5)
        }
        .padding(.leading, Self.rulerWidth - 4)
        .offset(y: layout.y(for: now) - 4)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: ブロック

    @ViewBuilder
    private func blockView(_ shown: PlanBlockDraft, original: PlanBlockDraft) -> some View {
        let movable = PlanGridLayout.canMove(original, confirmedDay: confirmedDay, now: now) && !isLocked(original)
        let isDragging = moving?.id == original.id || resizing?.id == original.id
        let height = max(layout.height(minutes: shown.minutes), 22)
        PlanGridBlock(block: shown, isPast: shown.end <= now && confirmedDay, isDragging: isDragging, height: height)
            .overlay(alignment: .bottom) {
                if movable, PlanGridLayout.canResize(original), height >= 30 { resizeHandle(original) }
            }
            .frame(height: height)
            .padding(.leading, Self.rulerWidth + 2)
            .padding(.trailing, 2)
            .offset(y: layout.y(for: shown.start))
            .zIndex(isDragging ? 1 : 0)
            .onTapGesture { if !isLocked(original) { onTap(original) } }
            .gesture(movable ? moveGesture(original) : nil)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(original.title) \(timeRange(original.start, original.end))")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: "30分早く") { if movable { onCommit(layout.shifted(original, minutes: -30)) } }
            .accessibilityAction(named: "30分遅く") { if movable { onCommit(layout.shifted(original, minutes: 30)) } }
            .accessibilityIdentifier("gridBlock")
    }

    /// 長押ししてからドラッグで動かす（すぐのドラッグは格子を上下に送るのに使う）
    private func moveGesture(_ block: PlanBlockDraft) -> some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(coordinateSpace: .named("grid")))
            .updating($moving) { value, state, _ in
                switch value {
                case .first(true): state = (block.id, 0)
                case .second(true, let drag): state = (block.id, drag?.translation.height ?? 0)
                default: break
                }
            }
            .onEnded { value in
                guard case .second(true, let drag?) = value else { return }
                let moved = layout.moved(block, by: drag.translation.height)
                if moved.start != block.start { onCommit(moved) }
            }
    }

    private func resizeHandle(_ block: PlanBlockDraft) -> some View {
        Capsule()
            .fill(Color.secondary.opacity(0.6))
            .frame(width: 32, height: 4)
            .padding(.vertical, 6)
            .padding(.horizontal, 24)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(coordinateSpace: .named("grid"))
                    .updating($resizing) { value, state, _ in state = (block.id, value.translation.height) }
                    .onEnded { value in
                        let resized = layout.resized(block, by: value.translation.height)
                        if resized.minutes != block.minutes { onCommit(resized) }
                    }
            )
            .accessibilityHidden(true)
    }
}

/// 格子の中の1ブロック。カテゴリの色の帯に名前と時刻
struct PlanGridBlock: View {
    let block: PlanBlockDraft
    let isPast: Bool
    let isDragging: Bool
    let height: CGFloat

    var body: some View {
        let color = block.isUnblock ? Theme.play : Theme.color(for: block.category)
        HStack(alignment: .top, spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4)
            // 短いブロックは1行に名前と時刻を並べる
            if height < 44 {
                HStack(spacing: 6) {
                    title(color)
                    Text(timeRange(block.start, block.end)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                .lineLimit(1)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    title(color)
                    Text(timeRange(block.start, block.end)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, height < 44 ? 3 : 6)
        .padding(.leading, 4).padding(.trailing, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(isDragging ? 0.3 : 0.16)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(color.opacity(isDragging ? 0.9 : 0), lineWidth: 1.5))
        .shadow(color: .black.opacity(isDragging ? 0.2 : 0), radius: 6, y: 3)
        .opacity(isPast ? 0.5 : 1)
        .clipped()
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    @ViewBuilder
    private func title(_ color: Color) -> some View {
        if block.isUnblock {
            Label(block.title, systemImage: "gamecontroller.fill")
                .font(.subheadline.bold()).foregroundStyle(color).lineLimit(1)
        } else {
            Text(block.title).font(.subheadline.bold()).lineLimit(height < 66 ? 1 : 2)
        }
    }
}
