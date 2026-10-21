import Foundation
import Testing
@testable import FocusApp

/// 予約する通知（TMR-05、REV-02）。
struct NotificationPlanTests {
    private func plan(_ running: FocusSession?, now: String, enabled: Bool = true,
                      review: ReviewSchedule = .daily(minutes: 22 * 60)) -> [AppNotification] {
        NotificationPlan.make(running: running, now: jst(now), plannedEndEnabled: enabled, review: review,
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

    /// 1b-76：区切りが変わらない間は、毎日その日の区切りの時刻に「今日の結果が確定しました」
    @Test func reviewIsDailyAtTheBoundary() {
        let schedule = ReviewSchedule.make(boundary: boundary([("2026-10-01", 1320)]), now: jst("2026-10-21T09:10"))
        #expect(schedule == .daily(minutes: 1320))
        let review = plan(nil, now: "2026-10-21T09:10", review: schedule).first { $0.id == AppNotification.reviewID }
        #expect(review?.trigger == .daily(minutes: 22 * 60))
        #expect(review?.title == "今日の結果が確定しました")
        #expect(review?.body == "先週の自分との勝ち負けを見て、明日の計画を立てましょう。")
        // 夜中の区切り（翌1:00）は 1:00 に
        #expect(ReviewSchedule.make(boundary: boundary([("2026-10-01", 1500)]), now: jst("2026-10-21T09:10"))
                == .daily(minutes: 60))
    }

    /// 1b-76：区切りを変えたら、通知は次の日から新しい時刻（今日の分は今の区切りの時刻）
    @Test func changedBoundaryNotifiesTodayAtTheOldTimeThenTheNewTime() {
        let b = boundary([("2026-10-01", 1320), ("2026-10-22", 1380)])
        let schedule = ReviewSchedule.make(boundary: b, now: jst("2026-10-21T15:00"))
        let reviews = plan(nil, now: "2026-10-21T15:00", review: schedule).filter { $0.id.hasPrefix(AppNotification.reviewID) }
        #expect(reviews.first?.trigger == .at(jst("2026-10-21T22:00")))
        #expect(reviews.dropFirst().first?.trigger == .at(jst("2026-10-22T23:00")))
        #expect(reviews.dropFirst(2).first?.trigger == .at(jst("2026-10-23T23:00")))
        #expect(reviews.allSatisfy { $0.title == "今日の結果が確定しました" })
        #expect(Set(reviews.map(\.id)).count == reviews.count)
        #expect(reviews.allSatisfy { AppNotification.kind(of: $0.id) == AppNotification.reviewID })
        // 22:00 を過ぎたら今日の分はもう出さず、この先は変わらないので毎日 23:00 の予約に戻る
        let late = ReviewSchedule.make(boundary: b, now: jst("2026-10-21T22:30"))
        #expect(late == .daily(minutes: 23 * 60))
    }

    /// 1b-79：移した日（まだ朝4:00区切り）は 22:00 に今までの文面「今日を振り返りましょう」、次の日から区切りの時刻に新しい文面
    @Test func migrationDayReviewNoticeIsRescheduled() {
        let b = boundary([("2026-10-23", 1320)])
        let schedule = ReviewSchedule.make(boundary: b, now: jst("2026-10-22T15:00"))
        let reviews = plan(nil, now: "2026-10-22T15:00", review: schedule).filter { $0.id.hasPrefix(AppNotification.reviewID) }
        #expect(reviews.first?.trigger == .at(jst("2026-10-22T22:00")))
        #expect(reviews.first?.title == "今日を振り返りましょう")
        #expect(reviews.first?.body == "今日の集中と、朝の計画とのズレを見返して、明日の計画を立てましょう。")
        #expect(reviews.dropFirst().first?.trigger == .at(jst("2026-10-23T22:00")))
        #expect(reviews.dropFirst().first?.title == "今日の結果が確定しました")
        // 前の版の毎日の予約（id が review）は残さない
        #expect(!reviews.contains { $0.trigger == .daily(minutes: 22 * 60) })
        // 次の日に開けば毎日の予約に戻る
        #expect(ReviewSchedule.make(boundary: b, now: jst("2026-10-23T09:00")) == .daily(minutes: 1320))
    }

    /// 予約は64件まで（振り返りの1回ずつの予約は、ほかの予約の残りの数まで）
    @Test func reviewShotsFitTheLimit() {
        let b = boundary([("2026-10-01", 1320), ("2026-10-22", 1380)])
        let blocks = (0..<60).map { index in
            PlanBlockSummary(id: UUID(), category: DefaultCategories.all[0], project: nil, title: "勉強", categoryName: "勉強",
                             start: jst("2026-10-21T16:00").addingTimeInterval(Double(index * 60)),
                             end: jst("2026-10-21T16:00").addingTimeInterval(Double(index * 60 + 30)), countsAsFocus: true)
        }
        let all = NotificationPlan.make(running: nil, now: jst("2026-10-21T15:00"), plannedEndEnabled: true,
                                        review: ReviewSchedule.make(boundary: b, now: jst("2026-10-21T15:00")), calendar: tokyoCalendar,
                                        blockNotice: BlockNotice(leadMinutes: 5, blocks: blocks, startedBlockIds: []))
        #expect(all.count <= 64)
        #expect(all.contains { $0.id.hasPrefix(AppNotification.reviewID) })
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
