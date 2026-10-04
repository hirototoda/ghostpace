import Foundation
import Testing
@testable import FocusApp

/// 目標のゴーストの進み方（GHO-10、Q11〜Q13）。
struct GoalGhostTests {
    private let calendar = tokyoCalendar
    private let c = DefaultCategories.all
    private let dayStart = jst("2026-10-19T04:00")

    private func block(_ start: String, _ minutes: Int, _ category: CategoryOption) -> PlanBlockDraft {
        PlanBlockDraft(start: jst("2026-10-19T" + start), minutes: minutes, category: category)
    }

    /// 7:00 に起きて 0:00 に寝る日（その朝の睡眠とその夜の睡眠）
    private let awake7to24 = [DateInterval(start: jst("2026-10-19T00:00"), end: jst("2026-10-19T07:00")),
                              DateInterval(start: jst("2026-10-20T00:00"), end: jst("2026-10-20T07:00"))]

    private func ghost(_ blocks: [PlanBlockDraft]?, goalMinutes: Int?, sleep: [DateInterval] = []) -> GoalGhost {
        GoalGhost(plan: blocks.map { PlanDraft(blocks: $0) }, goalSeconds: goalMinutes.map { $0 * 60 }, sleep: sleep,
                  dayStart: dayStart, calendar: calendar)
    }

    private func minutes(_ ghost: GoalGhost, at time: String) -> Int {
        ghost.focusSeconds(at: jst("2026-10-19T" + time)) / 60
    }

    // MARK: 計画どおり

    @Test func followsFocusBlocksOnlyWhenGoalEqualsPlan() {
        // 9:00–10:30 勉強、11:00–12:00 運動（デトックス）、13:00–15:00 仕事
        let g = ghost([block("09:00", 90, c[0]), block("11:00", 60, c[5]), block("13:00", 120, c[1])], goalMinutes: nil)
        #expect(g.goalSeconds == 210 * 60)
        #expect(minutes(g, at: "09:00") == 0)
        #expect(minutes(g, at: "09:30") == 30)
        #expect(minutes(g, at: "11:30") == 90)  // デトックスの間は増えない
        #expect(minutes(g, at: "14:00") == 150)
        #expect(minutes(g, at: "23:00") == 210)
        #expect(g.wholeDayFocusSeconds == 210 * 60)
    }

    @Test func goalBelowPlanIsRaisedToPlan() {
        // Q12：目標は計画の集中の合計より少なくできない
        let g = ghost([block("09:00", 120, c[0])], goalMinutes: 60)
        #expect(g.goalSeconds == 120 * 60)
    }

    // MARK: 目標が計画より多い（Q11、2026-10-03 から起きている時間）

    @Test func extraIsSpreadOverGapsOfTheWakingDay() {
        // docs の例：7:00 起き・0:00 寝、9:00–12:00 勉強、17:00–18:00 休み、目標6時間
        // 空き 7:00–9:00・12:00–17:00・18:00–0:00（13時間）に3時間を均等に
        let g = ghost([block("09:00", 180, c[0]), block("17:00", 60, c[4])], goalMinutes: 360, sleep: awake7to24)
        #expect(minutes(g, at: "06:59") == 0)
        #expect(minutes(g, at: "09:00") == 27)
        #expect(minutes(g, at: "12:00") == 207)
        #expect(minutes(g, at: "18:00") == 276)
        #expect(minutes(g, at: "21:00") < 360)  // 最後のブロックの終わりでは、まだ目標に届かない
        #expect(g.focusSeconds(at: jst("2026-10-20T00:00")) == 360 * 60)
        #expect(g.wholeDayFocusSeconds == 360 * 60)
    }

    @Test func detoxBlocksAreNotGaps() {
        // 9:00–10:00 勉強、10:00–11:00 運動、13:00–14:00 勉強。空きは 7:00–9:00・11:00–13:00・14:00–0:00（14時間）
        // 多い分7時間 → 1時間に30分ずつ。運動の間は増えない
        let g = ghost([block("09:00", 60, c[0]), block("10:00", 60, c[5]), block("13:00", 60, c[0])], goalMinutes: 540,
                      sleep: awake7to24)
        #expect(minutes(g, at: "09:00") == 60)
        #expect(minutes(g, at: "10:00") == 120)
        #expect(minutes(g, at: "11:00") == 120)
        #expect(minutes(g, at: "12:00") == 150)
        #expect(minutes(g, at: "13:00") == 180)
        #expect(minutes(g, at: "14:00") == 240)
        #expect(g.focusSeconds(at: jst("2026-10-20T00:00")) == 540 * 60)
    }

    @Test func blocksBeforeWakingStillCountButGapsStartAtWaking() {
        // 6:00–7:00 勉強（起きる前の計画）、起きるのは 8:00。空きは 8:00–0:00（16時間）に2時間 → 1時間に7.5分
        let sleep = [DateInterval(start: jst("2026-10-19T00:00"), end: jst("2026-10-19T08:00")), awake7to24[1]]
        let g = ghost([block("06:00", 60, c[0])], goalMinutes: 180, sleep: sleep)
        #expect(minutes(g, at: "07:00") == 60)
        #expect(minutes(g, at: "08:00") == 60)
        #expect(minutes(g, at: "16:00") == 120)
        #expect(g.focusSeconds(at: jst("2026-10-20T00:00")) == 180 * 60)
    }

