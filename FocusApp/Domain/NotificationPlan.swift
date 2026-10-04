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
    static let reviewID = "review"
    /// 計画ブロックの前の通知（TMR-12）。ブロックごとに `blockNotice-<ブロックのID>`
    static let blockNoticePrefix = "blockNotice-"
    static func blockNoticeID(_ blockId: UUID) -> String { blockNoticePrefix + blockId.uuidString }
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
    static func make(running: FocusSession?, now: Date, plannedEndEnabled: Bool, reviewMinutes: Int,
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
        result.append(AppNotification(id: AppNotification.reviewID, title: "今日を振り返りましょう",
                                      body: "今日の集中と、朝の計画とのズレを見返して、明日の計画を立てましょう。",
                                      trigger: .daily(minutes: reviewMinutes)))
        return result
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
