import Foundation

/// 足せるブロックの候補（PLN-09、docs/product/features/daily-plan.md「候補から足す」）。
struct PlanCandidate: Identifiable, Hashable {
    enum Source: Hashable {
        case yesterday
        case lastWeek
        /// テンプレートの名前
        case template(String)
    }

    /// その日に当てはめたブロック。足すときは新しい ID にする（`blockToAdd`）
    var block: PlanBlockDraft
    var source: Source
    /// 例：昨日、先週の月曜、平日
    var sourceLabel: String
    /// 描き直しても変わらない ID（中身から決める。行を作り直さないため）
    var id: String {
        "\(block.category.id)-\(block.project?.id.uuidString ?? "")-\(block.start.timeIntervalSinceReferenceDate)-\(block.minutes)"
    }

    /// 計画に足すブロック（同じ時刻・長さ、新しい ID）
    var blockToAdd: PlanBlockDraft {
        var added = block
        added.id = UUID()
        return added
    }
}

enum PlanCandidates {
    /// 候補の元になる、確定した日の計画（日中に直したあとの形）
    struct SourcePlan {
        var source: PlanCandidate.Source
        var plan: PlanDraft
        /// その計画の日（暦の日。その日の始まり、または日の名前の日の 0:00）。何日ずらすかに使う
        var dayStart: Date
    }

    /// 昨日 → 先週 → テンプレートの順に集め、同じもの（カテゴリ・ブロック名・時刻・長さ）は最初の出どころだけ残して時刻順に並べる。
    /// 今の計画と重なるもの・ゲーム・SNS の時間は出さない。`notEndedBy` があれば（計画のタブ）、その時刻までに終わったものも出さない
    /// - dayStart・dayEnd: その日の始まりと終わり（dayEnd が nil なら24時間後）。その日に入らないものは出さない
    /// - dayDate: 日の名前の日の 0:00（nil なら dayStart の暦の日）
    static func make(plan: PlanDraft, dayStart: Date, dayEnd: Date? = nil, dayDate: Date? = nil, calendar: Calendar,
                     sources: [SourcePlan], templates: [PlanTemplate], notEndedBy: Date?) -> [PlanCandidate] {
        let dayEnd = dayEnd ?? calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86400)
        let dayDate = dayDate ?? calendar.startOfDay(for: dayStart)
        var found: [PlanCandidate] = []
        func add(_ block: PlanBlockDraft, _ source: PlanCandidate.Source) {
            guard !block.isUnblock, !plan.blocks.contains(where: block.overlaps),
                  block.start >= dayStart, block.end <= dayEnd,
                  notEndedBy.map({ block.end > $0 }) ?? true,
                  !found.contains(where: { $0.block.matches(block) }) else { return }
            found.append(PlanCandidate(block: block, source: source, sourceLabel: label(source, dayStart: dayDate, calendar: calendar)))
        }
        for source in sources {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: source.dayStart), to: dayDate).day ?? 0
            for block in source.plan.sortedBlocks {
                // 暦で日をずらすので、夏時間をまたいでも同じ時刻になる
                guard let start = calendar.date(byAdding: .day, value: days, to: block.start) else { continue }
                var moved = block
                moved.start = start
                add(moved, source.source)
            }
        }
        for template in templates {
            for block in template.draft(dayStart: dayStart, dayEnd: dayEnd, dayDate: dayDate, calendar: calendar).sortedBlocks {
                add(block, .template(template.name))
            }
        }
        return found.enumerated().sorted { ($0.element.block.start, $0.offset) < ($1.element.block.start, $1.offset) }.map(\.element)
    }

    private static func label(_ source: PlanCandidate.Source, dayStart: Date, calendar: Calendar) -> String {
        switch source {
        case .yesterday: return "昨日"
        case .lastWeek:
            let weekday = ["日", "月", "火", "水", "木", "金", "土"][(calendar.component(.weekday, from: dayStart) - 1) % 7]
            return "先週の\(weekday)曜"
        case .template(let name): return name
        }
    }
}
