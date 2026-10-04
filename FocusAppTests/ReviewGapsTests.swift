import Foundation
import Testing
@testable import FocusApp

/// 夜の振り返りのズレ（REV-01）。
struct ReviewGapsTests {
    private let c = DefaultCategories.all

    private func block(_ start: String, _ minutes: Int, _ name: String = "勉強") -> PlanSnapshotBlock {
        PlanSnapshotBlock(blockId: UUID(), startAt: jst(start), endAt: jst(start).addingTimeInterval(Double(minutes * 60)),
                          categoryId: c[0].id, categoryName: name, projectId: nil, projectName: nil)
    }

    private func started(from block: PlanSnapshotBlock, _ start: String, _ end: String) -> FocusSession {
        var s = session(start, end)
        s.planBlockId = block.blockId
        return s
    }

    @Test func picksTheTwoLargestGaps() {
        let a = block("2026-10-19T09:00", 90, "英語")     // 45分 → −45分
        let b = block("2026-10-19T11:00", 120, "ゼミ準備") // 0分 → −2時間
        let d = block("2026-10-19T14:00", 120, "卒論")    // 1時間40分 → −20分
        let sessions = [started(from: a, "2026-10-19T09:00", "2026-10-19T09:45"),
                        started(from: d, "2026-10-19T14:00", "2026-10-19T15:40")]
        let gaps = ReviewGaps.largest(snapshot: [a, b, d], sessions: sessions, now: jst("2026-10-19T22:30"))
        #expect(gaps.map(\.title) == ["ゼミ準備", "英語"])
        #expect(gaps[0].diffSeconds == -120 * 60)
    }

    @Test func overrunCountsAsGapToo() {
        let a = block("2026-10-19T09:00", 60)
        let sessions = [started(from: a, "2026-10-19T09:00", "2026-10-19T10:40")]
        let gaps = ReviewGaps.largest(snapshot: [a], sessions: sessions, now: jst("2026-10-19T22:30"))
        #expect(gaps.first?.diffSeconds == 40 * 60)
    }

    @Test func gapsUnder15MinutesAreHidden() {
        let a = block("2026-10-19T09:00", 60)
        let sessions = [started(from: a, "2026-10-19T09:00", "2026-10-19T09:46")]
        #expect(ReviewGaps.largest(snapshot: [a], sessions: sessions, now: jst("2026-10-19T22:30")).isEmpty)
        let b = block("2026-10-19T12:00", 60)
        let exactly15 = [started(from: b, "2026-10-19T12:00", "2026-10-19T12:45")]
        #expect(ReviewGaps.largest(snapshot: [b], sessions: exactly15, now: jst("2026-10-19T22:30")).count == 1)
    }

    @Test func unplannedSessionsDoNotFillABlock() {
        let a = block("2026-10-19T09:00", 60)
        let unplanned = [session("2026-10-19T09:00", "2026-10-19T10:00")]
        #expect(ReviewGaps.largest(snapshot: [a], sessions: unplanned, now: jst("2026-10-19T22:30")).first?.actualSeconds == 0)
    }

    @Test func sameGapKeepsTimeOrder() {
        let a = block("2026-10-19T09:00", 60, "A"), b = block("2026-10-19T07:00", 60, "B"), d = block("2026-10-19T12:00", 60, "C")
        let gaps = ReviewGaps.largest(snapshot: [a, b, d], sessions: [], now: jst("2026-10-19T22:30"))
        #expect(gaps.map(\.title) == ["B", "A"])
    }

    @Test func blocksNotFinishedYetAreSkipped() {
        let evening = block("2026-10-19T22:00", 60, "読書")
        let finished = block("2026-10-19T09:00", 60)
        let gaps = ReviewGaps.largest(snapshot: [evening, finished], sessions: [], now: jst("2026-10-19T22:30"))
        #expect(gaps.map(\.title) == ["勉強"])
        // ちょうど終わった時刻なら入る
        #expect(ReviewGaps.largest(snapshot: [evening], sessions: [], now: jst("2026-10-19T23:00")).count == 1)
    }
}
