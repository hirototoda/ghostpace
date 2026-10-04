import Testing
@testable import FocusApp

struct DurationFormatTests {
    @Test func clockUsesHoursOnlyWhenNeeded() {
        #expect(DurationFormat.clock(4620) == "1:17:00")
        #expect(DurationFormat.clock(1390) == "23:10")
        #expect(DurationFormat.clock(-5) == "00:00")
    }

    @Test func japanese() {
        #expect(DurationFormat.japanese(5400) == "1時間30分")
        #expect(DurationFormat.japanese(3600) == "1時間")
        #expect(DurationFormat.japanese(3900) == "1時間05分")
        #expect(DurationFormat.japanese(1500) == "25分")
        #expect(DurationFormat.japanese(59) == "0分")
    }

    @Test func signedShowsLeadAndBehind() {
        #expect(DurationFormat.signed(1500) == "+25分")
        #expect(DurationFormat.signed(-3300) == "−55分")
        #expect(DurationFormat.signed(0) == "+0分")
    }
}
