import Foundation
import SwiftData

/// `-seedDemoData [場面]` の場面（docs/plan/recording-spec.md）。
enum DemoScene: String, CaseIterable, Hashable {
    /// 確定した計画＋今の時刻までのセッション
    case day
    /// 今日はまだ何もない（朝の計画が出る）
    case morning
    /// 今日は計画しない日
    case noplan
    /// day と同じ＋今の計画ブロックから23分前に開始して実行中
    case running
    /// day と同じ＋5時間前に計画外25分で開始したまま（止め忘れ）
    case forgot
    /// 先週の記録がない（使い始めの週）
    case firstweek
    /// 朝の計画の下書きに、ゲーム・SNS の時間（20:00・20:30）が入っている（BLK-10）
    case gamePlan
    /// day と同じ＋35分前に計画外（勉強・60分）で開始したまま、その後に計画ブロックの時刻が来た（TMR-11）
    case offPlanAtBlock

    var label: String {
        switch self {
        case .day: "昼"
        case .morning: "朝の計画"
        case .noplan: "計画なし"
        case .running: "タイマー実行中"
        case .forgot: "止め忘れ"
        case .firstweek: "先週のデータなし"
        case .gamePlan: "ゲーム・SNS の時間"
        case .offPlanAtBlock: "計画外のまま計画の時刻"
        }
    }
}

/// 検証用のデモデータ。乱数は使わず、日付から決まる値にする（同じ時刻なら同じ中身）。
@MainActor
enum DemoData {
    static let pastDays = 21

    private struct Item {
        var hour: Int, minute: Int, minutes: Int
        var category: Int
        var project: String?
        /// 開始から何分後に何分一時停止したか
        var pause: (after: Int, minutes: Int)?
    }

    /// 計画（7:30 読書、9:00 英語、11:00 ゼミ準備、14:00 卒論、16:00 運動、19:00 読書）
    private static let planItems = [
        Item(hour: 7, minute: 30, minutes: 60, category: 2),
        Item(hour: 9, minute: 0, minutes: 90, category: 0, project: "英語"),
        Item(hour: 11, minute: 0, minutes: 120, category: 0, project: "ゼミ準備"),
        Item(hour: 14, minute: 0, minutes: 120, category: 1, project: "卒論"),
        Item(hour: 16, minute: 0, minutes: 60, category: 5),
        Item(hour: 19, minute: 0, minutes: 60, category: 2),
    ]

    /// 今日のセッション
    private static let todayItems = [
        Item(hour: 7, minute: 30, minutes: 45, category: 2),
        Item(hour: 8, minute: 15, minutes: 30, category: 4),
        Item(hour: 9, minute: 0, minutes: 45, category: 0, project: "英語", pause: (after: 20, minutes: 5)),
        Item(hour: 14, minute: 0, minutes: 100, category: 1, project: "卒論"),
        Item(hour: 16, minute: 0, minutes: 50, category: 5),
        Item(hour: 19, minute: 10, minutes: 50, category: 2),
        Item(hour: 20, minute: 30, minutes: 40, category: 0),
    ]

    /// 過去の日のセッションの元
    private static let pastItems = [
        Item(hour: 8, minute: 0, minutes: 40, category: 0, project: "英語"),
        Item(hour: 9, minute: 30, minutes: 25, category: 0),
        Item(hour: 12, minute: 0, minutes: 30, category: 4),
        Item(hour: 13, minute: 0, minutes: 120, category: 1, project: "卒論"),
        Item(hour: 17, minute: 0, minutes: 60, category: 2),
        Item(hour: 20, minute: 0, minutes: 90, category: 0, project: "ゼミ準備"),
    ]

