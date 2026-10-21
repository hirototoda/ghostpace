import Foundation
import Testing
@testable import FocusApp

/// シールドに出す差（BLK-05）。本体が書いた材料から、拡張がその時刻の分まで計算する。
struct ShieldRaceSnapshotTests {
    private let dayStart = jst("2026-10-19T04:00")

    /// 相手は 9:00〜12:00 に毎分60秒ずつ集中した（15分ごとの累積）
    private var curve: [Int] {
        (0...96).map { index in
            let minutes = index * 15
            let from = 5 * 60, to = 8 * 60  // 4:00 から 5時間後〜8時間後 = 9:00〜12:00
            return max(0, min(minutes, to) - from) * 60
        }
    }

    private func snapshot(writtenAt: String, focus: Int, running: Bool) -> ShieldRaceSnapshot {
        ShieldRaceSnapshot(writtenAt: jst(writtenAt), dayKey: "2026-10-19", dayStart: dayStart, focusSecAtWrite: focus,
                           isFocusRunning: running, opponentPrefix: "先週の自分より", opponentCurve: curve)
    }

    @Test func opponentInterpolatesBetweenSteps() {
        let s = snapshot(writtenAt: "2026-10-19T09:00", focus: 0, running: false)
        #expect(s.opponentSeconds(at: jst("2026-10-19T09:00")) == 0)
        #expect(s.opponentSeconds(at: jst("2026-10-19T09:07:30")) == 450)
        #expect(s.opponentSeconds(at: jst("2026-10-19T10:00")) == 3600)
        #expect(s.opponentSeconds(at: jst("2026-10-19T13:00")) == 3 * 3600)
        // 最後の点より後（翌日の4:00ちょうど以降）は最後の値
        #expect(s.opponentSeconds(at: jst("2026-10-20T03:59")) == 3 * 3600)
    }

    @Test func runningFocusKeepsCountingAfterWrite() {
        let s = snapshot(writtenAt: "2026-10-19T10:00", focus: 3000, running: true)
        #expect(s.focusSeconds(at: jst("2026-10-19T10:30")) == 3000 + 1800)
        // 止まっていれば増えない
        let paused = snapshot(writtenAt: "2026-10-19T10:00", focus: 3000, running: false)
        #expect(paused.focusSeconds(at: jst("2026-10-19T10:30")) == 3000)
    }

    @Test func diffAtTimeOfShield() {
        let s = snapshot(writtenAt: "2026-10-19T10:00", focus: 4800, running: false)
        // 10:20：相手は 80分、自分は 80分 → ±0
        #expect(s.diffSeconds(at: jst("2026-10-19T10:20"), calendar: tokyoCalendar) == 0)
        // 9:40 に書いた値を 9:50 に見る：相手 50分、自分 60分 → +10分
        let early = snapshot(writtenAt: "2026-10-19T09:40", focus: 3600, running: false)
        #expect(early.diffSeconds(at: jst("2026-10-19T09:50"), calendar: tokyoCalendar) == 600)
    }

    @Test func noDiffOnAnotherDay() {
        let s = snapshot(writtenAt: "2026-10-19T22:00", focus: 4800, running: false)
        // 3:59 はまだ同じ日
        #expect(s.diffSeconds(at: jst("2026-10-20T03:59"), calendar: tokyoCalendar) != nil)
        // 4:00 から次の日。古い差は出さない
        #expect(s.diffSeconds(at: jst("2026-10-20T04:00"), calendar: tokyoCalendar) == nil)
    }

    /// 1b-79：区切り 22:00 の日。区切りを過ぎたら前の日の材料の差は出さない（拡張は区切りの履歴を読めないので dayEnd で決める）
    @Test func noDiffAfterTheBoundary() {
        var s = ShieldRaceSnapshot(writtenAt: jst("2026-10-21T21:00"), dayKey: "2026-10-21", dayStart: jst("2026-10-20T22:00"),
                                   dayEnd: jst("2026-10-21T22:00"), focusSecAtWrite: 4800, isFocusRunning: false,
                                   opponentPrefix: "先週の自分より", opponentCurve: [0, 600, 1200])
        #expect(s.diffSeconds(at: jst("2026-10-21T21:59"), calendar: tokyoCalendar) != nil)
        #expect(s.diffSeconds(at: jst("2026-10-21T22:00"), calendar: tokyoCalendar) == nil)
        #expect(s.diffSeconds(at: jst("2026-10-20T21:59"), calendar: tokyoCalendar) == nil)
        // 25時間の日も区切りまで出す
        s.dayEnd = jst("2026-10-21T23:00")
        #expect(s.diffSeconds(at: jst("2026-10-21T22:30"), calendar: tokyoCalendar) != nil)
    }

    /// 前の版の材料（dayEnd がない）は始まりの24時間後まで
    @Test func oldSnapshotWithoutDayEndLastsTwentyFourHours() throws {
        let json = #"{"writtenAt":0,"dayKey":"2026-10-19","dayStart":0,"focusSecAtWrite":60,"isFocusRunning":false,"opponentPrefix":"","opponentCurve":[0]}"#
        let old = try JSONDecoder().decode(ShieldRaceSnapshot.self, from: Data(json.utf8))
        #expect(old.dayEnd == nil)
        let start = Date(timeIntervalSinceReferenceDate: 0)
        #expect(old.diffSeconds(at: start.addingTimeInterval(24 * 3600 - 1), calendar: tokyoCalendar) != nil)
        #expect(old.diffSeconds(at: start.addingTimeInterval(24 * 3600), calendar: tokyoCalendar) == nil)
    }

    @Test func noDiffWithoutOpponent() {
        var s = snapshot(writtenAt: "2026-10-19T10:00", focus: 4800, running: false)
        s.opponentCurve = []
        #expect(s.diffSeconds(at: jst("2026-10-19T10:10"), calendar: tokyoCalendar) == nil)
    }

    @Test func shieldTextShowsDiffOrFallback() {
        let s = snapshot(writtenAt: "2026-10-19T09:40", focus: 3600, running: false)
        let text = ShieldText.make(snapshot: s, now: jst("2026-10-19T09:50"), calendar: tokyoCalendar)
        #expect(text.title == "ゲームと SNS はブロック中")
        #expect(text.subtitle == "今日は先週の自分より +10分\n\n" + ShieldText.howTo)
        #expect(text.primaryButton == "閉じる")
        #expect(text.secondaryButton == "開く")

        let behind = snapshot(writtenAt: "2026-10-19T11:00", focus: 600, running: false)
        #expect(ShieldText.make(snapshot: behind, now: jst("2026-10-19T11:00"), calendar: tokyoCalendar).subtitle
            == "今日は先週の自分より −1時間50分\n\n" + ShieldText.howTo)

        let fallback = ShieldText.make(snapshot: nil, now: jst("2026-10-19T09:50"), calendar: tokyoCalendar)
        #expect(fallback.subtitle == ShieldText.howTo)
        let yesterday = ShieldText.make(snapshot: s, now: jst("2026-10-20T05:00"), calendar: tokyoCalendar)
        #expect(yesterday.subtitle == ShieldText.howTo)
        #expect(ShieldText.howTo == "「開く」を押すと通知が届きます。通知か GhostPace を開いて、3秒長押しすると5秒後に開けます")
    }

    @Test func roundTripsThroughJSON() throws {
        let s = snapshot(writtenAt: "2026-10-19T09:40", focus: 3600, running: true)
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(ShieldRaceSnapshot.self, from: data) == s)
    }
}
