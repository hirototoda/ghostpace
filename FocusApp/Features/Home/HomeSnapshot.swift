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
    /// 一日の始まり（前の日の区切り）
    var dayStart: Date
    /// その日の区切り（グラフの右端）
    var dayEnd: Date
    /// 日の名前（GHO-17、glossary.md「日の名前」）
    var dayKey: String
    /// 日の名前の日の 0:00（表示の日付と、ほかの日と同じ時刻でそろえる基準）
    var dayDate: Date
    /// 区切りの履歴より前の日（朝4:00区切りの今までの数え方。確定は朝4:00）
    var isLegacyDay = false
    var sessions: [TimeSegment]
    var planBlocks: [PlanBlockSummary]
    var isNoPlanDay: Bool
    /// 先週の同じ曜日。記録がなければ nil（GHO-03）
    var ghost: GhostSummary?
    /// 目標のゴースト（GHO-10）。目標が0なら nil
    var goal: GoalGhost? = nil
    /// ホームに「今日を振り返る」を出すか（REV-02。その日の区切りから次の朝の計画を確定するまで）。AppModel が入れる
    var showsReviewEntry = false
    /// 今日のデジタルデトックス（DTX-01・03）。ブロックの記録から数える
    var detox: DetoxDay? = nil
    /// 先週の同じ曜日のデトックス（今日に揃えたもの）。丸1日分の記録がない日は nil（「先週のデトックスはなし」）
    var ghostDetox: DetoxDay? = nil
    /// 目標のゴーストのデトックス：計画どおりに進み、一度も開けない理想の日（2026-10-02 オーナー決定）
    var goalDetox: DetoxDay? = nil
    /// 自己ベストから開いたその日のグラフの相手「今日」（ANA-05、2026-10-11）。AppModel が入れる
    var todayRival: TodayRival? = nil
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

    /// 今までに始まった区間のラップ。相手がいなければ空。2026-10-12 からポイントで比べるので、
    /// 相手のポイントがない日（先週のデトックスがない日など、グラフに相手の線を出さない日）も空
    func laps(_ opponent: Opponent) -> [Lap] {
        guard let focus = opponentFocus(opponent), opponentPoints(opponent, at: dayStart) != nil else { return [] }
        return Laps.make(mine: sessions, opponent: focus, minePoints: myPoints(until:),
                         opponentPoints: { opponentPoints(opponent, at: $0) ?? 0 }, dayStart: dayStart, dayEnd: dayEnd, now: now)
    }

    /// 中間地点：相手の1日分のポイントの半分に、自分のポイントが届いた時刻（2026-10-12 からポイントで。それまでは集中した時間）
    func halfwayTime(_ opponent: Opponent) -> Date? {
        guard let whole = opponentPoints(opponent, at: dayEnd) else { return nil }
        return Laps.reachTime(points: whole / 2, of: myPoints(until:), from: dayStart, until: now)
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
    /// 朝の計画を確定した時刻。これより前に始めた記録（前の夜の予定、PLN-11）は、写しにあっても「足した時刻」で決める
    var confirmedAt: Date? = nil
    /// 点を数えるブロック。nil なら今の計画のブロック（計画しない日も、残した前の夜の分で数える。PLN-11）
    var blocks: [PlanBlockDraft]? = nil
}