    @Test func lateBlockPastBedtimeExtendsTheRangeButNotIntoSleep() {
        // 23:00 に寝る日に 23:30–0:30 の勉強。空きは 7:00–8:00・9:00–23:00（15時間）。寝ている 23:00–23:30 には足さない
        let sleep = [awake7to24[0], DateInterval(start: jst("2026-10-19T23:00"), end: jst("2026-10-20T07:00"))]
        let g = ghost([block("08:00", 60, c[0]), block("23:30", 60, c[0])], goalMinutes: 270, sleep: sleep)
        #expect(minutes(g, at: "08:00") == 10)
        #expect(minutes(g, at: "23:00") == 210)
        #expect(minutes(g, at: "23:30") == 210)
        #expect(g.focusSeconds(at: jst("2026-10-20T00:30")) == 270 * 60)
    }

    @Test func unknownBedtimeEndsTheRangeAt20() {
        // 睡眠が分からない日：最初のブロック 9:00 から 20:00 まで。空き 10:00–12:00・14:00–20:00（8時間）に2時間 → 1時間に15分
        let g = ghost([block("09:00", 60, c[0]), block("12:00", 120, c[0])], goalMinutes: 300)
        #expect(minutes(g, at: "08:59") == 0)
        #expect(minutes(g, at: "10:00") == 60)
        #expect(minutes(g, at: "12:00") == 90)
        #expect(minutes(g, at: "14:00") == 210)
        #expect(minutes(g, at: "20:00") == 300)
        #expect(minutes(g, at: "22:00") == 300)
    }

    @Test func bedtimeBeforeWakingIsTreatedAsUnknown() {
        // 寝る時刻が起きた時刻より前（読み違い）→ 分からない日と同じく 9:00〜20:00
        let sleep = [DateInterval(start: jst("2026-10-19T00:00"), end: jst("2026-10-19T07:00")),
                     DateInterval(start: jst("2026-10-19T06:00"), end: jst("2026-10-19T06:30"))]
        let g = ghost([block("09:00", 60, c[0]), block("12:00", 120, c[0])], goalMinutes: 300, sleep: sleep)
        #expect(minutes(g, at: "09:00") == 0)
        #expect(minutes(g, at: "20:00") == 300)
    }

    @Test func unknownBedtimeKeepsALateLastBlock() {
        // 20:00 より遅いブロックがあれば、その終わりまで。空き 10:00–21:00（11時間）に 11×6 分 ＝ 66分
        let g = ghost([block("09:00", 60, c[0]), block("21:00", 60, c[0])], goalMinutes: 186)
        #expect(minutes(g, at: "21:00") == 126)
        #expect(minutes(g, at: "22:00") == 186)
    }

    @Test func onlyWakeKnownEndsAt20() {
        // その朝の睡眠だけ（寝る時刻が分からない）：始まりは起きた 7:00、終わりは 20:00
        // 空き 7:00–9:00・10:00–20:00（12時間）に2時間 → 1時間に10分
        let g = ghost([block("09:00", 60, c[0])], goalMinutes: 180, sleep: [awake7to24[0]])
        #expect(minutes(g, at: "09:00") == 20)
        #expect(minutes(g, at: "20:00") == 180)
        #expect(minutes(g, at: "22:00") == 180)
    }

    @Test func bedtimeEqualToWakingIsTreatedAsUnknown() {
        let sleep = [awake7to24[0], DateInterval(start: jst("2026-10-19T07:00"), end: jst("2026-10-19T08:00"))]
        let g = ghost([block("09:00", 60, c[0]), block("12:00", 120, c[0])], goalMinutes: 300, sleep: sleep)
        #expect(minutes(g, at: "09:00") == 0)
        #expect(minutes(g, at: "20:00") == 300)
    }

    @Test func sleepOutsideTheDayIsClampedTo4am() {
        // 3:00 に起きて翌 5:00 に寝る → 4:00〜翌4:00 が起きている時間。空き 4:00–9:00・10:00–翌4:00（23時間）に 23×6 分
        let sleep = [DateInterval(start: jst("2026-10-18T23:00"), end: jst("2026-10-19T03:00")),
                     DateInterval(start: jst("2026-10-20T05:00"), end: jst("2026-10-20T12:00"))]
        let g = ghost([block("09:00", 60, c[0])], goalMinutes: 60 + 138, sleep: sleep)
        #expect(minutes(g, at: "04:00") == 0)
        #expect(minutes(g, at: "09:00") == 30)
        #expect(g.focusSeconds(at: jst("2026-10-20T03:59")) < 198 * 60)
        #expect(g.wholeDayFocusSeconds == 198 * 60)
    }