    /// 見本のブロックの記録：ずっと前から始めていて、今日は 10:40 に15分・13:20 に10分（開けた 25分（2回））、
    /// 過去の日は日によって0〜2回開けた（DTX-05）。今より後の記録は入れない
    static func blockEvents(_ scene: DemoScene, now: Date, calendar: Calendar) -> [BlockEvent] {
        let zone = calendar.timeZone.identifier
        var events = [BlockEvent(occurredAt: Date(timeIntervalSinceReferenceDate: 0), timeZoneId: zone, kind: .started)]
        let todayStart = DayBoundary.dayStart(containing: now, calendar: calendar)
        func unlock(_ dayStart: Date, hour: Int, minute: Int, minutes: Int) {
            guard let start = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: dayStart), start < now else { return }
            events.append(BlockEvent(occurredAt: start, timeZoneId: zone, kind: .unlocked, unlockMinutes: minutes))
            let end = start.addingTimeInterval(Double(minutes * 60))
            if end <= now { events.append(BlockEvent(occurredAt: end, timeZoneId: zone, kind: .reblocked)) }
        }
        unlock(todayStart, hour: 10, minute: 40, minutes: 15)
        unlock(todayStart, hour: 13, minute: 20, minutes: 10)
        if scene != .firstweek {
            for day in 1...pastDays {
                guard let dayStart = calendar.date(byAdding: .day, value: -day, to: todayStart) else { continue }
                if day % 3 != 0 { unlock(dayStart, hour: 12, minute: 30, minutes: 20 + day % 4 * 5) }
                if day % 2 == 1 { unlock(dayStart, hour: 21, minute: 10, minutes: 15) }
            }
        }
        return events
    }

    /// - goalMinutes: 今日の計画の目標（`-goalMinutes`）。nil なら計画の集中の合計
    static func seed(_ scene: DemoScene, into store: SwiftDataStore, calendar: Calendar, goalMinutes: Int? = nil) throws {
        try store.seedDefaultsIfNeeded()
        let categories = try store.categories()
        var projects: [String: ProjectOption] = [:]
        for (name, category) in [("英語", 0), ("ゼミ準備", 0), ("卒論", 1)] {
            projects[name] = try store.createProject(name: name, category: categories[category])
        }
        let context = store.context
        let timeZone = calendar.timeZone
        let now = store.clock.now()
        let todayStart = DayBoundary.dayStart(containing: now, calendar: calendar)

        func time(_ dayStart: Date, _ item: Item, shift: Int = 0) -> Date {
            dayStart.addingTimeInterval(Double((item.hour - DayBoundary.hour) * 3600 + (item.minute + shift) * 60))
        }
        func plan(dayStart: Date) -> PlanDraft {
            PlanDraft(blocks: planItems.map {
                PlanBlockDraft(start: time(dayStart, $0), minutes: $0.minutes, category: categories[$0.category],
                               project: $0.project.flatMap { projects[$0] })
            })
        }
        func insertSession(_ item: Item, start: Date, end: Date?, plannedEndAt: Date? = nil, plannedDurationSec: Int? = nil,
                           planBlockId: UUID? = nil) {
            let pauses: [PauseInterval] = item.pause.map { pause in
                let from = start.addingTimeInterval(Double(pause.after * 60))
                return [PauseInterval(start: from, end: from.addingTimeInterval(Double(pause.minutes * 60)))]
            } ?? []
            let record = FocusSessionRecord(
                dayKey: DayBoundary.dayKey(containing: start, calendar: calendar), timeZoneId: timeZone.identifier,
                planBlockId: planBlockId, categoryId: categories[item.category].id,
                countsAsFocus: categories[item.category].countsAsFocus,
                projectId: item.project.flatMap { projects[$0]?.id }, startAt: start,
                plannedEndAt: plannedEndAt, plannedDurationSec: plannedDurationSec, at: start)
            record.endAt = end
            // 一時停止は記録の終わり（切った後）の中に収める
            let limit = end ?? now
            record.pausesJSON = PauseInterval.encode(pauses.filter { $0.start < limit }.map {
                PauseInterval(start: $0.start, end: $0.end.map { min($0, limit) })
            })
            context.insert(record)
        }

        /// 今日のセッションのうち `limit` より前に始まったもの（終わりは `limit` で切る）
        /// `plan` があれば、同じカテゴリの計画ブロックの中で始めたものはそのブロックから開始したことにする
        func insertToday(_ items: some Sequence<Item>, until limit: Date, plan: PlanDraft? = nil) {
            for item in items {
                let start = time(todayStart, item)
                guard start < limit else { continue }
                let end = min(start.addingTimeInterval(Double(item.minutes * 60)), limit)
                guard end.timeIntervalSince(start) >= FocusSession.minimumSeconds else { continue }
                let block = plan?.blocks.first {
                    $0.start <= start && start < $0.end && $0.category == categories[item.category]
                }
                insertSession(item, start: start, end: end, plannedEndAt: block?.end, planBlockId: block?.id)
            }
        }

        // 過去の日
        if scene != .firstweek {
            for day in 1...pastDays {
                guard let dayStart = calendar.date(byAdding: .day, value: -day, to: todayStart) else { continue }
                let key = DayBoundary.dayKey(containing: dayStart, calendar: calendar)
                let pastPlan = plan(dayStart: dayStart)
                try store.confirm(pastPlan, dayKey: key, timeZone: timeZone)
                let shift = (day * 13) % 5 * 5 - 10
                let stretch = (day * 7) % 4 * 5 - 5
                for (index, item) in pastItems.enumerated() where !(day % 4 == 0 && index == day % pastItems.count) {
                    let start = time(dayStart, item, shift: shift)
                    // 同じカテゴリの計画ブロックの中で始めたものは、そのブロックから開始したことにする
                    let block = pastPlan.blocks.first {
                        $0.start <= start && start < $0.end && $0.category == categories[item.category]
                    }
                    insertSession(item, start: start, end: start.addingTimeInterval(Double((item.minutes + stretch) * 60)),
                                  plannedEndAt: block?.end, planBlockId: block?.id)
                }
            }
        }

        // 今日
        let todayKey = DayBoundary.dayKey(containing: now, calendar: calendar)
        var todayPlan = plan(dayStart: todayStart)
        todayPlan.goalSeconds = goalMinutes.map { $0 * 60 }
        switch scene {
        case .morning:
            break
        case .gamePlan:
            var draft = todayPlan
            for minute in [0, 30] {
                draft.blocks.append(.unblock(start: time(todayStart, Item(hour: 20, minute: minute, minutes: 30, category: 0))))
            }
            try store.saveDraft(draft, dayKey: todayKey, timeZone: timeZone)
        case .noplan:
            try store.skip(dayKey: todayKey, timeZone: timeZone)
            insertToday(todayItems.prefix(2), until: now)
        case .day, .firstweek:
            try store.confirm(todayPlan, dayKey: todayKey, timeZone: timeZone)
            insertToday(todayItems, until: now, plan: todayPlan)
        case .running:
            try store.confirm(todayPlan, dayKey: todayKey, timeZone: timeZone)
            let start = now.addingTimeInterval(-23 * 60)
            insertToday(todayItems, until: start, plan: todayPlan)
            if let block = todayPlan.blocks.first(where: { $0.start <= now && now < $0.end }) {
                let item = planItems[todayPlan.blocks.firstIndex(of: block)!]
                insertSession(item, start: start, end: nil, plannedEndAt: block.end, planBlockId: block.id)
            } else {
                insertSession(Item(hour: 0, minute: 0, minutes: 25, category: 0), start: start, end: nil, plannedDurationSec: 25 * 60)
            }
        case .offPlanAtBlock:
            try store.confirm(todayPlan, dayKey: todayKey, timeZone: timeZone)
            let start = now.addingTimeInterval(-35 * 60)
            insertToday(todayItems, until: start, plan: todayPlan)
            insertSession(Item(hour: 0, minute: 0, minutes: 60, category: 0), start: start, end: nil, plannedDurationSec: 60 * 60)
        case .forgot:
            let start = now.addingTimeInterval(-5 * 3600)
            if DayBoundary.dayKey(containing: start, calendar: calendar) == todayKey {
                try store.confirm(todayPlan, dayKey: todayKey, timeZone: timeZone)
                insertToday(todayItems, until: start, plan: todayPlan)
            }
            insertSession(Item(hour: 0, minute: 0, minutes: 25, category: 0), start: start, end: nil, plannedDurationSec: 25 * 60)
        }
        try context.save()

    }
}
