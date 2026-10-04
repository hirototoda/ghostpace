import Foundation
import Testing
@testable import FocusApp

struct DayBoundaryTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }

    private func jst(_ text: String) -> Date {
        LaunchOptions.parseDate(text, timeZone: TimeZone(identifier: "Asia/Tokyo")!)!
    }

    @Test func at4amTheNewDayStarts() {
        #expect(DayBoundary.dayStart(containing: jst("2026-10-19T04:00"), calendar: calendar) == jst("2026-10-19T04:00"))
        #expect(DayBoundary.dayKey(containing: jst("2026-10-19T04:00"), calendar: calendar) == "2026-10-19")
    }

    @Test func at359amItIsStillThePreviousDay() {
        #expect(DayBoundary.dayStart(containing: jst("2026-10-19T03:59"), calendar: calendar) == jst("2026-10-18T04:00"))
        #expect(DayBoundary.dayKey(containing: jst("2026-10-19T03:59"), calendar: calendar) == "2026-10-18")
    }

    @Test func lateEveningBelongsToSameDay() {
        #expect(DayBoundary.dayKey(containing: jst("2026-10-19T23:59"), calendar: calendar) == "2026-10-19")
    }
}
