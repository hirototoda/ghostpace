import Foundation
import Testing
@testable import FocusApp

/// 一日の区切り（GHO-17、ADR-0023、data-model.md「DayBoundaryChange」）
struct DayBoundaryTests {
    // MARK: 履歴がないとき（朝4:00区切り、今までと同じ）

    @Test func at4amTheNewDayStarts() {
        let legacy = DayBoundary(calendar: tokyoCalendar)
        #expect(legacy.dayStart(containing: jst("2026-10-19T04:00")) == jst("2026-10-19T04:00"))
        #expect(legacy.dayKey(containing: jst("2026-10-19T04:00")) == "2026-10-19")
    }

    @Test func at359amItIsStillThePreviousDay() {
        let legacy = DayBoundary(calendar: tokyoCalendar)
        #expect(legacy.dayStart(containing: jst("2026-10-19T03:59")) == jst("2026-10-18T04:00"))
        #expect(legacy.dayKey(containing: jst("2026-10-19T03:59")) == "2026-10-18")
    }

    @Test func lateEveningBelongsToSameDay() {
        #expect(DayBoundary(calendar: tokyoCalendar).dayKey(containing: jst("2026-10-19T23:59")) == "2026-10-19")
    }

    /// 1b-79：行が0件のまま読んだときは、すべての日を朝4:00区切りで数える
    @Test func emptyHistoryCountsFromFourAm() {
        let legacy = DayBoundary(calendar: tokyoCalendar)
        let day = legacy.day(containing: jst("2026-10-21T21:00"))
        #expect(day.start == jst("2026-10-21T04:00"))
        #expect(day.end == jst("2026-10-22T04:00"))
        #expect(day.isLegacy)
    }

    // MARK: 区切り 22:00

    /// 1b-71：区切り 22:00 で 21:59:59 はその日、22:00:00 は次の日（日の名前は次の暦の日）
    @Test func startDayKeyBoundary() {
        let b = boundary([("2026-10-01", 1320)])
        #expect(b.dayKey(containing: jst("2026-10-20T21:59:59")) == "2026-10-20")
        #expect(b.dayKey(containing: jst("2026-10-20T22:00:00")) == "2026-10-21")
        let day = b.day(containing: jst("2026-10-20T22:30"))
        #expect(day.start == jst("2026-10-20T22:00"))
        #expect(day.end == jst("2026-10-21T22:00"))
        #expect(day.date == jst("2026-10-21T00:00"))
        #expect(!day.isLegacy)
        // 夜中も同じ日
        #expect(b.dayKey(containing: jst("2026-10-21T03:00")) == "2026-10-21")
    }

    /// 1b-80：日の名前は一日の中の 12:00 の日（区切り 20:00・0:00・1:00・翌4:00）
    @Test func dayKeyIsTheDayContainingNoon() {
        for minutes in [1200, 1440, 1500, 1680] {
            let b = boundary([("2026-10-01", minutes)])
            let day = b.day(containing: jst("2026-10-21T12:00"))
            #expect(day.key == "2026-10-21", "区切り \(minutes)")
            #expect(day.contains(jst("2026-10-21T12:00")))
        }
        // 区切り 20:00：20:00 からは次の日
        let evening = boundary([("2026-10-01", 1200)])
        #expect(evening.dayKey(containing: jst("2026-10-21T19:59")) == "2026-10-21")
        #expect(evening.dayKey(containing: jst("2026-10-21T20:00")) == "2026-10-22")
        // 区切り 1:00（夜中）：10/21 1:00〜10/22 1:00 が 10/21
        let midnight = boundary([("2026-10-01", 1500)])
        #expect(midnight.dayKey(containing: jst("2026-10-22T00:59")) == "2026-10-21")
        #expect(midnight.dayKey(containing: jst("2026-10-22T01:00")) == "2026-10-22")
        // 区切り 0:00
        let zero = boundary([("2026-10-01", 1440)])
        #expect(zero.dayKey(containing: jst("2026-10-21T23:59")) == "2026-10-21")
        #expect(zero.dayKey(containing: jst("2026-10-22T00:00")) == "2026-10-22")
    }

    // MARK: 設定を変えた次の日（24時間でない日）

    /// 1b-75・1b-81：22:00 → 23:00 にした次の日は25時間、その先は 23:00 区切り
    @Test func changingTheBoundaryMakesTheNextDayLonger() {
        let b = boundary([("2026-10-01", 1320), ("2026-10-22", 1380)])
        let today = b.day(containing: jst("2026-10-21T15:00"))
        #expect(today.end == jst("2026-10-21T22:00"))
        let next = b.day(1, from: today)
        #expect(next.key == "2026-10-22")
        #expect(next.start == jst("2026-10-21T22:00"))
        #expect(next.end == jst("2026-10-22T23:00"))
        #expect(next.duration == 25 * 3600)
        #expect(b.day(2, from: today).duration == 24 * 3600)
    }

