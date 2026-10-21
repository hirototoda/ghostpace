import Foundation

/// 出す通知（TMR-05、REV-02）。
struct AppNotification: Hashable {
    enum Trigger: Hashable {
        /// その時刻に1回
        case at(Date)
        /// 毎日その時刻（0:00 からの分）
        case daily(minutes: Int)
    }

    var id: String
    var title: String
    var body: String
    var trigger: Trigger

    static let plannedEndID = "plannedEnd"
    static let blockStartID = "blockStart"
    /// 振り返り（REV-02）。毎日のものは `review`、1回ずつのものは `review-<日の名前>`
    static let reviewID = "review"
    /// 計画ブロックの前の通知（TMR-12）。ブロックごとに `blockNotice-<ブロックのID>`
    static let blockNoticePrefix = "blockNotice-"
    static func blockNoticeID(_ blockId: UUID) -> String { blockNoticePrefix + blockId.uuidString }

    /// 押したときに何を開くかの種類（振り返りの1回ずつの予約も振り返り）
    static func kind(of id: String) -> String { id.hasPrefix(reviewID) ? reviewID : id }

    /// iPhone が一度に予約できる通知の数
    static let systemLimit = 64
}

/// 振り返りの通知の予約（REV-02、review.md「通知」）。その日の区切りの時刻に出す。
/// 区切りが変わらない間は毎日の予約1つ。区切りを変えた・移した日など、日によって時刻や文面が変わる間は、
/// これから7日分を1回ずつ予約する（毎日の予約は日ごとに変えられないため）。次に開いたときに毎日の予約に戻る
enum ReviewSchedule: Hashable {
    /// 毎日その時刻（0:00 からの分）に「今日の結果が確定しました」
    case daily(minutes: Int)
    /// 1回ずつ
    case shots([Shot])

    struct Shot: Hashable {
        var dayKey: String
        var at: Date
        /// 区切りの履歴より前の日（移した日）。確定は朝4:00なので今までの文面
        var isLegacy: Bool
    }

    /// 1回ずつ予約する日数
    static let shotDays = 7

    static func make(boundary: DayBoundary, now: Date) -> ReviewSchedule {
        let today = boundary.day(containing: now)
        let days = (0..<shotDays).map { boundary.day($0, from: today) }
        let latest = boundary.latestEndMinutes
        if days.allSatisfy({ !$0.isLegacy && $0.endMinutes == latest }) { return .daily(minutes: latest % 1440) }
        return .shots(days.compactMap { day in
            // 移した日は今までの初期値の 22:00 に（Q48）
            let at = day.isLegacy ? boundary.wallClock(day.date, minutes: DayBoundary.defaultEndMinutes) : day.end
            return at > now ? Shot(dayKey: day.key, at: at, isLegacy: day.isLegacy) : nil
        })
    }
}

/// 計画ブロックの前の通知（TMR-12）の材料。
struct BlockNotice: Hashable {
    /// 何分前に知らせるか（0 はちょうど、nil はオフ）
    var leadMinutes: Int?
    /// 確定した今日の計画のブロック（下書き・計画しない日は空）
    var blocks: [PlanBlockSummary]
    /// もう始めたブロック（前倒しを含む）
    var startedBlockIds: Set<UUID>

    /// 設定の選択肢（オフ・ちょうど・5・10・15分前）。初期は5分前
    static let choices: [Int?] = [nil, 0, 5, 10, 15]
    static let defaultLeadMinutes = 5
    /// iPhone の予約の上限（64件）より少なく。振り返りなどの分を残す
    static let maxCount = 60
}

/// 今の状態から、予約しておく通知を決める（docs/product/features/focus-timer.md・review.md）。
enum NotificationPlan {
    /// - planBlocks: その日の計画ブロック。計画外のタイマー中に次のブロックの時刻が来たら知らせる（TMR-11）
    /// - blockNotice: 計画ブロックの前の通知（TMR-12）
    /// - review: 振り返りの通知（REV-02、その日の区切りの時刻）
    static func make(running: FocusSession?, now: Date, plannedEndEnabled: Bool, review: ReviewSchedule,
                     calendar: Calendar, planBlocks: [PlanBlockSummary] = [], blockNotice: BlockNotice? = nil) -> [AppNotification] {
        var result: [AppNotification] = []
        var formatted = Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
            .locale(Locale(identifier: "ja_JP"))
        formatted.timeZone = calendar.timeZone
        // 予定の時間：カウントダウンで、一時停止中でなく、予定の時刻がまだ来ていないときだけ
        if plannedEndEnabled, let session = running, !session.isPaused, let end = session.plannedEnd(at: now), end > now {
            result.append(AppNotification(id: AppNotification.plannedEndID, title: "\(session.title)の予定の時間です",
                                           body: "\(end.formatted(formatted)) になりました。続けると、超過した分も記録されます。",
                                           trigger: .at(end)))
        }
        // 計画の時刻：計画外のタイマー中に、次の計画ブロックが始まる時刻（一時停止中も出す。ゲーム・SNS の時間は除く）
        if plannedEndEnabled, let session = running, session.planBlockId == nil,
           let block = planBlocks.filter({ $0.start > now && !$0.category.isUnblock }).min(by: { $0.start < $1.start }) {
            result.append(AppNotification(id: AppNotification.blockStartID, title: "\(block.title)の時間です",
                                          body: "\(block.start.formatted(formatted)) になりました。開いて切り替えると、ここから\(block.title)の記録になります。",
                                          trigger: .at(block.start)))
        }
        if let blockNotice {
            result += notices(blockNotice, running: running, now: now, formatted: formatted, taken: result)
        }
        switch review {
        case .daily(let minutes):
            result.append(reviewNotification(id: AppNotification.reviewID, isLegacy: false, trigger: .daily(minutes: minutes)))
        case .shots(let shots):
            // 予約の上限（64件）に収まる分だけ（近い日から）
            let room = max(1, AppNotification.systemLimit - result.count)
            result += shots.prefix(room).map {
                reviewNotification(id: "\(AppNotification.reviewID)-\($0.dayKey)", isLegacy: $0.isLegacy, trigger: .at($0.at))
            }
        }
        return result
    }