    @Test func extraBeyondGapsContinuesAfterBedtime() {
        // 7:00 起き・23:00 寝、9:00–10:00 勉強。空き 7:00–9:00・10:00–23:00（15時間）より1時間多い → 23:00–0:00 も集中
        let sleep = [awake7to24[0], DateInterval(start: jst("2026-10-19T23:00"), end: jst("2026-10-20T07:00"))]
        let g = ghost([block("09:00", 60, c[0])], goalMinutes: 17 * 60, sleep: sleep)
        #expect(minutes(g, at: "23:00") == 16 * 60)
        #expect(g.focusSeconds(at: jst("2026-10-20T00:00")) == 17 * 3600)
    }

    @Test func extraBeyondGapsNeverStartsBeforeWaking() {
        // 21:00 に起きた・寝る時刻は分からない・計画は午前だけ → 20:00 で範囲が終わるが、続きは起きた 21:00 から
        let g = ghost([block("09:00", 60, c[0])], goalMinutes: 120,
                      sleep: [DateInterval(start: jst("2026-10-19T12:00"), end: jst("2026-10-19T21:00"))])
        #expect(minutes(g, at: "21:00") == 60)
        #expect(minutes(g, at: "22:00") == 120)
    }

    @Test func extraBeyondGapsContinuesAfterTheRange() {
        // 空き（10:00–11:00・12:00–20:00 の9時間）より多い分は、空きをすべて集中にし、残りは範囲の終わり（20:00）の後に続ける
        let g = ghost([block("09:00", 60, c[0]), block("11:00", 60, c[0])], goalMinutes: 720)
        #expect(minutes(g, at: "20:00") == 660)
        #expect(minutes(g, at: "21:00") == 720)
        #expect(g.wholeDayFocusSeconds == 720 * 60)
    }

    @Test func extraNeverRunsPastTheDayBoundary() {
        // 3:00 まで計画があれば、翌朝4:00で打ち切る
        let blocks = [PlanBlockDraft(start: jst("2026-10-20T02:00"), minutes: 60, category: c[0])]
        let g = GoalGhost(plan: PlanDraft(blocks: blocks), goalSeconds: 240 * 60, sleep: [], dayStart: dayStart, calendar: calendar)
        #expect(g.wholeDayFocusSeconds == 120 * 60)
    }

    // MARK: 計画なし日（Q13）

    @Test func noPlanDaySpreadsGoalFrom8To20() {
        let g = ghost(nil, goalMinutes: 360)
        #expect(minutes(g, at: "08:00") == 0)
        #expect(minutes(g, at: "09:00") == 30)
        #expect(minutes(g, at: "14:00") == 180)
        #expect(minutes(g, at: "20:00") == 360)
        #expect(minutes(g, at: "22:00") == 360)
    }

    @Test func noPlanDayOver12HoursWidensBothSides() {
        // 14時間なら 7:00〜21:00 ずっと集中
        let g = ghost(nil, goalMinutes: 14 * 60)
        #expect(minutes(g, at: "07:00") == 0)
        #expect(minutes(g, at: "08:00") == 60)
        #expect(minutes(g, at: "21:00") == 14 * 60)
    }

    @Test func noPlanDayVeryLongGoalStaysInsideTheDay() {
        // 22時間：4:00 で切れる分を後ろに足して、1日の中で目標の分だけ進む
        let g = ghost(nil, goalMinutes: 22 * 60)
        #expect(g.wholeDayFocusSeconds == 22 * 3600)
        #expect(minutes(g, at: "04:00") == 0)
        #expect(minutes(g, at: "05:00") == 60)
    }

    @Test func noPlanDayWithoutGoalHasNoGhost() {
        #expect(ghost(nil, goalMinutes: nil).goalSeconds == 0)
        #expect(ghost([], goalMinutes: nil).goalSeconds == 0)
    }

    @Test func emptyPlanWithGoalBehavesLikeNoPlanDay() {
        let g = ghost([], goalMinutes: 120)
        #expect(minutes(g, at: "14:00") == 60)
    }

    @Test func detoxOnlyPlanSpreadsGoalOverGapsOfTheWakingDay() {
        // 集中のブロックがなくても、目標を立てれば起きている時間の空きに進む。空き 7:00–9:00・10:00–12:00・13:00–0:00（15時間）
        let g = ghost([block("09:00", 60, c[5]), block("12:00", 60, c[4])], goalMinutes: 150, sleep: awake7to24)
        #expect(minutes(g, at: "09:00") == 20)
        #expect(minutes(g, at: "10:00") == 20)
        #expect(minutes(g, at: "11:00") == 30)
        #expect(minutes(g, at: "13:00") == 40)
        #expect(g.focusSeconds(at: jst("2026-10-20T00:00")) == 150 * 60)
    }

    @Test func noPlanDayIgnoresSleep() {
        // 計画なし日は起きている時間に関係なく 8:00〜20:00（Q13 のまま）
        let g = ghost(nil, goalMinutes: 360, sleep: awake7to24)
        #expect(minutes(g, at: "08:00") == 0)
        #expect(minutes(g, at: "20:00") == 360)
    }
}
