import FamilyControls
import SwiftUI

/// この機能が入った版を最初に開いたときに1回だけ出す説明（BLK-01）。
struct BlockingIntroSheet: View {
    let onContinue: () -> Void
    let onLater: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.focus)
                    .padding(.top, 28)
                    .accessibilityHidden(true)
                Text("ゲームと SNS をブロックします").font(.title2.bold()).multilineTextAlignment(.center)
                VStack(alignment: .leading, spacing: 12) {
                    Label("いつも（24時間）ブロックします", systemImage: "clock")
                    Label("開きたいときは、GhostPace で3秒長押しすると、5秒後に5分〜1時間開けます", systemImage: "hand.tap")
                    Label("開いたことは記録して、あとで振り返りに使います", systemImage: "chart.bar")
                    Label("次の画面で Screen Time の許可を聞き、ブロックするアプリを選びます", systemImage: "checklist")
                }
                .font(.subheadline)
                .padding(.horizontal, 8)
            }
            .padding(24)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                Button(action: onContinue) {
                    Text("続ける").font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.extraLarge)
                .accessibilityIdentifier("blockingContinueButton")
                Button("あとで", action: onLater)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityIdentifier("blockingLaterButton")
            }
            .padding(.horizontal, 24).padding(.bottom, 8)
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled()
        .tint(Theme.focus)
    }
}

/// 選択画面で選ぶもの。
enum BlockSelectionPurpose: Hashable {
    /// いつものブロックの対象（BLK-09）
    case blocked
    /// 集中中も使うアプリ（BLK-02）
    case focusAllow
}

/// ブロックするアプリ・集中中も使うアプリを選ぶ画面（BLK-01・BLK-02・BLK-09）。iPhone 標準の選択画面をこの画面に埋め込み、「完了」で保存する。
/// 選択画面を `.familyActivityPicker` で出すと、設定の一覧の中からでは実機ですぐ閉じてしまった（2026-10-01）ため、この形にした。
/// すでに対象があるときは、外せば長押しなしで開けてしまうので、先に開くときと同じ長押し（3秒＋5秒）を挟む。
struct BlockSelectionSheet: View {
    let model: AppModel
    var purpose: BlockSelectionPurpose = .blocked
    let requiresHold: Bool
    @State private var selection = FamilyActivitySelection()
    @State private var holdDone = false
    @State private var countdown: Int?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if requiresHold && !holdDone { holdStep } else { pickerStep }
            }
            .navigationTitle(purpose == .blocked ? "ブロックするアプリ" : "集中中も使うアプリ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("やめる") { dismiss() }
                        .accessibilityIdentifier("blockSelectionCancelButton")
                }
                if !requiresHold || holdDone {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完了") { save() }
                            .accessibilityIdentifier("blockSelectionDoneButton")
                    }
                }
            }
        }
        .tint(Theme.focus)
        .interactiveDismissDisabled()
        .onAppear {
            let current = purpose == .blocked ? model.blockSelection : model.focusAllowSelection
            selection = current.flatMap(ShieldControl.decode) ?? FamilyActivitySelection()
        }
        .task(id: countdown) {
            guard let countdown else { return }
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return }
            if countdown > 1 { self.countdown = countdown - 1 } else { holdDone = true }
        }
    }

    @ViewBuilder
    private var pickerStep: some View {
        switch purpose {
        case .blocked:
            FamilyActivityPicker(headerText: "「ソーシャル」と「ゲーム」に印をつけて、右上の「完了」を押してください",
                                 footerText: "選んだアプリとサイトを、いつもブロックします。開くときは GhostPace で3秒長押しします。",
                                 selection: $selection)
        case .focusAllow:
            FamilyActivityPicker(headerText: Self.focusAllowHeader, footerText: Self.focusAllowFooter, selection: $selection)
        }
    }

    /// GhostPace まで止まると一時停止も長押しもできなくなるので、選んでおいてもらう（app-blocking.md）
    static let focusAllowHeader = "集中中も使うアプリ（Kindle・辞書など）を選んで、右上の「完了」を押してください。GhostPace も選んでおいてください"
    static let focusAllowFooter = "集中のタイマー中は、ここで選んだもの以外のアプリをブロックします。何も選ばなければ全部ブロックします。"

    private var holdStep: some View {
        VStack(spacing: 18) {
            Text("外すと長押しなしで開けてしまうので、変える前にも3秒押して5秒待ってください")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let countdown {
                Text("\(countdown)").font(Theme.heroNumber(64)).foregroundStyle(Theme.focus)
                    .frame(width: 150, height: 150)
                    .contentTransition(.numericText(countsDown: true))
            } else {
                HoldCircle(label: "押し続ける", size: 150) { countdown = BlockPolicy.countdownSeconds }
            }
        }
        .padding(24)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(selection) else { return }
        switch purpose {
        case .blocked:
            if model.saveBlockSelection(data) { dismiss() }
        case .focusAllow:
            model.saveFocusAllowSelection(data)
            dismiss()
        }
    }
}

