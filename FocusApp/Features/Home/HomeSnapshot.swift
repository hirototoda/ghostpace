import Foundation

/// ホームに出す計画ブロック。
struct PlanBlockSummary: Identifiable, Hashable {
    var id: UUID
    var category: CategoryOption
    var project: ProjectOption?
    /// プロジェクト名があればそれ、なければカテゴリ名
    var title: String
    var categoryName: String
    var start: Date
    var end: Date
    var countsAsFocus: Bool
}

/// ホーム画面の表示内容。記録から `make` で作る。
struct HomeSnapshot {
    var now: Date
    var dayStart: Date
    /// 翌日の4:00（グラフの右端）
    var dayEnd: Date
    var sessions: [TimeSegment]
    var planBlocks: [PlanBlockSummary]
    var isNoPlanDay: Bool
    /// 先週の同じ曜日。記録がなければ nil（GHO-03）
    var ghost: GhostSummary?
    /// 目標のゴースト（GHO-10）。目標が0なら nil
    var goal: GoalGhost? = nil
    /// 振り返りの通知時刻（初期値 22:00、REV-02）
    var reviewTime: Date
    /// 今日のデジタルデトックス（DTX-01・03）。ブロックの記録から数える
    var detox: DetoxDay? = nil
    /// 先週の同じ曜日のデトックス（今日に揃えたもの）。丸1日分の記録がない日は nil（「先週のデトックスはなし」）
    var ghostDetox: DetoxDay? = nil
    /// 目標のゴーストのデトックス：計画どおりに進み、一度も開けない理想の日（2026-10-02 オーナー決定）
    var goalDetox: DetoxDay? = nil
    /// タイマーを始めた所とカテゴリのアイコン（裏のグラフ、GHO-15）。続けて同じカテゴリのときは最初だけ
    var sessionIcons: [SessionIcon] = []
    /// 自己ベスト（今日より前、GHO-15・ANA-06）。AppModel が入れる
    var personalBest: PersonalBest? = nil
    /// 先週より前に記録がある（休み明けの文言、GHO-15）。AppModel が入れる
    var hasOlderHistory = false
    /// 起きている時間（計画なし日のペース）。AppModel が入れる
    var awake: ClosedRange<Date>? = nil
    /// 計画どおりの点（GHO-16）が付いた時刻：自分・先週の自分（今日に揃えた）・目標のゴースト
    var planAwards: [OnPlanPoints.Award] = []
    var ghostPlanAwards: [Date] = []
    var goalPlanAwards: [Date] = []
    /// 今日の記録があるブロック（さっきの行・前倒しの判定）
    var startedBlockIds: Set<UUID> = []

    var focusSeconds: Int { sessions.focusSeconds(until: now) }
    /// 今日開けた時間と回数（DTX-05）。今日ブロックが一度も効いていなければ nil（出さない）
    var opened: OpenedTime? { detox?.opened(until: now) }
    var plannedFocusSeconds: Int {
        planBlocks.filter(\.countsAsFocus).reduce(0) { $0 + Int($1.end.timeIntervalSince($1.start)) }
    }
    var currentBlock: PlanBlockSummary? { planBlocks.first { $0.start <= now && now < $0.end } }
    var nextBlock: PlanBlockSummary? { planBlocks.filter { $0.start > now }.min { $0.start < $1.start } }
    /// 今から前倒しで始められるブロック（TMR-10）：計画なし日でない日の次のブロック。
    /// 2026-10-06 から今のブロックの最中も（タイマーが動いていないとき＝ホームが見えているとき、TMR-15）。
    /// ゲーム・SNS の時間（BLK-10）はタイマーを始めないので出さない
    var earlyStartBlock: PlanBlockSummary? {
        guard !isNoPlanDay, let next = nextBlock, !next.category.isUnblock else { return nil }
        return next
    }

    /// 遅れて始められる終わったブロック（TMR-15）：記録がなく、開始から1時間以内（計画どおりの点の窓）。一番新しいもの
    var recentMissedBlock: PlanBlockSummary? {
        guard !isNoPlanDay else { return nil }
        return planBlocks.filter {
            $0.end <= now && now.timeIntervalSince($0.start) <= OnPlanPoints.window && !startedBlockIds.contains($0.id)
                && !$0.category.isUnblock
        }.max { $0.start < $1.start }
    }
    var ghostFocusSeconds: Int? { ghost?.focusSeconds(at: now) }
    /// 先週の自分との差（プラスならリード）
    var ghostDiffSeconds: Int? { ghostFocusSeconds.map { focusSeconds - $0 } }
    var showsReviewEntry: Bool { now >= reviewTime }

    /// 相手がこの時刻までに集中した時間。相手がいなければ nil
    func opponentFocusSeconds(_ opponent: Opponent) -> Int? {
        switch opponent {
        case .lastWeek: ghostFocusSeconds
        case .goal: goal?.focusSeconds(at: now)
        }
    }

