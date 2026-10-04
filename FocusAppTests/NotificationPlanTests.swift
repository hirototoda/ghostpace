import Foundation
import Testing
@testable import FocusApp

/// 予約する通知（TMR-05、REV-02）。
struct NotificationPlanTests {
    private func plan(_ running: FocusSession?, now: String, enabled: Bool = true, reviewMinutes: Int = 22 * 60) -> [AppNotification] {
        NotificationPlan.make(running: running, now: jst(now), plannedEndEnabled: enabled, reviewMinutes: reviewMinutes,
                              calendar: tokyoCalendar)
    }

    private func plannedEnd(_ notifications: [AppNotification]) -> AppNotification? {
        notifications.first { $0.id == AppNotification.plannedEndID }
    }

    @Test func countdownFromBlockNotifiesAtBlockEnd() {
        var s = session("2026-10-19T11:20", nil, plannedEnd: "2026-10-19T13:00")
        s.project = ProjectOption(id: UUID(), name: "ゼミ準備", category: DefaultCategories.all[0])
        let n = plannedEnd(plan(s, now: "2026-10-19T11:30"))
        #expect(n?.trigger == .at(jst("2026-10-19T13:00")))
        #expect(n?.title == "ゼミ準備の予定の時間です")
        #expect(n?.body == "13:00 になりました。続けると、超過した分も記録されます。")
    }

    @Test func unplannedLengthMovesWithPauses() {
        // 25分のうち5分止めた → 終わりは5分後ろへ
        let s = session("2026-10-19T09:00", nil, pauses: [("2026-10-19T09:10", "2026-10-19T09:15")], plannedMinutes: 25)
        #expect(plannedEnd(plan(s, now: "2026-10-19T09:20"))?.trigger == .at(jst("2026-10-19T09:30")))
    }

    @Test func pausedOrStopwatchOrPastOrDisabledHasNoPlannedEnd() {
        let paused = session("2026-10-19T09:00", nil, pauses: [("2026-10-19T09:10", nil)], plannedMinutes: 25)
        #expect(plannedEnd(plan(paused, now: "2026-10-19T09:20")) == nil)
        let stopwatch = session("2026-10-19T09:00", nil)
        #expect(plannedEnd(plan(stopwatch, now: "2026-10-19T09:20")) == nil)
        let over = session("2026-10-19T09:00", nil, plannedMinutes: 25)
        #expect(plannedEnd(plan(over, now: "2026-10-19T09:25")) == nil)
        let running = session("2026-10-19T09:00", nil, plannedMinutes: 25)
        #expect(plannedEnd(plan(running, now: "2026-10-19T09:10", enabled: false)) == nil)
        #expect(plannedEnd(plan(nil, now: "2026-10-19T09:10")) == nil)
    }

    @Test func reviewIsDailyAtTheSetTime() {
        let review = plan(nil, now: "2026-10-19T09:10", reviewMinutes: 21 * 60 + 30).first { $0.id == AppNotification.reviewID }
        #expect(review?.trigger == .daily(minutes: 21 * 60 + 30))
        #expect(review?.title == "今日を振り返りましょう")
    }
}

@MainActor
struct AppSettingsTests {
    @Test func defaultsWhenEmpty() throws {
        let defaults = try #require(UserDefaults(suiteName: "settings-test-\(UUID().uuidString)"))
        let settings = UserDefaultsSettings(defaults: defaults)
        #expect(settings.reviewMinutes == 22 * 60)
        #expect(settings.plannedEndNotifications)
        #expect(!settings.didShowNotificationIntro)
        #expect(!settings.didRegroupDetoxCategories)
        #expect(settings.opponent == .lastWeek)
    }

    @Test func savesValues() throws {
        let suite = "settings-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = UserDefaultsSettings(defaults: defaults)
        settings.reviewMinutes = 30
        settings.plannedEndNotifications = false
        settings.didShowNotificationIntro = true
        settings.opponent = .goal
        let reopened = UserDefaultsSettings(defaults: try #require(UserDefaults(suiteName: suite)))
        #expect(reopened.reviewMinutes == 30)
        #expect(!reopened.plannedEndNotifications)
        #expect(reopened.didShowNotificationIntro)
        #expect(reopened.opponent == .goal)
        defaults.removePersistentDomain(forName: suite)
    }
}
