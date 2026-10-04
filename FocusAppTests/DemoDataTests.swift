import Foundation
import SwiftData
import Testing
@testable import FocusApp

@MainActor
struct DemoDataTests {
    private let now = jst("2026-10-19T11:20")

    private func seeded(_ scene: DemoScene, at date: Date? = nil) throws -> TestStore {
        let t = try TestStore(now: date ?? now)
        try DemoData.seed(scene, into: t.store, calendar: tokyoCalendar)
        return t
    }

    @Test func demoIsDeterministic() throws {
        let a = try seeded(.day)
        let b = try seeded(.day)
        func summary(_ t: TestStore) throws -> [String] {
            try t.context.fetch(FetchDescriptor<FocusSessionRecord>(sortBy: [SortDescriptor(\.startAt)]))
                .map { "\($0.dayKey) \($0.startAt) \(String(describing: $0.endAt))" }
        }
        #expect(try summary(a) == summary(b))
    }

    @Test(arguments: DemoScene.allCases)
    func demoScene(_ scene: DemoScene) throws {
        let t = try seeded(scene)
        let lastWeek = try t.store.sessions(dayKey: "2026-10-12")
        #expect(lastWeek.isEmpty == (scene == .firstweek))
        #expect(try t.store.sessions(dayKey: "2026-09-28").isEmpty == (scene == .firstweek))

        let plan = try t.store.plan(dayKey: "2026-10-19")
        switch scene {
        case .morning: #expect(plan == nil)
        case .noplan: #expect(plan?.status == .skipped)
        case .gamePlan:
            // 朝の計画の下書きに、ゲーム・SNS の時間が2つ（BLK-10）
            #expect(plan?.status == .draft)
            #expect(plan?.draft.unblockCount == 2)
        default: #expect(plan?.status == .confirmed)
        }

        let running = try t.store.runningSession()
        switch scene {
        case .running:
            let r = try #require(running)
            #expect(r.startAt == now.addingTimeInterval(-23 * 60))
            // 実行中は今日の他のセッションと重ならない
            let others = try t.store.sessions(dayKey: "2026-10-19").filter { $0.id != r.id }
            #expect(others.allSatisfy { ($0.endAt ?? .distantFuture) <= r.startAt })
        case .forgot:
            let r = try #require(running)
            #expect(r.startAt == now.addingTimeInterval(-5 * 3600))
            #expect(r.plannedDurationSec == 25 * 60)
        case .offPlanAtBlock:
            // 35分前から計画外（60分）。その後に始まった計画ブロックに切り替えられる（TMR-11）
            let r = try #require(running)
            #expect(r.startAt == now.addingTimeInterval(-35 * 60))
            #expect(r.planBlockId == nil)
            #expect(r.plannedDurationSec == 60 * 60)
            let others = try t.store.sessions(dayKey: "2026-10-19").filter { $0.id != r.id }
            #expect(others.allSatisfy { ($0.endAt ?? .distantFuture) <= r.startAt })
        default:
            #expect(running == nil)
        }
    }

    @Test func forgotAcrossDayBoundaryLeavesTodayEmpty() throws {
        let t = try seeded(.forgot, at: jst("2026-10-20T04:10"))
        #expect(try t.store.runningSession()?.dayKey == "2026-10-19")
        #expect(try t.store.plan(dayKey: "2026-10-20") == nil)

        // 前日の他のセッションとは重ならず、終えるときに終了時刻を聞く（台本 J の前提）
        let running = try #require(try t.store.runningSession())
        let yesterday = try t.store.sessions(dayKey: "2026-10-19").filter { $0.id != running.id }
        #expect(yesterday.allSatisfy { ($0.endAt ?? .distantFuture) <= running.startAt })
        #expect(running.needsEndTimeCheck(at: jst("2026-10-20T04:10"), calendar: tokyoCalendar))
    }
}