    /// 相手の1日分（円の1周）
    func opponentWholeDaySeconds(_ opponent: Opponent) -> Int? {
        switch opponent {
        case .lastWeek: ghost?.wholeDayFocusSeconds
        case .goal: goal?.goalSeconds
        }
    }

    /// 相手との差（プラスならリード）
    func opponentDiffSeconds(_ opponent: Opponent) -> Int? {
        opponentFocusSeconds(opponent).map { focusSeconds - $0 }
    }

    // MARK: ラップ・予想ゴール・追いつく・自己ベスト（GHO-06・15）

    /// 相手が `date` までに集中した時間。相手がいなければ nil
    func opponentFocus(_ opponent: Opponent) -> ((Date) -> Int)? {
        switch opponent {
        case .lastWeek: ghost.map { ghost in { ghost.focusSeconds(at: $0) } }
        case .goal: goal.map { goal in { goal.focusSeconds(at: $0) } }
        }
    }

    /// 今までに始まった区間のラップ。相手がいなければ空
    func laps(_ opponent: Opponent) -> [Lap] {
        guard let focus = opponentFocus(opponent) else { return [] }
        return Laps.make(mine: sessions, opponent: focus, dayStart: dayStart, now: now)
    }

    /// 中間地点（相手の1日分の半分）に届いた時刻
    func halfwayTime(_ opponent: Opponent) -> Date? {
        opponentWholeDaySeconds(opponent).flatMap { Laps.reachTime($0 / 2, mine: sessions, now: now) }
    }

    /// 予想ゴール：計画どおりなら（計画なし日は今までのペースで）今日の集中。出せなければ nil
    var predictedFinish: Int? {
        if !isNoPlanDay { return RacePace.plannedFinish(focusNow: focusSeconds, blocks: planBlocks, now: now) }
        guard let awake else { return nil }
        return RacePace.paceFinish(focusNow: focusSeconds, wake: awake.lowerBound, bed: awake.upperBound, now: now)
    }

    /// 休まず集中して相手に追いつくまでの分
    func catchUpMinutes(_ opponent: Opponent) -> Int? {
        opponentFocus(opponent).flatMap { RacePace.catchUpMinutes(focusNow: focusSeconds, opponent: $0, now: now, dayEnd: dayEnd) }
    }

    var bestStatus: PersonalBest.Status? { personalBest?.status(todayFocus: focusSeconds) }
}

/// 計画どおりの点（GHO-16）の材料：朝の計画の写しのブロック、ブロックを足した時刻、先週の確定した計画
struct OnPlanContext {
    var morningBlockIds: Set<UUID> = []
    var addedAt: [UUID: Date] = [:]
    var lastWeekPlan: StoredPlan?
    var lastWeekMorningBlockIds: Set<UUID> = []
}

/// 裏のグラフのアイコン（GHO-15）
struct SessionIcon: Hashable {
    var start: Date
    var symbol: String
}

