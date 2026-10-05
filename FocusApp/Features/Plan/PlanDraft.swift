import Foundation

/// 計画ブロックの編集中の値。
struct PlanBlockDraft: Identifiable, Hashable {
    var id = UUID()
    var start: Date
    var minutes: Int
    var category: CategoryOption
    var project: ProjectOption?

    var end: Date { start.addingTimeInterval(Double(minutes * 60)) }
    /// ホームなどに出す名前。ブロック名がなければカテゴリ名
    var title: String { project?.name ?? category.name }
    /// ゲーム・SNS の時間（BLK-10）。集中にもデトックスにも数えず、タイマーは始めない
    var isUnblock: Bool { category.isUnblock }

    /// 新しいゲーム・SNS の時間（長さは30分で決まり）
    static func unblock(start: Date) -> PlanBlockDraft {
        PlanBlockDraft(start: start, minutes: PlanDraft.unblockMinutes, category: .gameSNS)
    }

    func overlaps(_ other: PlanBlockDraft) -> Bool {
        id != other.id && start < other.end && other.start < end
    }
}

/// 1日の計画の編集中の値（PLN-02）。確定するとスナップショットとして保存する（PLN-03）。
struct PlanDraft: Hashable {
    static let defaultMinutes = 60
    static let minuteStep = 5
    /// ゲーム・SNS の時間の長さ（分）と、1日に置ける数（BLK-10、2026-10-01 オーナー決定）
    static let unblockMinutes = 30
    static let unblockLimit = PlanLimits.unblockPerDay

    var blocks: [PlanBlockDraft] = []
    /// 手で決めた今日の目標（GHO-10）。nil なら計画の集中の合計に合わせて動く（保存データ第2版）
    var goalSeconds: Int? = nil

    var sortedBlocks: [PlanBlockDraft] { blocks.sorted { $0.start < $1.start } }

    /// 新しいブロックの開始時刻。最後のブロックの終わり。なければ今（5分単位に切り上げ）。
    func nextStart(now: Date) -> Date {
        if let last = blocks.max(by: { $0.end < $1.end }) { return last.end }
        return Self.rounded(now, .up)
    }

    /// 近い5分に合わせる。開始時刻は5分刻みで選ぶので、前の1分刻みで入れた時刻は編集を開いたときに合わせる
    static func roundedToStep(_ date: Date) -> Date { rounded(date, .toNearestOrAwayFromZero) }

