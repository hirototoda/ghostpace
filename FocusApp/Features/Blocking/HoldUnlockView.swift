import SwiftUI

/// 長押しの画面（BLK-05・BLK-07・BLK-08、docs/product/features/app-blocking.md。2026-10-01 案A「円を押す」に決定）。
/// 開ける長さ（5分〜1時間、初めは15分）を選び、円を3秒押し続けると5秒数えてから開く。途中で離すと最初から。
/// 押している間、先週の自分との差を見せる。開けている間は残り時間と「今すぐ戻す」だけを出す。
struct HoldUnlockView: View {
    let snapshot: HomeSnapshot
    let opponent: Opponent
    /// 開けている期限。nil ならブロック中
    let unlockedUntil: Date?
    let onUnlock: (Int) -> Void
    let onReblock: () -> Void
    let onClose: () -> Void
    /// 開けた時間が終わった（画面を閉じてブロックに戻ったことを反映する）
    var onExpire: () -> Void = {}
    /// 見本の撮影用に、押している途中の見た目で始める
    var initialProgress: Double = 0
    /// ゲーム・SNS の時間で開いているときの、その終わり（BLK-10）。長押しは要らないので知らせるだけ
    var unblockedUntil: Date?

    @State private var minutes = BlockPolicy.defaultUnlockMinutes
    /// 押し終わってから開くまでの残り秒数。nil なら数えていない
    @State private var countdown: Int?
    @State private var countdownTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let unlockedUntil {
                UnlockedView(until: unlockedUntil, onReblock: onReblock, onClose: onClose, onExpire: onExpire)
            } else if let unblockedUntil {
                unblockedContent(until: unblockedUntil)
            } else {
                holdContent
            }
        }
        .sensoryFeedback(.success, trigger: unlockedUntil != nil) { _, new in new }
        // ほかのアプリに移ったら数え直し（押すところから）
        .onChange(of: scenePhase) { _, phase in if phase != .active { stopCountdown() } }
        .onDisappear { stopCountdown() }
    }

    /// ゲーム・SNS の時間の中（BLK-10）：開けなくても使える
    private func unblockedContent(until: Date) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "gamecontroller.fill").font(.system(size: 52)).foregroundStyle(Theme.play)
            Text("今はゲーム・SNS の時間です（\(until.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))) まで）")
                .font(.title3.bold()).multilineTextAlignment(.center)
                .accessibilityIdentifier("unblockedTitle")
            Text("ゲームや SNS をそのまま開けます。この時間もデトックスとして数えます。")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
            Button("閉じる", action: onClose)
                .buttonStyle(.borderedProminent).controlSize(.large)
                .accessibilityIdentifier("holdCancelButton")
        }
        .padding(24)
    }

    private func startCountdown() {
        countdownTask?.cancel()
        let chosen = minutes
        countdownTask = Task {
            for remaining in stride(from: BlockPolicy.countdownSeconds, to: 0, by: -1) {
                countdown = remaining
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            countdown = nil
            onUnlock(chosen)
        }
    }

    private func stopCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdown = nil
    }

    // MARK: 対戦の数字

    /// 比べる相手（選んだ相手がいなければ、いる方）
    private var raceOpponent: Opponent? {
        snapshot.opponentDiffSeconds(opponent) != nil ? opponent
            : Opponent.allCases.first { snapshot.opponentDiffSeconds($0) != nil }
    }

    @ViewBuilder
    private var raceLine: some View {
        if let raceOpponent, let diff = snapshot.opponentDiffSeconds(raceOpponent) {
            VStack(spacing: 6) {
                Text("今日は\(raceOpponent.diffPrefix)").font(.headline).foregroundStyle(.secondary)
                DurationText(seconds: diff, signed: true, size: 64)
                    .foregroundStyle(Theme.diffColor(diff))
                Text(diff >= 0 ? "リードしています" : "まだ取り戻せます")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("holdRaceLine")
        } else {
            VStack(spacing: 6) {
                Text("今日の集中").font(.headline).foregroundStyle(.secondary)
                DurationText(seconds: snapshot.focusSeconds, size: 64)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("holdRaceLine")
        }
    }

    private var holdContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                Label("ゲームと SNS はブロック中", systemImage: "lock.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
                    .padding(.top, 32)
                Spacer(minLength: 24)
                raceLine
                Spacer(minLength: 24)
                MinutesStepper(minutes: $minutes)
                    .padding(.bottom, 20)
                    .disabled(countdown != nil)
                if let countdown {
                    CountdownCircle(remaining: countdown)
                    Text("\(countdown)秒後に\(minutes)分開きます")
                        .font(.footnote).foregroundStyle(.secondary)
                        .padding(.top, 14)
                } else {
                    HoldCircle(label: "押し続ける", initialProgress: initialProgress) { startCountdown() }
                    Text("3秒押し続けると、5秒後に\(minutes)分開きます")
                        .font(.footnote).foregroundStyle(.secondary)
                        .padding(.top, 14)
                }
                Spacer(minLength: 24)
                Button("やめる") {
                    stopCountdown()
                    onClose()
                }
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
                    .padding(.bottom, 12)
                    .accessibilityIdentifier("holdCancelButton")
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
            .containerRelativeFrame(.vertical, alignment: .center) { length, _ in length }
        }
        .scrollBounceBehavior(.basedOnSize)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }
}