    /// 振り返りの通知の文面。区切りの後は「今日の結果が確定しました」（2026-10-21 オーナー決定、本文は Claude 補足 Q49）。
    /// 移した日（確定は朝4:00のまま）は今までの文面（Q48）
    private static func reviewNotification(id: String, isLegacy: Bool, trigger: AppNotification.Trigger) -> AppNotification {
        isLegacy
            ? AppNotification(id: id, title: String(localized: "今日を振り返りましょう"),
                              body: String(localized: "今日の集中と、朝の計画とのズレを見返して、明日の計画を立てましょう。"), trigger: trigger)
            : AppNotification(id: id, title: String(localized: "今日の結果が確定しました"),
                              body: String(localized: "先週の自分との勝ち負けを見て、明日の計画を立てましょう。"), trigger: trigger)
    }
}

extension NotificationPlan {
    /// 計画ブロックの前の通知（TMR-12、docs/product/features/focus-timer.md）
    /// - taken: ほかに予約する通知。「ちょうど」で同じ時刻に出るものがあれば、そちらだけにする
    private static func notices(_ notice: BlockNotice, running: FocusSession?, now: Date, formatted: Date.FormatStyle,
                                taken: [AppNotification]) -> [AppNotification] {
        guard let lead = notice.leadMinutes else { return [] }
        let takenTimes = Set(taken.compactMap { notification -> Date? in
            if case .at(let date) = notification.trigger { return date }
            return nil
        })
        let candidates = notice.blocks
            .filter { !$0.category.isUnblock && !notice.startedBlockIds.contains($0.id) }
            .map { (block: $0, at: $0.start.addingTimeInterval(-Double(lead * 60))) }
            .filter { $0.at > now && !(lead == 0 && takenTimes.contains($0.at)) }
            .sorted { $0.at < $1.at }
            .prefix(BlockNotice.maxCount)
        return candidates.map { block, at in
            let time = block.start.formatted(formatted)
            if lead == 0 {
                return AppNotification(id: AppNotification.blockNoticeID(block.id), title: "\(block.title)の時間です",
                                       body: "\(time) になりました。開いて始めましょう。", trigger: .at(at))
            }
            let body = running == nil && offersEarlyStart(block, at: at, in: notice.blocks)
                ? "\(time) から。開いて［今から始める］で記録できます。"
                : "\(time) から。開いて始めましょう。"
            return AppNotification(id: AppNotification.blockNoticeID(block.id), title: "まもなく\(block.title)",
                                   body: body, trigger: .at(at))
        }
    }

    /// その時刻のホームに、このブロックの［今から始める］が出るか（TMR-10 と同じ条件：今の計画ブロックがなく、次がこのブロック）
    private static func offersEarlyStart(_ block: PlanBlockSummary, at time: Date, in blocks: [PlanBlockSummary]) -> Bool {
        guard !blocks.contains(where: { $0.start <= time && time < $0.end }) else { return false }
        return blocks.filter { $0.start > time }.min { $0.start < $1.start }?.id == block.id
    }
}

enum NotificationAuthorization: Hashable {
    case notDetermined
    case denied
    case authorized
}

/// 通知の予約の窓口（本物は UserNotificationScheduler。テストでは差し替える）。
@MainActor
protocol NotificationScheduling: AnyObject {
    func authorization() async -> NotificationAuthorization
    /// iPhone の許可を聞く。許可されたら true
    func requestAuthorization() async -> Bool
    /// 予約を `notifications` にそろえる（同じ id は置き換え、ないものは取り消す）
    func replaceAll(with notifications: [AppNotification])
}

/// 何もしない（見本データ・UI テスト用）。
@MainActor
final class NoNotifications: NotificationScheduling {
    var status: NotificationAuthorization
    private(set) var scheduled: [AppNotification] = []
    private(set) var requestCount = 0

    init(status: NotificationAuthorization = .notDetermined) {
        self.status = status
    }

    func authorization() async -> NotificationAuthorization { status }

    func requestAuthorization() async -> Bool {
        requestCount += 1
        if status == .notDetermined { status = .authorized }
        return status == .authorized
    }

    func replaceAll(with notifications: [AppNotification]) {
        scheduled = notifications
    }
}