    /// 1b-81：22時間（22:00→20:00）・32時間（20:00→翌4:00）・16時間（翌4:00→20:00）
    @Test func shortAndLongDays() {
        #expect(boundary([("2026-10-01", 1320), ("2026-10-22", 1200)]).day(key: "2026-10-22")?.duration == TimeInterval(22 * 3600))
        #expect(boundary([("2026-10-01", 1200), ("2026-10-22", 1680)]).day(key: "2026-10-22")?.duration == TimeInterval(32 * 3600))
        #expect(boundary([("2026-10-01", 1680), ("2026-10-22", 1200)]).day(key: "2026-10-22")?.duration == TimeInterval(16 * 3600))
    }

    /// 1b-77：移した日は 4:00 区切りのまま、次の日が 4:00〜22:00 の18時間、その次から 22:00 区切り
    @Test func migrationDayThenEighteenHourDay() {
        let b = boundary([("2026-10-23", 1320)])
        let migrated = b.day(containing: jst("2026-10-22T15:00"))
        #expect(migrated.key == "2026-10-22")
        #expect(migrated.isLegacy)
        #expect(migrated.start == jst("2026-10-22T04:00"))
        #expect(migrated.end == jst("2026-10-23T04:00"))
        let short = b.day(1, from: migrated)
        #expect(short.start == jst("2026-10-23T04:00"))
        #expect(short.end == jst("2026-10-23T22:00"))
        #expect(!short.isLegacy)
        let normal = b.day(2, from: migrated)
        #expect(normal.start == jst("2026-10-23T22:00"))
        #expect(normal.end == jst("2026-10-24T22:00"))
        // 過去の日は変わらない
        #expect(b.dayStart(containing: jst("2026-10-15T03:59")) == jst("2026-10-14T04:00"))
    }

    /// 先週の同じ曜日は 7日前の日の名前（区切りが違っても）
    @Test func sameDayLastWeekUsesTheDayName() {
        let b = boundary([("2026-10-23", 1320)])
        let today = b.day(containing: jst("2026-10-28T09:00"))
        #expect(b.sameDayLastWeek(today.start) == jst("2026-10-21T04:00"))
    }

    // MARK: 読み方（1b-82）

    @Test func boundaryHistoryRoundsOutOfRangeValues() {
        #expect(DayBoundary.normalized(1320) == 1320)
        #expect(DayBoundary.normalized(1334) == 1320)
        #expect(DayBoundary.normalized(1336) == 1350)
        #expect(DayBoundary.normalized(600) == 1200)
        #expect(DayBoundary.normalized(2000) == 1680)
        #expect(boundary([("2026-10-01", 2000)]).endMinutes(key: "2026-10-21") == 1680)
        #expect(DayBoundary.choices.count == 17)
        #expect(DayBoundary.choices.first == 1200)
        #expect(DayBoundary.choices.last == 1680)
    }

    @Test func duplicateFromDayKeyPicksNewest() {
        let b = DayBoundary(calendar: tokyoCalendar, changes: [
            DayBoundaryChange(fromDayKey: "2026-10-22", endMinutes: 1380, updatedAt: jst("2026-10-21T10:00")),
            DayBoundaryChange(fromDayKey: "2026-10-22", endMinutes: 1260, updatedAt: jst("2026-10-21T11:00")),
            DayBoundaryChange(fromDayKey: "2026-10-22", endMinutes: 1440, updatedAt: jst("2026-10-21T09:00")),
        ])
        #expect(b.endMinutes(key: "2026-10-22") == 1260)
    }

    // MARK: 朝の計画を出す時刻（1b-73・1b-80）

    @Test func morningPlanHiddenBetweenBoundaryAndFour() {
        let b = boundary([("2026-10-01", 1320)])
        #expect(!b.isMorning(jst("2026-10-20T22:00")))
        #expect(!b.isMorning(jst("2026-10-21T03:59")))
        #expect(b.isMorning(jst("2026-10-21T04:00")))
        #expect(b.isMorning(jst("2026-10-21T21:59")))
        // 区切り 1:00：1:00〜3:59 は出さない
        let midnight = boundary([("2026-10-01", 1500)])
        #expect(midnight.isMorning(jst("2026-10-22T00:30")))
        #expect(!midnight.isMorning(jst("2026-10-22T01:00")))
        #expect(midnight.isMorning(jst("2026-10-22T04:00")))
        // 区切り 翌4:00：出さない時間帯はない
        let four = boundary([("2026-10-01", 1680)])
        #expect(four.isMorning(jst("2026-10-22T03:59")))
        #expect(four.isMorning(jst("2026-10-22T04:00")))
    }
}