extension HomeSnapshot {
    /// 記録からホームの表示を作る。
    /// - todaySessions: 今日の dayKey のセッション（実行中を含む）と、前の日に始めて4:00をまたいだセッション
    /// - plan: nil なら計画なし日（スキップ）
    /// - lastWeekSessions: 7日前の dayKey のセッション。0件なら対戦なし（GHO-03）
    /// - noPlanGoalSeconds: 計画なし日に決めた目標
    /// - reviewMinutes: 振り返りの通知の時刻（0:00 からの分、REV-02）。0:00〜3:59 ならその日の夜中（翌日の暦）
    /// - detox / lastWeekDetox: 今日と先週の同じ曜日のデトックス（DTX-01）。先週は丸1日分あるときだけ使う
    /// - sleep: 今日の睡眠（その朝とその夜）。目標のゴーストの起きている時間とデトックスに使う
    /// - dayStart: その日の 4:00。過ぎた日（分析、ANA-05）は `now` を翌4:00 にするので、日を取り違えないよう渡す。nil なら `now` の日
    static func make(now: Date, calendar: Calendar, todaySessions: [FocusSession], plan: PlanDraft?,
                     lastWeekSessions: [FocusSession], reviewMinutes: Int = SettingsDefaults.reviewMinutes,
                     noPlanGoalSeconds: Int? = nil, detox: DetoxDay? = nil, lastWeekDetox: DetoxDay? = nil,
                     sleep: [DateInterval] = [], sleepCaps: [DateInterval] = [], dayStart: Date? = nil,
                     onPlan: OnPlanContext = OnPlanContext()) -> HomeSnapshot {
        let dayStart = dayStart ?? DayBoundary.dayStart(containing: now, calendar: calendar)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86400)
        let lastWeekStart = DayBoundary.sameDayLastWeek(dayStart, calendar: calendar)
        // 計画なし日は目標時間だけ（GHO-10、Q13）
        let goal = GoalGhost(plan: plan, goalSeconds: plan == nil ? noPlanGoalSeconds : plan?.goalSeconds, sleep: sleep,
                             dayStart: dayStart, calendar: calendar).nonEmpty
        var snapshot = HomeSnapshot(
            now: now,
            dayStart: dayStart,
            dayEnd: dayEnd,
            // 前の日に始めて4:00をまたいだタイマーは、4:00より後の分だけ（2026-10-03）
            sessions: todaySessions.flatMap { $0.activeSegments(now: now) }.compactMap { $0.starting(at: dayStart) },
            planBlocks: plan?.summaries ?? [],
            isNoPlanDay: plan == nil,
            ghost: GhostSummary(lastWeek: lastWeekSessions, lastWeekStart: lastWeekStart, todayStart: dayStart),
            goal: goal,
            reviewTime: calendar.date(byAdding: .minute, value: (reviewMinutes - DayBoundary.hour * 60 + 1440) % 1440, to: dayStart)
                ?? dayStart,
            detox: detox,
            ghostDetox: lastWeekDetox.flatMap { $0.isComplete ? $0.shifted(by: dayStart.timeIntervalSince(lastWeekStart)) : nil },
            goalDetox: goal.map { idealDetox($0, plan: plan, sleep: sleep, sleepCaps: sleepCaps, dayStart: dayStart, dayEnd: dayEnd) },
            sessionIcons: icons(todaySessions, dayStart: dayStart, now: now)
        )
        // 計画どおりの点（GHO-16）：自分、目標のゴースト、先週の自分（先週の計画と記録から同じ決まりで、今日に揃える）
        snapshot.planAwards = plan.map {
            OnPlanPoints.awards(blocks: $0.blocks, sessions: todaySessions, morningBlockIds: onPlan.morningBlockIds,
                                addedAt: onPlan.addedAt, now: now)
        } ?? []
        snapshot.goalPlanAwards = goal == nil ? [] : OnPlanPoints.goalAwards(blocks: plan?.blocks ?? [])
        if let lastWeek = onPlan.lastWeekPlan {
            let offset = dayStart.timeIntervalSince(lastWeekStart)
            snapshot.ghostPlanAwards = OnPlanPoints.awards(
                blocks: lastWeek.draft.blocks, sessions: lastWeekSessions, morningBlockIds: onPlan.lastWeekMorningBlockIds,
                addedAt: lastWeek.addedAt, now: dayEnd.addingTimeInterval(-offset)).map { $0.date.addingTimeInterval(offset) }
        }
        snapshot.startedBlockIds = Set(todaySessions.compactMap(\.planBlockId))
        return snapshot
    }

    /// タイマーを始めた所のアイコン。続けて同じカテゴリのときは最初だけ。前の日から続くタイマーは 4:00 に置く
    static func icons(_ sessions: [FocusSession], dayStart: Date, now: Date) -> [SessionIcon] {
        var result: [SessionIcon] = []
        var last: UUID?
        for session in sessions.sorted(by: { $0.startAt < $1.startAt }) where (session.endAt ?? now) > dayStart && session.startAt <= now {
            defer { last = session.category.id }
            guard session.category.id != last else { continue }
            result.append(SessionIcon(start: max(session.startAt, dayStart), symbol: CategoryIcon.symbol(for: session.category)))
        }
        return result
    }

    /// 目標のゴーストのデトックス：計画どおりに進み、2回だけ（0分）開ける日（GHO-10、2026-10-03）。
    /// 目標どおりに集中する時間（速さ1の区間）は集中、空き時間に少しずつ集中する区間は残りの割合だけデトックス、
    /// 計画のデトックスのブロックはタイマー中（グループの上限まで）、寝ている間は自分と同じ睡眠で数える
    private static func idealDetox(_ goal: GoalGhost, plan: PlanDraft?, sleep: [DateInterval], sleepCaps: [DateInterval],
                                   dayStart: Date, dayEnd: Date) -> DetoxDay {
        var day = DetoxDay.make(.init(
            dayStart: dayStart, dayEnd: dayEnd, until: dayEnd,
            events: [BlockEvent(occurredAt: .distantPast, timeZoneId: "UTC", kind: .started)],
            focus: goal.segments.filter { $0.rate >= 1 }.map { DateInterval(start: $0.start, end: max($0.start, $0.end)) },
            detoxTimers: (plan?.blocks ?? []).filter(\.category.countsAsDetox).map {
                DetoxTimer(interval: DateInterval(start: $0.start, end: $0.end), group: DetoxGroup.of($0.category))
            },
            sleep: sleep, gameWindows: [],
            partialFocus: goal.segments.filter { $0.rate < 1 && $0.end > $0.start }.map {
                PartialFocus(interval: DateInterval(start: $0.start, end: $0.end), share: $0.rate)
            },
            sleepCaps: sleepCaps))
        day.unlockStarts = GoalGhost.openTimes(sleep: sleep, dayStart: dayStart, dayEnd: dayEnd)
        return day
    }
}
