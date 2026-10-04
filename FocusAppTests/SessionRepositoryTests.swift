import Foundation
import SwiftData
import Testing
@testable import FocusApp

@MainActor
struct SessionRepositoryTests {
    private func request(_ category: CategoryOption, planBlockId: UUID? = nil, plannedEnd: Date? = nil,
                         minutes: Int? = nil, timeZone: TimeZone = tokyo) -> StartRequest {
        StartRequest(category: category, project: nil, planBlockId: planBlockId, plannedEndAt: plannedEnd,
                     plannedDurationSec: minutes.map { $0 * 60 }, timeZone: timeZone)
    }

    @Test func startPlannedSavesRunning() throws {
        let t = try TestStore(now: jst("2026-10-19T09:20"))
        let study = try t.seeded()[0]
        let blockId = UUID()
        let started = try t.store.start(request(study, planBlockId: blockId, plannedEnd: jst("2026-10-19T10:10")))

        let running = try #require(try t.store.runningSession())
        #expect(running == started)
        #expect(running.startAt == jst("2026-10-19T09:20"))
        #expect(running.endAt == nil)
        #expect(running.dayKey == "2026-10-19")
        #expect(running.planBlockId == blockId)
        #expect(running.plannedEndAt == jst("2026-10-19T10:10"))
        let record = try #require(try t.context.fetch(FetchDescriptor<FocusSessionRecord>()).first)
        #expect(record.timeZoneId == "Asia/Tokyo")
    }

    @Test func startUnplannedLengthAndStopwatch() throws {
        let t = try TestStore()
        let study = try t.seeded()[0]
        let length = try t.store.start(request(study, minutes: 25))
        #expect(length.plannedDurationSec == 1500)
        #expect(length.plannedEndAt == nil)
        _ = try t.store.end(id: length.id, reportedEnd: nil)

        let stopwatch = try t.store.start(request(study))
        #expect(stopwatch.plannedDurationSec == nil)
        #expect(stopwatch.plannedEndAt == nil)
    }

    @Test func startWhileRunningThrows() throws {
        let t = try TestStore()
        let study = try t.seeded()[0]
        _ = try t.store.start(request(study))
        #expect(throws: RecordError.alreadyRunning) { try t.store.start(request(study)) }
        #expect(try t.context.fetchCount(FetchDescriptor<FocusSessionRecord>()) == 1)
    }

    @Test func startDayKeyBoundary() throws {
        let t = try TestStore(now: jst("2026-10-19T03:59:59"))
        let study = try t.seeded()[0]
        let early = try t.store.start(request(study))
        #expect(early.dayKey == "2026-10-18")
        t.clock.set(jst("2026-10-19T04:05"))
        _ = try t.store.end(id: early.id, reportedEnd: nil)

        t.clock.set(jst("2026-10-19T04:00:00"))
        #expect(try t.store.start(request(study)).dayKey == "2026-10-19")
    }

    @Test func pauseResumePersist() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        let study = try t.seeded()[0]
        let s = try t.store.start(request(study))
        t.clock.set(jst("2026-10-19T09:10"))
        try t.store.pause(id: s.id)
        #expect(try t.store.runningSession()?.isPaused == true)
        t.clock.set(jst("2026-10-19T09:15"))
        try t.store.resume(id: s.id)

