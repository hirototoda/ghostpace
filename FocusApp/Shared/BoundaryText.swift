import Foundation

/// 一日の区切りの表示（GHO-17、settings.md「一日の区切り」）
enum BoundaryText {
    /// 区切りの時刻（日の名前の日の 0:00 からの分）。22:00、夜中は「翌1:00」
    static func time(_ minutes: Int) -> String {
        let rest = ((minutes % 1440) + 1440) % 1440
        let text = String(format: "%d:%02d", rest / 60, rest % 60)
        return minutes >= 1440 ? String(localized: "翌\(text)") : text
    }

    /// 一日の長さ（「25時間」「24時間30分」）
    static func length(hours: Double) -> String {
        let minutes = Int((hours * 60).rounded())
        return minutes % 60 == 0 ? String(localized: "\(minutes / 60)時間")
            : String(localized: "\(minutes / 60)時間\(minutes % 60)分")
    }

    /// 区切りを変えたときの行の下の知らせ（Q48）。例「明日から 23:00 で区切ります（今日は 22:00 で確定します）」
    static func pending(_ change: PendingBoundaryChange) -> String {
        String(localized: "明日から \(time(change.tomorrowEndMinutes)) で区切ります（今日は \(time(change.todayEndMinutes)) で確定します）")
    }

    /// 明日が24時間でないときの知らせ。24時間なら nil。例「明日は25時間です」
    static func tomorrowLength(_ change: PendingBoundaryChange) -> String? {
        abs(change.tomorrowHours - 24) < 0.01 ? nil : String(localized: "明日は\(length(hours: change.tomorrowHours))です")
    }
}