    private static func rounded(_ date: Date, _ rule: FloatingPointRoundingRule) -> Date {
        let step = Double(minuteStep * 60)
        return Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / step).rounded(rule) * step)
    }

    /// 保存できない理由。保存できるなら nil。
    func problem(with block: PlanBlockDraft, dayStart: Date) -> String? {
        if block.isUnblock, blocks.filter({ $0.isUnblock && $0.id != block.id }).count >= Self.unblockLimit {
            return "ゲーム・SNS の時間は1日\(Self.unblockLimit)つまでです"
        }
        if let other = blocks.first(where: block.overlaps) {
            return "\(timeRange(other.start, other.end)) の\(other.title)と重なっています"
        }
        if block.start < dayStart || block.end > dayStart.addingTimeInterval(24 * 3600) {
            return "1日の区切り（朝4:00）をまたいでいます"
        }
        return nil
    }

    mutating func upsert(_ block: PlanBlockDraft) {
        if let index = blocks.firstIndex(where: { $0.id == block.id }) {
            blocks[index] = block
        } else {
            blocks.append(block)
        }
    }

    mutating func remove(id: PlanBlockDraft.ID) {
        blocks.removeAll { $0.id == id }
    }

    /// 今その中にあるゲーム・SNS の時間を消す：今の時刻で終える（そこまでは使った時間として残す。BLK-10）。1分にならなければ消す
    mutating func endUnblock(id: PlanBlockDraft.ID, now: Date) {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        let minutes = Int(now.timeIntervalSince(blocks[index].start) / 60)
        if minutes >= 1 { blocks[index].minutes = minutes } else { blocks.remove(at: index) }
    }

    /// 確定した日の、ゲーム・SNS の時間の今の段階（BLK-10「確定したあとの変更」）
    enum UnblockPhase { case upcoming, ongoing, past }

    static func unblockPhase(_ block: PlanBlockDraft, now: Date) -> UnblockPhase {
        if block.end <= now { return .past }
        return block.start <= now ? .ongoing : .upcoming
    }

    /// 確定した日（計画のタブ）の、終わったゲーム・SNS の時間。編集も削除もできない
    static func isLocked(_ block: PlanBlockDraft, confirmedDay: Bool, now: Date) -> Bool {
        confirmedDay && block.isUnblock && unblockPhase(block, now: now) == .past
    }

    /// 確定した日の、今その中にあるゲーム・SNS の時間（開始は変えられず、消すと今で終える）
    static func isOngoing(_ block: PlanBlockDraft, confirmedDay: Bool, now: Date) -> Bool {
        confirmedDay && block.isUnblock && unblockPhase(block, now: now) == .ongoing
    }

    /// 消す（BLK-10「確定したあとの変更」）。確定した日のゲーム・SNS の時間は、まだなら消す、今その中なら今で終える、
    /// 終わったものは消さない。ほかのブロックと、下書き・テンプレートでは消す
    mutating func delete(id: PlanBlockDraft.ID, confirmedDay: Bool, now: Date) {
        guard let block = blocks.first(where: { $0.id == id }) else { return }
        guard confirmedDay, block.isUnblock else { return remove(id: id) }
        switch Self.unblockPhase(block, now: now) {
        case .upcoming: remove(id: id)
        case .ongoing: endUnblock(id: id, now: now)
        case .past: break
        }
    }


    /// 日中にテンプレートで進める（PLN-07）：今から先だけを置き換える。
    /// 始まった・終わったブロックは残し、まだ始まっていないブロックを外して、テンプレートのうち今より後に始まり、
    /// 残したブロックと重ならないものを入れる。目標はそのまま。
    /// ゲーム・SNS の時間（BLK-10）もテンプレートのものに置き換える（1日3つまで）。
    /// これからの習慣どおりのブロック（PLN-08）も残す
    func replacingFuture(with template: PlanDraft, now: Date, keeping habits: PlanDraft = PlanDraft()) -> PlanDraft {
        var result = self
        let kept = habitBlocks(habits)
        result.blocks = blocks.filter { block in block.start <= now || kept.contains { $0.id == block.id } }
        for block in template.sortedBlocks where block.start > now
            && !result.blocks.contains(where: { $0.matches(block) || block.overlaps($0) }) {
            if block.isUnblock, result.unblockCount >= Self.unblockLimit { continue }
            result.blocks.append(block)
        }
        return result
    }

    /// 前の日から引き継ぐゲーム・SNS の時間（BLK-10）。時:分をこの日に当てはめる（0:00〜3:59 は暦の翌日）
    /// 暦で日をずらすので、夏時間をまたいでも同じ時刻になる
    static func carriedUnblocks(_ previous: [PlanBlockDraft], previousDayStart: Date, dayStart: Date,
                                calendar: Calendar) -> [PlanBlockDraft] {
        let days = calendar.dateComponents([.day], from: previousDayStart, to: dayStart).day ?? 0
        return previous.filter(\.isUnblock).sorted { $0.start < $1.start }.prefix(unblockLimit).compactMap {
            calendar.date(byAdding: .day, value: days, to: $0.start).map { .unblock(start: $0) }
        }
    }

    var focusSeconds: Int { blocks.filter(\.category.countsAsFocus).reduce(0) { $0 + $1.minutes * 60 } }
    /// ゲーム・SNS の時間は入れない（BLK-10）
    var detoxSeconds: Int { blocks.filter(\.category.countsAsDetox).reduce(0) { $0 + $1.minutes * 60 } }

    /// ゲーム・SNS の時間の数と、あといくつ置けるか
    var unblockCount: Int { blocks.filter(\.isUnblock).count }
    var remainingUnblocks: Int { max(0, Self.unblockLimit - unblockCount) }

    var summaries: [PlanBlockSummary] {
        sortedBlocks.map {
            PlanBlockSummary(id: $0.id, category: $0.category, project: $0.project, title: $0.title,
                             categoryName: $0.category.name, start: $0.start, end: $0.end,
                             countsAsFocus: $0.category.countsAsFocus)
        }
    }
}
