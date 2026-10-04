import Foundation
import UserNotifications

/// 予約する1件（UNNotificationRequest を作る前の形）。
struct PendingNotification: Equatable {
    var identifier: String
    var title: String
    var body: String
    var trigger: AppNotification.Trigger
}

/// 通知センターのうち、予約に使う部分（テストでは偽物に差し替える）。
@MainActor
protocol NotificationCenterScheduling: AnyObject {
    func removeAllPendingNotificationRequests()
    func add(_ request: PendingNotification)
}

/// 本物の通知センター。時刻はそのときのタイムゾーンで iPhone の予約に直す。
@MainActor
final class SystemNotificationCenter: NotificationCenterScheduling {
    private let center = UNUserNotificationCenter.current()
    private let calendar: () -> Calendar

    init(calendar: @escaping () -> Calendar) {
        self.calendar = calendar
    }

    func removeAllPendingNotificationRequests() {
        center.removeAllPendingNotificationRequests()
    }

    func add(_ request: PendingNotification) {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default
        content.userInfo = ["kind": request.identifier]
        let trigger: UNNotificationTrigger
        switch request.trigger {
        case .at(let date):
            let parts = calendar().dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        case .daily(let minutes):
            trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: minutes / 60, minute: minutes % 60),
                                                    repeats: true)
        }
        center.add(UNNotificationRequest(identifier: request.identifier, content: content, trigger: trigger))
    }
}

/// UNUserNotificationCenter で通知を予約する。
@MainActor
final class UserNotificationScheduler: NotificationScheduling {
    private let center: NotificationCenterScheduling
    private let calendar: () -> Calendar
    /// 最後に予約した内容とタイムゾーン（同じなら予約し直さない）
    private var last: (notifications: [AppNotification], timeZone: TimeZone)?

    init(center: NotificationCenterScheduling, calendar: @escaping () -> Calendar) {
        self.center = center
        self.calendar = calendar
    }

    convenience init(calendar: @escaping () -> Calendar) {
        self.init(center: SystemNotificationCenter(calendar: calendar), calendar: calendar)
    }

    func authorization() async -> NotificationAuthorization {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        default: .authorized
        }
    }

    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// 予約をすべて取り消してから入れ直す。計画ブロックごとの通知（TMR-12）は id が変わり、
    /// 前の起動で予約したものも残っているので、一覧にない id を選んで消す方法では取り残す（2026-10-04 に直した不具合）
    func replaceAll(with notifications: [AppNotification]) {
        let timeZone = calendar().timeZone
        if let last, last.notifications == notifications, last.timeZone == timeZone { return }
        last = (notifications, timeZone)
        center.removeAllPendingNotificationRequests()
        for notification in notifications {
            center.add(PendingNotification(identifier: notification.id, title: notification.title, body: notification.body,
                                           trigger: notification.trigger))
        }
    }
}