        let running = try #require(try t.store.runningSession())
        #expect(running.pauses == [PauseInterval(start: jst("2026-10-19T09:10"), end: jst("2026-10-19T09:15"))])
        #expect(!running.isPaused)
    }

    @Test func pauseResumeAreIdempotent() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        let study = try t.seeded()[0]
        let s = try t.store.start(request(study))
        try t.store.resume(id: s.id)
        #expect(try t.store.runningSession()?.pauses == [])

        t.clock.set(jst("2026-10-19T09:10"))
        try t.store.pause(id: s.id)
        t.clock.set(jst("2026-10-19T09:11"))
        try t.store.pause(id: s.id)
        #expect(try t.store.runningSession()?.pauses == [PauseInterval(start: jst("2026-10-19T09:10"), end: nil)])

        t.clock.set(jst("2026-10-19T09:20"))
        try t.store.resume(id: s.id)
        t.clock.set(jst("2026-10-19T09:30"))
        _ = try t.store.end(id: s.id, reportedEnd: nil)
        try t.store.pause(id: s.id)
        try t.store.resume(id: s.id)
        let ended = try #require(try t.store.sessions(dayKey: "2026-10-19").first)
        #expect(ended.pauseCount == 1)
        #expect(ended.endAt == jst("2026-10-19T09:30"))
    }

    @Test func endSaves() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        let study = try t.seeded()[0]
        let s = try t.store.start(request(study))
        t.clock.set(jst("2026-10-19T09:30"))
        #expect(try t.store.end(id: s.id, reportedEnd: nil) == .saved)
        #expect(try t.store.runningSession() == nil)
        #expect(try t.store.sessions(dayKey: "2026-10-19").first?.endAt == jst("2026-10-19T09:30"))
    }

    @Test(arguments: [(59.5, 0.0, true), (60.0, 0.0, false), (600.0, 570.0, true)])
    func endShortSessionDiscards(wallSeconds: Double, pausedSeconds: Double, discarded: Bool) throws {
        let start = jst("2026-10-19T09:00")
        let t = try TestStore(now: start)
        let study = try t.seeded()[0]
        let s = try t.store.start(request(study))
        if pausedSeconds > 0 {
            t.clock.set(start.addingTimeInterval(10))
            try t.store.pause(id: s.id)
            t.clock.set(start.addingTimeInterval(10 + pausedSeconds))
            try t.store.resume(id: s.id)
        }
        t.clock.set(start.addingTimeInterval(wallSeconds))
        let result = try t.store.end(id: s.id, reportedEnd: nil)
        #expect(result == (discarded ? .discardedTooShort : .saved))
        #expect(try t.context.fetchCount(FetchDescriptor<FocusSessionRecord>()) == (discarded ? 0 : 1))
    }

    @Test func endWithReportedEnd() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        let study = try t.seeded()[0]
        let s = try t.store.start(request(study, minutes: 25))
        t.clock.set(jst("2026-10-19T14:00"))
        #expect(try t.store.end(id: s.id, reportedEnd: jst("2026-10-19T09:25")) == .saved)
        let ended = try #require(try t.store.sessions(dayKey: "2026-10-19").first)
        #expect(ended.endAt == jst("2026-10-19T09:25"))
        #expect(ended.originalEndAt == jst("2026-10-19T14:00"))

        // 早めた結果が1分未満なら記録しない
        let short = try t.store.start(request(study))
        t.clock.set(jst("2026-10-19T15:00"))
        #expect(try t.store.end(id: short.id, reportedEnd: jst("2026-10-19T14:00:30")) == .discardedTooShort)
    }

    @Test func endWithReportedEndAtOrBeforeStartDiscards() throws {
        for reported in ["2026-10-19T09:00:00", "2026-10-19T08:59:59"] {
            let t = try TestStore(now: jst("2026-10-19T09:00"))
            let study = try t.seeded()[0]
            let s = try t.store.start(request(study))
            t.clock.set(jst("2026-10-19T09:30"))
            #expect(try t.store.end(id: s.id, reportedEnd: jst(reported)) == .discardedTooShort)
            #expect(try t.store.runningSession() == nil)
            #expect(try t.context.fetchCount(FetchDescriptor<FocusSessionRecord>()) == 0)
        }
    }

    @Test func endWithReportedEndAfterNowThrowsAndKeepsRunning() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        let study = try t.seeded()[0]
        let s = try t.store.start(request(study))
        t.clock.set(jst("2026-10-19T09:30"))
        #expect(throws: SessionError.invalidEnd) { try t.store.end(id: s.id, reportedEnd: jst("2026-10-19T09:31")) }
        #expect(try t.store.runningSession()?.id == s.id)
    }

    @Test func endTwiceIsNoOpAndUnknownIdThrows() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        let study = try t.seeded()[0]
        let s = try t.store.start(request(study))
        t.clock.set(jst("2026-10-19T09:30"))
        _ = try t.store.end(id: s.id, reportedEnd: nil)
        t.clock.set(jst("2026-10-19T09:40"))
        #expect(try t.store.end(id: s.id, reportedEnd: nil) == .saved)
        #expect(try t.store.sessions(dayKey: "2026-10-19").first?.endAt == jst("2026-10-19T09:30"))
        #expect(throws: RecordError.notFound) { try t.store.end(id: UUID(), reportedEnd: nil) }
        #expect(throws: RecordError.notFound) { try t.store.pause(id: UUID()) }
    }

    @Test func saveFailureKeepsRunning() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        let study = try t.seeded()[0]
        let s = try t.store.start(request(study))
        t.clock.set(jst("2026-10-19T09:30"))

        t.store.saveHook = { throw TestFailure() }
        #expect(throws: TestFailure.self) { try t.store.end(id: s.id, reportedEnd: nil) }
        #expect(try t.store.runningSession()?.id == s.id)
        #expect(try t.store.runningSession()?.endAt == nil)

        t.store.saveHook = nil
        #expect(try t.store.end(id: s.id, reportedEnd: nil) == .saved)
        #expect(try t.store.runningSession() == nil)
    }

    @Test func discardFailureKeepsRunning() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        let study = try t.seeded()[0]
        let s = try t.store.start(request(study))
        t.clock.set(jst("2026-10-19T09:00:10"))
        t.store.saveHook = { throw TestFailure() }
        #expect(throws: TestFailure.self) { try t.store.end(id: s.id, reportedEnd: nil) }
        #expect(try t.store.runningSession()?.id == s.id)
    }

    @Test func sessionsByDayKey() throws {
        let t = try TestStore(now: jst("2026-10-19T03:30"))
        let study = try t.seeded()[0]
        let night = try t.store.start(request(study))
        t.clock.set(jst("2026-10-19T04:30"))
        _ = try t.store.end(id: night.id, reportedEnd: nil)
        let morning = try t.store.start(request(study))
        t.clock.set(jst("2026-10-19T05:00"))
        _ = try t.store.end(id: morning.id, reportedEnd: nil)

        #expect(try t.store.sessions(dayKey: "2026-10-18").map(\.id) == [night.id])
        #expect(try t.store.sessions(dayKey: "2026-10-19").map(\.id) == [morning.id])
    }

    @Test func runningSurvivesNewContainer() throws {
        let url = temporaryStoreURL()
        defer { removeStoreFiles(url) }
        let started: FocusSession
        do {
            let t = try TestStore(now: jst("2026-10-19T10:00"), url: url)
            let study = try t.seeded()[0]
            started = try t.store.start(request(study))
        }
        let reopened = try TestStore(now: jst("2026-10-19T10:30"), url: url)
        let running = try #require(try reopened.store.runningSession())
        #expect(running.id == started.id)
        #expect(running.startAt == jst("2026-10-19T10:00"))
        #expect(running.activeSeconds(at: reopened.clock.now()) == 30 * 60)
    }

    @Test func corruptPausesJSONReadsAsEmpty() throws {
        let t = try TestStore()
        let study = try t.seeded()[0]
        _ = try t.store.start(request(study))
        let record = try #require(try t.context.fetch(FetchDescriptor<FocusSessionRecord>()).first)
        record.pausesJSON = Data("broken".utf8)
        try t.context.save()
        #expect(try t.store.runningSession()?.pauses == [])
    }

    @Test func duplicateRunningPicksLatest() throws {
        let t = try TestStore()
        let study = try t.seeded()[0]
        for start in ["2026-10-19T08:00", "2026-10-19T08:30"] {
            t.context.insert(FocusSessionRecord(dayKey: "2026-10-19", timeZoneId: "Asia/Tokyo", planBlockId: nil,
                                                categoryId: study.id, countsAsFocus: true, projectId: nil, startAt: jst(start),
                                                plannedEndAt: nil, plannedDurationSec: nil, at: jst(start)))
        }
        try t.context.save()
        #expect(try t.store.runningSession()?.startAt == jst("2026-10-19T08:30"))
    }

    @Test func unknownCategoryFallsBack() throws {
        let t = try TestStore()
        try t.seeded()
        t.context.insert(FocusSessionRecord(dayKey: "2026-10-19", timeZoneId: "Asia/Tokyo", planBlockId: nil,
                                            categoryId: UUID(), countsAsFocus: true, projectId: UUID(), startAt: jst("2026-10-19T08:00"),
                                            plannedEndAt: nil, plannedDurationSec: nil, at: jst("2026-10-19T08:00")))
        try t.context.save()
        let s = try #require(try t.store.sessions(dayKey: "2026-10-19").first)
        #expect(s.category == .unknown)
        #expect(s.category.name == "不明")
        // 集中かどうかは記録に残っている値を使う（カテゴリが見つからなくても集計は変わらない）
        #expect(s.category.countsAsFocus)
        #expect(s.project == nil)
    }

    @Test func shortenEndSavesAndKeepsFirstOriginal() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        let study = try t.seeded()[0]
        let s = try t.store.start(request(study))
        t.clock.set(jst("2026-10-19T14:00"))
        _ = try t.store.end(id: s.id, reportedEnd: nil)

        try t.store.shortenEnd(id: s.id, to: jst("2026-10-19T10:00"))
        try t.store.shortenEnd(id: s.id, to: jst("2026-10-19T09:30"))
        let saved = try #require(try t.store.sessions(dayKey: "2026-10-19").first)
        #expect(saved.endAt == jst("2026-10-19T09:30"))
        #expect(saved.originalEndAt == jst("2026-10-19T14:00"))
        #expect(throws: SessionError.invalidEnd) { try t.store.shortenEnd(id: s.id, to: jst("2026-10-19T12:00")) }
    }

    @Test func shortenEndAfterReportedEndKeepsFirstOriginal() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        let study = try t.seeded()[0]
        let s = try t.store.start(request(study))
        t.clock.set(jst("2026-10-19T14:00"))
        _ = try t.store.end(id: s.id, reportedEnd: jst("2026-10-19T11:00"))  // 終了時の「いつやめましたか？」
        try t.store.shortenEnd(id: s.id, to: jst("2026-10-19T10:00"))
        let saved = try #require(try t.store.sessions(dayKey: "2026-10-19").first)
        #expect(saved.endAt == jst("2026-10-19T10:00"))
        #expect(saved.originalEndAt == jst("2026-10-19T14:00"))
    }

    @Test func shortenEndUnderOneMinuteKeepsRecord() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        let study = try t.seeded()[0]
        let s = try t.store.start(request(study))
        t.clock.set(jst("2026-10-19T10:00"))
        _ = try t.store.end(id: s.id, reportedEnd: nil)
        try t.store.shortenEnd(id: s.id, to: jst("2026-10-19T09:00:30"))
        #expect(try t.store.sessions(dayKey: "2026-10-19").first?.endAt == jst("2026-10-19T09:00:30"))
    }

    @Test func shortenEndFailureRollsBack() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        let study = try t.seeded()[0]
        let s = try t.store.start(request(study))
        t.clock.set(jst("2026-10-19T10:00"))
        _ = try t.store.end(id: s.id, reportedEnd: nil)
        t.store.saveHook = { throw TestFailure() }
        #expect(throws: TestFailure.self) { try t.store.shortenEnd(id: s.id, to: jst("2026-10-19T09:30")) }
        t.store.saveHook = nil
        let saved = try #require(try t.store.sessions(dayKey: "2026-10-19").first)
        #expect(saved.endAt == jst("2026-10-19T10:00"))
        #expect(saved.originalEndAt == nil)
    }

    /// 「集中に数えるか」を後から変えても、過去の記録は開始したときのまま（2026-09-30 決定）
    @Test func countsAsFocusIsFrozenAtStart() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        let reading = try t.seeded()[2]
        let before = try t.store.start(request(reading))
        t.clock.set(jst("2026-10-19T09:30"))
        _ = try t.store.end(id: before.id, reportedEnd: nil)

        let record = try #require(try t.context.fetch(FetchDescriptor<CategoryRecord>()).first { $0.id == reading.id })
        record.countsAsFocus = false
        try t.context.save()
        let changed = try #require(try t.store.categories().first { $0.id == reading.id })
        let after = try t.store.start(request(changed))
        t.clock.set(jst("2026-10-19T10:00"))
        _ = try t.store.end(id: after.id, reportedEnd: nil)

        let sessions = try t.store.sessions(dayKey: "2026-10-19")
        #expect(sessions.map(\.category.countsAsFocus) == [true, false])
        #expect(sessions.map(\.category.name) == ["読書", "読書"])
    }

    @Test func archivedCategoryStillResolves() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        let reading = try t.seeded()[2]
        let s = try t.store.start(request(reading))
        t.clock.set(jst("2026-10-19T09:30"))
        _ = try t.store.end(id: s.id, reportedEnd: nil)
        let record = try #require(try t.context.fetch(FetchDescriptor<CategoryRecord>()).first { $0.id == reading.id })
        record.isArchived = true
        try t.context.save()

        let loaded = try #require(try t.store.sessions(dayKey: "2026-10-19").first)
        #expect(loaded.category.name == "読書")
        #expect(loaded.category.countsAsFocus)
    }
}