/// 開ける長さ（5分〜1時間、5分刻み）。
private struct MinutesStepper: View {
    @Binding var minutes: Int

    private var lowest: Int { BlockPolicy.unlockMinuteOptions.first ?? 5 }
    private var highest: Int { BlockPolicy.unlockMinuteOptions.last ?? 60 }

    var body: some View {
        HStack(spacing: 16) {
            step("minus", enabled: minutes > lowest) { minutes -= 5 }
                .accessibilityIdentifier("unlockMinutesMinus")
            VStack(spacing: 0) {
                Text("開ける長さ").font(.caption).foregroundStyle(.secondary)
                Text("\(minutes)分").font(.title2.bold().monospacedDigit())
                    .accessibilityIdentifier("unlockMinutes")
            }
            .frame(minWidth: 96)
            step("plus", enabled: minutes < highest) { minutes += 5 }
                .accessibilityIdentifier("unlockMinutesPlus")
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private func step(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3.bold())
                .frame(width: 48, height: 48)
                .background(Circle().fill(Theme.focus.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Theme.focus : Color.secondary.opacity(0.4))
        .disabled(!enabled)
        .accessibilityLabel(symbol == "plus" ? "5分長く" : "5分短く")
    }
}

/// 3秒押し続けると `onComplete` を呼ぶ円。途中で離すと最初から（輪が戻る）。
/// 押した時間は自分で数える（SwiftUI の長押しは、実機で輪が回りきっても成立しないことがあった。2026-10-01）。
struct HoldCircle: View {
    var label: String
    var size: CGFloat = 180
    var initialProgress: Double = 0
    let onComplete: () -> Void

    @State private var progress: Double = 0
    @State private var pressTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Circle().fill(Theme.focus.opacity(0.08))
            Ring(progress: progress, color: Theme.focus, lineWidth: 10)
            VStack(spacing: 6) {
                Image(systemName: progress > 0 ? "lock.open.fill" : "lock.fill").font(.system(size: size * 0.19))
                Text(label).font(.subheadline.bold())
            }
            .foregroundStyle(Theme.focus)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .onAppear { progress = initialProgress }
        .onDisappear { release() }
        // スクロールより先に指を受け取る
        .highPriorityGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if pressTask == nil { press() } }
                .onEnded { _ in release() })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("3秒押し続けてください")
        .accessibilityIdentifier("holdButton")
    }

    private func press() {
        withAnimation(.linear(duration: BlockPolicy.holdSeconds)) { progress = 1 }
        pressTask = Task {
            try? await Task.sleep(for: .seconds(BlockPolicy.holdSeconds))
            if Task.isCancelled { return }
            onComplete()
        }
    }

    private func release() {
        pressTask?.cancel()
        pressTask = nil
        withAnimation(.easeOut(duration: 0.25)) { progress = 0 }
    }
}

/// 押し終わったあと、開くまでの残り秒数。
private struct CountdownCircle: View {
    let remaining: Int

    var body: some View {
        ZStack {
            Circle().fill(Theme.focus.opacity(0.08))
            Ring(progress: Double(remaining) / Double(BlockPolicy.countdownSeconds), color: Theme.focus, lineWidth: 10)
                .animation(.linear(duration: 1), value: remaining)
            Text("\(remaining)")
                .font(Theme.heroNumber(64))
                .foregroundStyle(Theme.focus)
                .contentTransition(.numericText(countsDown: true))
        }
        .frame(width: 180, height: 180)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("あと\(remaining)秒で開きます")
        .accessibilityIdentifier("unlockCountdown")
    }
}

/// 開けたあと：残り時間と「今すぐ戻す」。
private struct UnlockedView: View {
    let until: Date
    let onReblock: () -> Void
    let onClose: () -> Void
    let onExpire: () -> Void
    @Environment(\.clock) private var clock

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 24)
            Image(systemName: "lock.open.fill")
                .font(.system(size: 44))
                .foregroundStyle(Theme.focus)
                .accessibilityHidden(true)
            Text("開けました").font(.title2.bold())
                .accessibilityIdentifier("unlockedTitle")
            Text("ゲームや SNS を開き直してください")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let remaining = max(0, Int(until.timeIntervalSince(clock.now()).rounded(.up)))
                VStack(spacing: 4) {
                    Text(DurationFormat.clock(remaining)).font(Theme.heroNumber(56))
                    Text("でブロックに戻ります").font(.subheadline).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("unlockRemaining")
            }
            .padding(.top, 8)
            Spacer(minLength: 24)
            Button(action: onReblock) {
                Text("今すぐ戻す").font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityIdentifier("reblockNowButton")
            Button("閉じる", action: onClose)
                .font(.subheadline).foregroundStyle(.secondary)
                .padding(.bottom, 12)
                .accessibilityIdentifier("holdCloseButton")
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .task(id: until) {
            let remaining = until.timeIntervalSince(clock.now())
            if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
            if !Task.isCancelled { onExpire() }
        }
    }
}
