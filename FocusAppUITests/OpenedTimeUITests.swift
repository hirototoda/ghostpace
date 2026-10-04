import XCTest

/// 開けた時間（DTX-05）：ホームの円の下と夜の振り返りに同じ値が出る。
@MainActor
final class OpenedTimeUITests: XCTestCase {
    private let timeout: TimeInterval = 10

    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func launch(_ time: String, _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-seedDemoData", "day", "-fixedNow", "\(time)+09:00"] + extra
        app.launch()
        return app
    }

    func testHomeAndReviewShowTheSameOpenedTime() {
        // 見本は 10:40 に15分・13:20 に10分開けた
        let home = launch("2026-10-19T14:30:00")
        let label = home.descendants(matching: .any)["openedLabel"]
        XCTAssertTrue(label.waitForExistence(timeout: timeout))
        XCTAssertEqual(label.label, "開けた 25分（2回）")

        let review = launch("2026-10-19T22:30:00", ["-openReview"])
        let reviewLabel = review.descendants(matching: .any).matching(identifier: "openedLabel").firstMatch
        XCTAssertTrue(reviewLabel.waitForExistence(timeout: timeout))
        XCTAssertEqual(reviewLabel.label, "開けた 25分（2回）")
        XCTAssertTrue(review.staticTexts["開けた時間"].waitForExistence(timeout: timeout))  // 勝ち負けの行（振り返りの下にホームもあるので、同じ部品が2つある）

        // まだ開けていない朝
        let morning = launch("2026-10-19T09:30:00")
        let none = morning.descendants(matching: .any)["openedLabel"]
        XCTAssertTrue(none.waitForExistence(timeout: timeout))
        XCTAssertEqual(none.label, "開けていない")
    }

    /// タイムライン（TML-05）：日付の下に出て、前の日へ戻るとその日の分に変わる
    func testTimelineShowsEachDaysOpenedTime() {
        // 見本は今日 25分2回、昨日（10/18）は 12:30 に25分・21:10 に15分
        let app = launch("2026-10-19T14:30:00", ["-openTimeline"])
        let label = app.descendants(matching: .any).matching(identifier: "timelineOpenedLabel").firstMatch
        XCTAssertTrue(label.waitForExistence(timeout: timeout))
        XCTAssertEqual(label.label, "開けた 25分（2回）")
        app.buttons["previousDayButton"].tap()
        let predicate = NSPredicate(format: "label == %@", "開けた 40分（2回）")
        expectation(for: predicate, evaluatedWith: app.descendants(matching: .any).matching(identifier: "timelineOpenedLabel").firstMatch)
        waitForExpectations(timeout: timeout)
    }
}
