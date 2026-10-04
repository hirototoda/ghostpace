import Foundation
import Testing
@testable import FocusApp

/// ブロックの決まり（app-blocking.md、BLK-07〜09、ADR-0013）。
struct BlockPolicyTests {
    private let now = jst("2026-10-19T11:20")

    // MARK: 開ける長さ（BLK-07）

    @Test func unlockMinuteOptionsAreFiveToSixtyInFives() {
        #expect(BlockPolicy.unlockMinuteOptions == [5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60])
        #expect(BlockPolicy.defaultUnlockMinutes == 15)
        // 3秒押し続けたあと、5秒数えてから開く（2026-10-01 オーナー要望で 5秒長押しから変更）
        #expect(BlockPolicy.holdSeconds == 3)
        #expect(BlockPolicy.countdownSeconds == 5)
    }

    @Test(arguments: [5, 15, 60])
    func unlockedUntilAddsChosenMinutes(minutes: Int) {
        #expect(BlockPolicy.unlockedUntil(now: now, minutes: minutes) == now.addingTimeInterval(Double(minutes) * 60))
    }

    @Test(arguments: [0, 3, 17, 65, -5])
    func unlockedUntilRejectsMinutesOutsideOptions(minutes: Int) {
        #expect(BlockPolicy.unlockedUntil(now: now, minutes: minutes) == nil)
    }

    // MARK: ブロック中か（BLK-09）

    @Test func blockedWhenEnabledAndNotUnlocked() {
        #expect(BlockPolicy.isBlocked(BlockState(isEnabled: true), now: now))
        #expect(!BlockPolicy.isBlocked(BlockState(isEnabled: false), now: now))
    }

    @Test func unlockedUntilTheMomentItEnds() {
        let until = now.addingTimeInterval(15 * 60)
        let state = BlockState(isEnabled: true, unlockedUntil: until)
        #expect(!BlockPolicy.isBlocked(state, now: until.addingTimeInterval(-1)))
        #expect(!BlockPolicy.isExpired(state, now: until.addingTimeInterval(-1)))
        // 期限ちょうどでブロックに戻る
        #expect(BlockPolicy.isBlocked(state, now: until))
        #expect(BlockPolicy.isExpired(state, now: until))
        #expect(BlockPolicy.isExpired(state, now: until.addingTimeInterval(3600)))
    }

    @Test func notExpiredWhenNeverUnlocked() {
        #expect(!BlockPolicy.isExpired(BlockState(isEnabled: true), now: now))
    }

    @Test func unlockAcrossDayBoundaryIsJustTime() {
        // 3:55 に15分開ければ 4:10 まで。日付の区切りは関係しない
        let start = jst("2026-10-20T03:55")
        let until = BlockPolicy.unlockedUntil(now: start, minutes: 15)
        #expect(until == jst("2026-10-20T04:10"))
        #expect(!BlockPolicy.isBlocked(BlockState(isEnabled: true, unlockedUntil: until), now: jst("2026-10-20T04:05")))
    }

    // MARK: シールドの「開く」から2分以内（BLK-08）

    @Test func holdScreenWantedWithinTwoMinutesOfRequest() {
        func state(_ secondsAgo: TimeInterval) -> BlockState {
            BlockState(isEnabled: true, unlockRequestedAt: now.addingTimeInterval(-secondsAgo))
        }
        #expect(BlockPolicy.wantsHoldScreen(state(0), now: now))
        #expect(BlockPolicy.wantsHoldScreen(state(119), now: now))
        #expect(BlockPolicy.wantsHoldScreen(state(120), now: now))
        #expect(!BlockPolicy.wantsHoldScreen(state(121), now: now))
        // 時計が戻った（未来の時刻）ときは出さない
        #expect(!BlockPolicy.wantsHoldScreen(state(-30), now: now))
        #expect(!BlockPolicy.wantsHoldScreen(BlockState(isEnabled: true), now: now))
        // 開けている間は出さない
        var unlocked = state(10)
        unlocked.unlockedUntil = now.addingTimeInterval(600)
        #expect(!BlockPolicy.wantsHoldScreen(unlocked, now: now))
    }

    // MARK: 自動で戻すスケジュール（最短15分、ios-constraints.md）
    // 実機で「スケジュールの終わり」の合図は届かず、「終わる前の合図」は届いた（2026-10-01）。
    // そこで、どの長さでも「戻す時刻＋15分」で終わるスケジュールを作り、15分前の合図（＝戻す時刻）で戻す。

    @Test(arguments: [5, 10, 15, 30, 60])
    func everyLengthReblocksByWarning(minutes: Int) throws {
        let schedule = try #require(BlockPolicy.reblockSchedule(now: now, minutes: minutes))
        let fire = now.addingTimeInterval(Double(minutes) * 60)
        #expect(schedule.start == now)
        #expect(schedule.warningMinutes == 15)
        #expect(schedule.end == fire.addingTimeInterval(15 * 60))
        #expect(schedule.fireAt == fire)
        // スケジュールは15分以上ある
        #expect(schedule.end.timeIntervalSince(schedule.start) >= 15 * 60)
    }

    @Test func scheduleRoundsUpToMinuteSoItNeverFiresEarly() throws {
        // スケジュールは分単位。10:03:40 に5分開けると期限は 10:08:40、戻すのは 10:09:00
        let at = jst("2026-10-19T10:03:40")
        let five = try #require(BlockPolicy.reblockSchedule(now: at, minutes: 5))
        #expect(five.start == jst("2026-10-19T10:03"))
        #expect(five.fireAt == jst("2026-10-19T10:09"))
        #expect(five.end == jst("2026-10-19T10:24"))
        let fifteen = try #require(BlockPolicy.reblockSchedule(now: at, minutes: 15))
        #expect(fifteen.fireAt == jst("2026-10-19T10:19"))
        #expect(fifteen.fireAt >= BlockPolicy.unlockedUntil(now: at, minutes: 15)!)
    }

    @Test func scheduleRejectsInvalidMinutes() {
        #expect(BlockPolicy.reblockSchedule(now: now, minutes: 7) == nil)
    }
}