extension HomeSnapshot {
    /// 記録からホームの表示を作る。
    /// - todaySessions: 今日の dayKey のセッション（実行中を含む）と、前の日に始めて区切りをまたいだセッション
    /// - plan: nil なら計画なし日（スキップ）
    /// - lastWeekSessions: 7日前の dayKey のセッション。0件なら対戦なし（GHO-03）
    /// - noPlanGoalSeconds: 計画なし日に決めた目標
    /// - detox / lastWeekDetox: 今日と先週の同じ曜日のデトックス（DTX-01）。先週は丸1日分あるときだけ使う
    /// - sleep: 今日の睡眠（点を付ける睡眠）。目標のゴーストのデトックスに使う
    /// - awakeSleep: [その朝の睡眠, その夜の睡眠]。目標のゴーストの起きている時間・開ける時刻に使う。nil なら `sleep`
    /// - day: その日（始まり・終わり・日の名前）。nil なら区切りの履歴がないとき（朝4:00区切り）の `dayStart`（なければ `now`）の日
    /// - lastWeekDay: 先週の同じ曜日（先週の区切りで数えたまま）。nil なら `day` と同じ区切りの7日前
    /// - dayStart: 過ぎた日（分析、ANA-05）は `now` をその日の区切りにするので、日を取り違えないよう渡す（`day` がないとき）
    static func make(now: Date, calendar: Calendar, todaySessions: [FocusSession], plan: PlanDraft?,
                     lastWeekSessions: [FocusSession], noPlanGoalSeconds: Int? = nil, detox: DetoxDay? = nil,
                     lastWeekDetox: DetoxDay? = nil, sleep: [DateInterval] = [], sleepCaps: [DateInterval] = [],
                     awakeSleep: [DateInterval]? = nil, day: BoundaryDay? = nil, lastWeekDay: BoundaryDay? = nil,
                     dayStart: Date? = nil, onPlan: OnPlanContext = OnPlanContext()) -> HomeSnapshot {
        let legacy = DayBoundary(calendar: calendar)
        let day = day ?? legacy.day(containing: dayStart ?? now)
        let lastWeekDay = lastWeekDay ?? legacy.day(-7, from: day)
        let dayStart = day.start, dayEnd = day.end
        // 先週の日を今日に重ねるずれ（同じ時刻でそろえる、GHO-02）
        let shift = day.date.timeIntervalSince(lastWeekDay.date)
        // 計画なし日は目標時間だけ（GHO-10、Q13）
        let goal = GoalGhost(plan: plan, goalSeconds: plan == nil ? noPlanGoalSeconds : plan?.goalSeconds, sleep: awakeSleep ?? sleep,
                             dayStart: dayStart, dayEnd: dayEnd, dayDate: day.date, calendar: calendar).nonEmpty
        var snapshot = HomeSnapshot(
            now: now,
            dayStart: dayStart,
            dayEnd: dayEnd,
            dayKey: day.key,
            dayDate: day.date,
            isLegacyDay: day.isLegacy,
            // 前の日に始めて区切りをまたいだタイマーは、区切りより後の分だけ（2026-10-03）
            sessions: todaySessions.flatMap { $0.activeSegments(now: now) }.compactMap { $0.starting(at: dayStart) },
            planBlocks: plan?.summaries ?? [],
            isNoPlanDay: plan == nil,
            ghost: GhostSummary(lastWeek: lastWeekSessions, lastWeekDay: lastWeekDay.interval, shift: shift),
            goal: goal,
            detox: detox,
            ghostDetox: lastWeekDetox.flatMap { $0.isComplete ? $0.shifted(by: shift) : nil },
            goalDetox: goal.map { idealDetox($0, plan: plan, sleep: sleep, awakeSleep: awakeSleep ?? sleep, sleepCaps: sleepCaps,
                                             dayStart: dayStart, dayEnd: dayEnd) }
        )
        // 計画どおりの点（GHO-16）：自分、目標のゴースト、先週の自分（先週の計画と記録から同じ決まりで、今日に揃える）
        let awardBlocks = onPlan.blocks ?? plan?.blocks
        snapshot.planAwards = awardBlocks.map {
            OnPlanPoints.awards(blocks: $0, sessions: todaySessions, morningBlockIds: onPlan.morningBlockIds,
                                addedAt: onPlan.addedAt, morningSince: onPlan.confirmedAt, now: now)
        } ?? []
        snapshot.goalPlanAwards = goal == nil ? [] : OnPlanPoints.goalAwards(blocks: plan?.blocks ?? [])
        if let lastWeek = onPlan.lastWeekPlan {
            snapshot.ghostPlanAwards = OnPlanPoints.awards(
                blocks: lastWeek.draft.blocks, sessions: lastWeekSessions, morningBlockIds: onPlan.lastWeekMorningBlockIds,
                addedAt: lastWeek.addedAt, morningSince: lastWeek.confirmedAt, now: lastWeekDay.end)
                .map { $0.date.addingTimeInterval(shift) }
        }
        snapshot.startedBlockIds = Set(todaySessions.compactMap(\.planBlockId))
        return snapshot
    }

    /// 目標のゴーストのデトックス：計画どおりに進み、2回だけ（0分）開ける日（GHO-10、2026-10-03）。
    /// 目標どおりに集中する時間（速さ1の区間）は集中、空き時間に少しずつ集中する区間は残りの割合だけデトックス、
    /// 計画のデトックスのブロックはタイマー中（グループの上限まで）、寝ている間は自分と同じ睡眠で数える
    private static func idealDetox(_ goal: GoalGhost, plan: PlanDraft?, sleep: [DateInterval], awakeSleep: [DateInterval],
                                   sleepCaps: [DateInterval], dayStart: Date, dayEnd: Date) -> DetoxDay {
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
        day.unlockStarts = GoalGhost.openTimes(sleep: awakeSleep, dayStart: dayStart, dayEnd: dayEnd)
        return day
    }
}