@MainActor
struct SchemaTests {
    @Test func fileStoreRoundTripsAllModels() throws {
        let url = temporaryStoreURL()
        defer { removeStoreFiles(url) }
        let now = jst("2026-10-19T09:00")
        let blockId = UUID()
        do {
            let container = try AppStore.makeContainer(url: url)
            let context = ModelContext(container)
            let category = CategoryRecord(name: "勉強", countsAsFocus: true, sortOrder: 0, at: now)
            let project = ProjectRecord(name: "ゼミ準備", categoryId: category.id, at: now)
            let plan = DailyPlanRecord(dayKey: "2026-10-19", timeZoneId: "Asia/Tokyo", statusRaw: "confirmed", at: now)
            plan.confirmedAt = now
            plan.snapshotJSON = Data("[]".utf8)
            let block = PlanBlockRecord(id: blockId, planId: plan.id, startAt: now, endAt: now.addingTimeInterval(3600),
                                        categoryId: category.id, projectId: project.id, at: now)
            block.isRemoved = true
            let session = FocusSessionRecord(dayKey: "2026-10-19", timeZoneId: "Asia/Tokyo", planBlockId: blockId,
                                             categoryId: category.id, countsAsFocus: true, projectId: project.id, startAt: now,
                                             plannedEndAt: now.addingTimeInterval(3600), plannedDurationSec: nil, at: now)
            session.endAt = now.addingTimeInterval(1800)
            session.originalEndAt = now.addingTimeInterval(7200)
            session.pausesJSON = PauseInterval.encode([PauseInterval(start: now.addingTimeInterval(60), end: now.addingTimeInterval(120))])
            session.note = "メモ"
            context.insert(category)
            context.insert(project)
            context.insert(plan)
            context.insert(block)
            context.insert(session)
            try context.save()
        }

        let context = ModelContext(try AppStore.makeContainer(url: url))
        #expect(try context.fetch(FetchDescriptor<CategoryRecord>()).first?.name == "勉強")
        #expect(try context.fetch(FetchDescriptor<ProjectRecord>()).first?.name == "ゼミ準備")
        let plan = try #require(try context.fetch(FetchDescriptor<DailyPlanRecord>()).first)
        #expect(plan.statusRaw == "confirmed" && plan.confirmedAt == now && plan.snapshotJSON == Data("[]".utf8))
        let block = try #require(try context.fetch(FetchDescriptor<PlanBlockRecord>()).first)
        #expect(block.id == blockId && block.isRemoved && block.projectId != nil)
        let session = try #require(try context.fetch(FetchDescriptor<FocusSessionRecord>()).first)
        #expect(session.endAt == now.addingTimeInterval(1800))
        #expect(session.originalEndAt == now.addingTimeInterval(7200))
        #expect(PauseInterval.decode(session.pausesJSON).count == 1)
        #expect(session.note == "メモ")
        #expect(session.plannedEndAt == now.addingTimeInterval(3600))
        #expect(session.countsAsFocus)
    }

    @Test func openFailureKeepsFile() throws {
        let url = temporaryStoreURL()
        defer { removeStoreFiles(url) }
        let garbage = Data(repeating: 0xAB, count: 4096)
        try garbage.write(to: url)

        #expect(throws: (any Error).self) { try AppStore.makeContainer(url: url) }
        #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        #expect(try Data(contentsOf: url) == garbage)
    }
}
