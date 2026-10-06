#if DEBUG
import SwiftUI

/// ロック画面と画面上部の見本（画面の確認用、`-liveGallery`）。ロック画面に似せた背景に、場面ごとの表示を並べる。
struct LiveActivityGallery: View {
    @Environment(\.clock) private var clock

    private struct Scene: Identifiable {
        var id: String
        var activity: TimerActivity
    }

    /// 見本の場面：計画ブロックの残り／超過／一時停止中／ストップウォッチ
    private func scenes(now: Date) -> [Scene] {
        let study = CategoryOption(name: "勉強", countsAsFocus: true)
        let reading = CategoryOption(name: "運動", countsAsFocus: false)
        let seminar = ProjectOption(id: UUID(), name: "ゼミ準備", category: study)
        func session(_ category: CategoryOption, _ project: ProjectOption?, startedAgo: Double, plannedEnd: Double? = nil,
                     minutes: Int? = nil, pausedAgo: Double? = nil) -> FocusSession {
            FocusSession(id: UUID(), dayKey: "", category: category, project: project, planBlockId: nil,
                         startAt: now.addingTimeInterval(-startedAgo), endAt: nil,
                         plannedEndAt: plannedEnd.map { now.addingTimeInterval($0) }, plannedDurationSec: minutes.map { $0 * 60 },
                         pauses: pausedAgo.map { [PauseInterval(start: now.addingTimeInterval(-$0), end: nil)] } ?? [])
        }
        // ロック画面の数字は iPhone の時計で数えるので、見本の時計（-fixedNow）との差だけずらす
        let shift = SystemClock().now().timeIntervalSince(now).rounded()
        func make(_ id: String, _ s: FocusSession) -> Scene {
            var activity = TimerActivity.make(s, now: now, timeZone: .current)
            activity.state = activity.state.shifted(by: shift)
            return Scene(id: id, activity: activity)
        }
        return [
            make("残り", session(study, seminar, startedAgo: 20 * 60, plannedEnd: 100 * 60)),
            make("超過", session(study, nil, startedAgo: 28 * 60 + 12, minutes: 25)),
            make("一時停止中", session(study, nil, startedAgo: 15 * 60, minutes: 25, pausedAgo: 5 * 60)),
            make("ストップウォッチ", session(reading, nil, startedAgo: 23 * 60 + 10)),
        ]
    }

    var body: some View {
        let now = clock.now()
        let scenes = scenes(now: now)
        ScrollView {
            VStack(spacing: 14) {
                islandMock(scenes[0].activity)
                    .padding(.top, 44)
                Text(now, format: .dateTime.hour().minute())
                    .font(.system(size: 72, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.bottom, 8)
                ForEach(scenes) { scene in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(scene.id).font(.caption.bold()).foregroundStyle(.white.opacity(0.8))
                        TimerLockScreenView(attributes: scene.activity.attributes, state: scene.activity.state)
                            .padding(16)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
                    }
                }
            }
            .padding(.horizontal, 12)
        }
        .background(LinearGradient(colors: [.indigo, .purple.opacity(0.8), .black], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea())
    }

    /// 画面上部（Dynamic Island）のふだんの小さな表示に似せたもの
    private func islandMock(_ activity: TimerActivity) -> some View {
        HStack {
            TimerProgressRing(progress: activity.state.progress, tint: activity.attributes.tint, lineWidth: 3)
                .frame(width: 20, height: 20)
                .font(.caption)
            Spacer(minLength: 90)
            TimerReadingText(reading: activity.state.reading)
                .font(.callout.bold().monospacedDigit())
                .foregroundStyle(activity.attributes.tint)
                .multilineTextAlignment(.trailing)
                .frame(minWidth: 40, maxWidth: 80, alignment: .trailing)
                .dynamicTypeSize(...DynamicTypeSize.large)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Capsule().fill(.black))
        .fixedSize()
        .environment(\.colorScheme, .dark)
    }
}
#endif