/// 設定の「アプリのブロック」（settings.md、app-blocking.md）。
struct BlockingSettingsSection: View {
    @Bindable var model: AppModel
    let notificationsOff: Bool
    /// 選ぶ画面を出す（出すのは設定の画面の外側。一覧の中から出すと閉じてしまうため）
    let onSelect: () -> Void
    /// 集中中も使うアプリを選ぶ画面を出す
    let onSelectFocusAllow: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section {
            statusRow
            if model.blockingAuthorization != .unavailable, model.isBlockingStarted {
                Button {
                    onSelect()
                } label: {
                    LabeledContent("ブロックするアプリ") {
                        Text(model.hasBlockSelection ? "\(model.blockSelectionCount)件" : "もう一度選んでください")
                    }
                }
                .foregroundStyle(.primary)
                .accessibilityIdentifier("blockSelectionButton")
                Button {
                    onSelectFocusAllow()
                } label: {
                    LabeledContent("集中中も使うアプリ") {
                        Text(model.focusAllowCount > 0 ? "\(model.focusAllowCount)件" : "なし（全部ブロック）")
                    }
                }
                .foregroundStyle(.primary)
                .accessibilityIdentifier("focusAllowButton")
                if model.unlockedUntil == nil {
                    Button {
                        model.openHold()
                    } label: {
                        Label("開ける", systemImage: "lock.open")
                    }
                    .accessibilityIdentifier("settingsOpenHoldButton")
                }
            }
            #if DEBUG
            debugLog
            #endif
        } header: {
            Text("アプリのブロック")
        } footer: {
            if notificationsOff, model.isBlockingStarted {
                Text("通知がオフなので、シールドで「開く」を押したあとは自分で GhostPace を開いてください（2分以内）。")
            } else {
                Text("ゲームと SNS はいつも、集中のタイマー中はほかのアプリもブロックします。開くときは3秒長押しして、5秒待ちます。")
            }
        }
    }

    #if DEBUG
    /// 実機で流れを確かめるための記録（Debug の版だけ）
    private var debugLog: some View {
        DisclosureGroup("ブロックの記録（確認用）") {
            Text("通知：\(notificationsOff ? "オフ" : "オン")").font(.caption)
            let events = model.recentBlockEvents()
            if events.isEmpty {
                Text("まだ記録はありません").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(BlockDebugTrace.lines().reversed().enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption2.monospaced())
            }
            ForEach(events) { event in
                HStack {
                    Text(event.occurredAt, format: .dateTime.month().day().hour().minute().second())
                    Spacer()
                    Text(event.kind.rawValue + (event.reblockReason.map { "（\($0.rawValue)）" } ?? ""))
                }
                .font(.caption.monospacedDigit())
            }
        }
    }
    #endif

    @ViewBuilder
    private var statusRow: some View {
        if model.blockingAuthorization == .unavailable {
            Text("この版ではまだ使えません").foregroundStyle(.secondary)
                .accessibilityIdentifier("blockingStatus")
        } else if !model.isBlockingStarted {
            row("まだ始めていません", button: "始める") {
                Task {
                    if await model.requestBlockingAuthorization() == .approved { onSelect() }
                }
            }
        } else if !model.hasBlockSelection {
            row("ブロックするアプリを読めませんでした", button: "選ぶ") { onSelect() }
        } else if model.blockingAuthorization == .denied {
            row("Screen Time が許可されていません", button: "設定を開く") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
        } else if let until = model.unlockedUntil {
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                let minutes = max(1, Int((until.timeIntervalSince(model.clock.now()) / 60).rounded(.up)))
                row("あと\(minutes)分でブロックに戻る", button: "今すぐ戻す") { model.reblockNow() }
            }
        } else {
            Label("ブロック中", systemImage: "lock.fill")
                .accessibilityIdentifier("blockingStatus")
        }
    }

    private func row(_ text: String, button: String, action: @escaping () -> Void) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Text(text).font(.subheadline)
                Spacer()
                actionButton(button, action: action)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(text).font(.subheadline)
                actionButton(button, action: action)
            }
        }
        .accessibilityIdentifier("blockingStatus")
    }

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .fixedSize()
            .accessibilityIdentifier("blockingStatusButton")
    }
}
