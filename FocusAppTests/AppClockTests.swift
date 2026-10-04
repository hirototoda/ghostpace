import Foundation
import Testing
@testable import FocusApp

struct AppClockTests {
    @Test func fixedClockAlwaysReturnsSameDate() {
        let date = Date(timeIntervalSince1970: 1_792_000_000)
        let clock = FixedClock(date: date)

        #expect(clock.now() == date)
        #expect(clock.now() == date)
    }

    @Test func offsetClockStartsAtGivenDateAndAdvancesWithBase() {
        let realStart = Date(timeIntervalSince1970: 1_700_000_000)
        let fakeStart = Date(timeIntervalSince1970: 1_792_000_000)
        let base = MutableClock(realStart)
        let clock = OffsetClock(startingAt: fakeStart, base: base)

        #expect(clock.now() == fakeStart)

        base.set(realStart.addingTimeInterval(90))
        #expect(clock.now() == fakeStart.addingTimeInterval(90))
    }
}
