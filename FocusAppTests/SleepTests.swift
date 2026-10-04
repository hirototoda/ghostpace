import Foundation
import SwiftData
import Testing
@testable import FocusApp

/// 睡眠（digital-detox.md「睡眠」、DTX-02）。
struct SleepPickerTests {
    private let dayStart = jst("2026-10-19T04:00")

    private func interval(_ start: String, _ end: String) -> DateInterval {
        DateInterval(start: jst(start), end: jst(end))
    }

    @Test func picksTheLongestStretchAndSkipsNaps() {
        let samples = [
            interval("2026-10-19T00:10", "2026-10-19T03:00"),
            interval("2026-10-19T03:40", "2026-10-19T07:05"),   // 40分あいただけなので同じまとまり
            interval("2026-10-19T13:00", "2026-10-19T13:40"),   // 昼寝
        ]
        #expect(SleepPicker.pick(samples, dayStart: dayStart, calendar: tokyoCalendar)
                == interval("2026-10-19T00:10", "2026-10-19T07:05"))
    }

    @Test func rangeEdgesAndExactHourGap() {
        // 18:00 ちょうどから・14:00 ちょうどまで
        let edges = [interval("2026-10-18T17:00", "2026-10-18T18:00"), interval("2026-10-19T14:00", "2026-10-19T15:00")]
        #expect(SleepPicker.pick(edges, dayStart: dayStart, calendar: tokyoCalendar) == nil)
        // ちょうど1時間あいたら別のまとまり
        let split = [interval("2026-10-19T00:00", "2026-10-19T01:00"), interval("2026-10-19T02:00", "2026-10-19T02:30")]
        #expect(SleepPicker.pick(split, dayStart: dayStart, calendar: tokyoCalendar)
                == interval("2026-10-19T00:00", "2026-10-19T01:00"))
    }

    @Test func gapOfAnHourSplits() {
        let samples = [interval("2026-10-19T00:00", "2026-10-19T02:00"), interval("2026-10-19T03:00", "2026-10-19T04:30")]
        #expect(SleepPicker.pick(samples, dayStart: dayStart, calendar: tokyoCalendar)
                == interval("2026-10-19T00:00", "2026-10-19T02:00"))
    }

    @Test func tieGoesToTheLaterOne() {
        let samples = [interval("2026-10-18T19:00", "2026-10-18T20:00"), interval("2026-10-19T06:00", "2026-10-19T07:00")]
        #expect(SleepPicker.pick(samples, dayStart: dayStart, calendar: tokyoCalendar)
                == interval("2026-10-19T06:00", "2026-10-19T07:00"))
    }

    @Test func onlyFromSixPmToTwoPm() {
        let (from, to) = SleepPicker.searchRange(dayStart: dayStart, calendar: tokyoCalendar)
        #expect(from == jst("2026-10-18T18:00"))
        #expect(to == jst("2026-10-19T14:00"))
        #expect(SleepPicker.pick([interval("2026-10-19T15:00", "2026-10-19T16:00")], dayStart: dayStart,
                                 calendar: tokyoCalendar) == nil)
    }

    @Test func settingTimesMapToTheDay() {
        let usual = SleepLine.fromSetting(startMinutes: 0, endMinutes: 7 * 60, dayStart: dayStart, calendar: tokyoCalendar)
        #expect(usual == SleepLine(start: jst("2026-10-19T00:00"), end: jst("2026-10-19T07:00"), source: .setting))
        // 23:00〜6:00 は前の夜から
        let late = SleepLine.fromSetting(startMinutes: 23 * 60, endMinutes: 6 * 60, dayStart: dayStart, calendar: tokyoCalendar)
        #expect(late.start == jst("2026-10-18T23:00"))
        #expect(late.end == jst("2026-10-19T06:00"))
    }

    @Test func editedStartMovesToTheNightBefore() {
        #expect(SleepLine.normalizedStart(jst("2026-10-19T23:30"), end: jst("2026-10-19T07:00")) == jst("2026-10-18T23:30"))
        #expect(SleepLine.normalizedStart(jst("2026-10-19T00:30"), end: jst("2026-10-19T07:00")) == jst("2026-10-19T00:30"))
    }

    @Test func unknownSourceIsTreatedAsManual() {
        #expect(SleepLine.Source(raw: "later") == .manual)
    }
}

/// 保存と、第2版からの移行（NFR-02）。
@MainActor
struct SleepStoreTests {
    @Test func savesAndOverwrites() throws {
        let t = try TestStore(now: jst("2026-10-19T07:30"))
        let line = SleepLine(start: jst("2026-10-19T00:10"), end: jst("2026-10-19T07:05"), source: .health)
        try t.store.saveSleep(line, dayKey: "2026-10-19", timeZone: tokyo)
        #expect(try t.store.sleep(dayKey: "2026-10-19") == line)
        var manual = line
        manual.source = .manual
        manual.start = jst("2026-10-18T23:30")
        try t.store.saveSleep(manual, dayKey: "2026-10-19", timeZone: tokyo)
        // 手で直したら、直す前の値も残る（第4版）
        manual.original = DateInterval(start: line.start, end: line.end)
        #expect(try t.store.sleep(dayKey: "2026-10-19") == manual)
        #expect(try t.store.sleep(dayKey: "2026-10-18") == nil)
    }

    @Test func version2StoreOpensWithVersion3() throws {
        let url = temporaryStoreURL()
        defer { removeStoreFiles(url) }
        let now = jst("2026-10-19T09:00")
        let categoryId = UUID(), templateId = UUID()
        do {
            let schema = Schema(versionedSchema: SchemaV2.self)
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url,
                                                                                               cloudKitDatabase: .none))
            let context = ModelContext(container)
            context.insert(SchemaV2.CategoryRecord(id: categoryId, name: "勉強", countsAsFocus: true, sortOrder: 0, at: now))
            let plan = SchemaV2.DailyPlanRecord(dayKey: "2026-10-19", timeZoneId: "Asia/Tokyo", statusRaw: "confirmed", at: now)
            plan.goalFocusSec = 3 * 3600
            plan.goalEdited = true
            context.insert(plan)
            context.insert(SchemaV2.PlanTemplateRecord(id: templateId, name: "平日", sortOrder: 0, blocksJSON: Data("[]".utf8), at: now))
            try context.save()
        }
        let container = try AppStore.makeContainer(url: url)
        let store = SwiftDataStore(container: container, clock: FixedClock(date: now))
        #expect(try store.categories().map(\.name) == ["勉強"])
        #expect(try store.plan(dayKey: "2026-10-19")?.draft.goalSeconds == 3 * 3600)
        #expect(try store.templates().map(\.id) == [templateId])
        #expect(try store.sleep(dayKey: "2026-10-19") == nil)
        // 第3版で睡眠を書ける
        try store.saveSleep(SleepLine(start: jst("2026-10-19T00:00"), end: jst("2026-10-19T07:00"), source: .setting),
                            dayKey: "2026-10-19", timeZone: tokyo)
        #expect(try store.sleep(dayKey: "2026-10-19")?.source == .setting)
    }
}

/// 本体（AppModel）での睡眠。
@MainActor
struct SleepModelTests {
    private func model(_ t: TestStore, source: NoSleepSource = NoSleepSource(), settings: MemorySettings = MemorySettings()) -> AppModel {
        settings.didShowBlockingIntro = true
        return AppModel(store: t.store, clock: t.clock, timeZone: { tokyo }, settings: settings, sleepSource: source)
    }

    private let lastNight = DateInterval(start: jst("2026-10-19T00:10"), end: jst("2026-10-19T07:05"))

    @Test func firstOpenSavesTheSettingTimes() throws {
        let t = try TestStore(now: jst("2026-10-19T07:30"))
        try t.seeded()
        let m = model(t)
        let line = try #require(m.sleepLine(dayStart: jst("2026-10-19T04:00")))
        #expect(line == SleepLine(start: jst("2026-10-19T00:00"), end: jst("2026-10-19T07:00"), source: .setting))
        // 開かなかった前の日も、設定の時刻で保存する
        #expect(try t.store.sleep(dayKey: "2026-10-18")?.source == .setting)
    }

    /// 保存したあとで設定を変えても、保存した日は変わらない
    @Test func changingSettingsLaterKeepsSavedDays() throws {
        let t = try TestStore(now: jst("2026-10-19T07:30"))
        try t.seeded()
        let m = model(t)
        m.setSleepSetting(startMinutes: 23 * 60, endMinutes: 6 * 60)
        m.reload()
        #expect(m.sleepLine(dayStart: jst("2026-10-19T04:00"))?.start == jst("2026-10-19T00:00"))
        t.clock.set(jst("2026-10-20T07:00"))
        m.reload()
        #expect(m.sleepLine(dayStart: jst("2026-10-20T04:00"))?.start == jst("2026-10-19T23:00"))
    }

    @Test func healthReplacesSettingTimesTheSameDay() async throws {
        let t = try TestStore(now: jst("2026-10-19T07:30"))
        try t.seeded()
        let source = NoSleepSource(isAvailable: true, intervals: [lastNight])
        let m = model(t, source: source)
        await m.refreshSleep()
        #expect(m.sleepLine(dayStart: jst("2026-10-19T04:00"))
                == SleepLine(start: lastNight.start, end: lastNight.end, source: .health))
        #expect(try t.store.sleep(dayKey: "2026-10-19")?.source == .health)
    }

    @Test func manualIsNotReplaced() async throws {
        let t = try TestStore(now: jst("2026-10-19T07:30"))
        try t.seeded()
        let source = NoSleepSource(isAvailable: true)
        let m = model(t, source: source)
        #expect(m.setSleepManually(start: jst("2026-10-18T23:30"), end: jst("2026-10-19T06:30")))
        source.intervals = [lastNight]
        await m.refreshSleep()
        #expect(m.sleepLine(dayStart: jst("2026-10-19T04:00"))?.source == .manual)
        #expect(m.sleepLine(dayStart: jst("2026-10-19T04:00"))?.start == jst("2026-10-18T23:30"))
    }

    /// 翌朝4:00 を過ぎたら、前の日の睡眠は置き換えない
    @Test func pastDaysAreNotReplaced() async throws {
        let t = try TestStore(now: jst("2026-10-19T07:30"))
        try t.seeded()
        let source = NoSleepSource(isAvailable: true)
        let m = model(t, source: source)
        t.clock.set(jst("2026-10-20T04:10"))
        source.intervals = [lastNight]
        await m.refreshSleep()
        #expect(try t.store.sleep(dayKey: "2026-10-19")?.source == .setting)
    }

    @Test func invalidManualTimesAreRejected() throws {
        let t = try TestStore(now: jst("2026-10-19T07:30"))
        try t.seeded()
        let m = model(t)
        #expect(!m.setSleepManually(start: jst("2026-10-19T07:00"), end: jst("2026-10-19T06:00")))
        #expect(m.errorMessage == AppModel.invalidSleepMessage)
        #expect(m.sleepLine(dayStart: jst("2026-10-19T04:00"))?.source == .setting)
    }

    @Test func asksHealthOnlyUntilRequested() async throws {
        let t = try TestStore(now: jst("2026-10-19T07:30"))
        try t.seeded()
        let source = NoSleepSource(isAvailable: true, needsRequest: true, intervals: [lastNight])
        let m = model(t, source: source)
        await m.refreshSleep()
        #expect(m.healthNeedsRequest)
        await m.requestHealthAccess()
        #expect(!m.healthNeedsRequest)
        #expect(m.sleepLine(dayStart: jst("2026-10-19T04:00"))?.source == .health)
    }

    @Test func settingsPersistSleepTimes() throws {
        let suite = "settings-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = UserDefaultsSettings(defaults: defaults)
        #expect(settings.sleepStartMinutes == 0)
        #expect(settings.sleepEndMinutes == 7 * 60)
        settings.sleepStartMinutes = 23 * 60 + 30
        let reopened = UserDefaultsSettings(defaults: try #require(UserDefaults(suiteName: suite)))
        #expect(reopened.sleepStartMinutes == 23 * 60 + 30)
        defaults.removePersistentDomain(forName: suite)
    }

    // MARK: 境界（レビューで足した）

    @Test func fillsOnlyTheLastSevenDaysAndKeepsSavedOnes() throws {
        let t = try TestStore(now: jst("2026-10-19T07:30"))
        try t.seeded()
        let saved = SleepLine(start: jst("2026-10-17T01:00"), end: jst("2026-10-17T08:00"), source: .manual)
        try t.store.saveSleep(saved, dayKey: "2026-10-17", timeZone: tokyo)
        _ = model(t)
        #expect(try t.store.sleep(dayKey: "2026-10-13")?.source == .setting)
        #expect(try t.store.sleep(dayKey: "2026-10-12") == nil)
        #expect(try t.store.sleep(dayKey: "2026-10-17") == saved)
    }

    /// 3:59 はまだ前の日（置き換えられる）、4:00 からは新しい日
    @Test func fourAmBoundary() async throws {
        let t = try TestStore(now: jst("2026-10-20T03:59"))
        try t.seeded()
        let source = NoSleepSource(isAvailable: true, intervals: [lastNight])
        let m = model(t, source: source)
        #expect(m.sleepLine(dayStart: jst("2026-10-19T04:00")) != nil)
        await m.refreshSleep()
        #expect(try t.store.sleep(dayKey: "2026-10-19")?.source == .health)
        t.clock.set(jst("2026-10-20T04:00"))
        m.reload()
        #expect(m.sleepLine(dayStart: jst("2026-10-19T04:00")) == nil)
        #expect(m.sleepLine(dayStart: jst("2026-10-20T04:00"))?.source == .setting)
    }

    @Test func dayOrLongerIsRejected() throws {
        let t = try TestStore(now: jst("2026-10-19T07:30"))
        try t.seeded()
        let m = model(t)
        #expect(!m.setSleepManually(start: jst("2026-10-18T07:00"), end: jst("2026-10-19T07:00")))
        #expect(m.setSleepManually(start: jst("2026-10-18T07:05"), end: jst("2026-10-19T07:00")))
    }

    @Test func settingsPersistBothEnds() throws {
        let suite = "settings-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = UserDefaultsSettings(defaults: defaults)
        settings.sleepEndMinutes = 6 * 60 + 45
        #expect(UserDefaultsSettings(defaults: try #require(UserDefaults(suiteName: suite))).sleepEndMinutes == 6 * 60 + 45)
        defaults.removePersistentDomain(forName: suite)
    }

    @Test func sameStartAndEndSettingIsIgnored() throws {
        let t = try TestStore(now: jst("2026-10-19T07:30"))
        try t.seeded()
        let m = model(t)
        m.setSleepSetting(startMinutes: 7 * 60, endMinutes: 7 * 60)
        #expect(m.sleepStartMinutes == 0)
        #expect(m.sleepEndMinutes == 7 * 60)
    }

    // MARK: 朝の計画の確定で決める（2026-10-03）

    private func confirm(_ m: AppModel) async {
        m.confirmPlan(PlanDraft(blocks: [PlanBlockDraft(start: jst("2026-10-19T09:00"), minutes: 60, category: m.categories[0])]))
        await m.confirmSleepTask?.value
    }

    /// 開いた時点ではまだ Garmin が同期していなくても、確定した時点で読み直してヘルスケアの値にする
    @Test func confirmingReadsHealthAgain() async throws {
        let t = try TestStore(now: jst("2026-10-19T07:30"))
        try t.seeded()
        let source = NoSleepSource(isAvailable: true)
        let m = model(t, source: source)
        await m.refreshSleep()
        #expect(m.sleepLine(dayStart: jst("2026-10-19T04:00"))?.source == .setting)
        source.intervals = [lastNight]
        await confirm(m)
        #expect(m.sleepLine(dayStart: jst("2026-10-19T04:00"))
                == SleepLine(start: lastNight.start, end: lastNight.end, source: .health))
    }

    /// 確定してヘルスケアの値で決まったら、あとでヘルスケアが変わっても置き換えない（昼寝が長くても）
    @Test func confirmedHealthIsKept() async throws {
        let t = try TestStore(now: jst("2026-10-19T07:30"))
        try t.seeded()
        let source = NoSleepSource(isAvailable: true, intervals: [lastNight])
        let m = model(t, source: source)
        await confirm(m)
        t.clock.set(jst("2026-10-19T15:00"))
        source.intervals = [DateInterval(start: jst("2026-10-19T00:10"), end: jst("2026-10-19T08:30"))]
        await m.refreshSleep()
        await m.refreshSleep(onlyIfSetting: true)
        #expect(m.sleepLine(dayStart: jst("2026-10-19T04:00"))?.end == lastNight.end)
        // 開き直しても同じ
        let reopened = model(t, source: source)
        await reopened.refreshSleep()
        #expect(reopened.sleepLine(dayStart: jst("2026-10-19T04:00"))?.end == lastNight.end)
    }

    /// 確定した時点でヘルスケアになければ設定の時刻のまま。その日のうちに入ったら1回だけ置き換え、そこで決まる
    @Test func confirmedWithoutHealthIsReplacedOnceLater() async throws {
        let t = try TestStore(now: jst("2026-10-19T07:30"))
        try t.seeded()
        let source = NoSleepSource(isAvailable: true)
        let m = model(t, source: source)
        await confirm(m)
        #expect(m.sleepLine(dayStart: jst("2026-10-19T04:00"))?.source == .setting)
        t.clock.set(jst("2026-10-19T09:00"))
        source.intervals = [lastNight]
        await m.refreshSleep(onlyIfSetting: true)
        #expect(m.sleepLine(dayStart: jst("2026-10-19T04:00"))?.source == .health)
        source.intervals = [DateInterval(start: jst("2026-10-19T00:10"), end: jst("2026-10-19T08:30"))]
        await m.refreshSleep()
        #expect(m.sleepLine(dayStart: jst("2026-10-19T04:00"))?.end == lastNight.end)
    }

    /// 確定前（計画しない日も）は今までどおり、その日のうちはヘルスケアの新しい値に置き換える
    @Test func beforeConfirmHealthKeepsUpdating() async throws {
        let t = try TestStore(now: jst("2026-10-19T07:30"))
        try t.seeded()
        let source = NoSleepSource(isAvailable: true, intervals: [lastNight])
        let m = model(t, source: source)
        m.skipPlan()
        await m.refreshSleep()
        let later = DateInterval(start: jst("2026-10-19T00:10"), end: jst("2026-10-19T08:30"))
        source.intervals = [later]
        await m.refreshSleep()
        #expect(m.sleepLine(dayStart: jst("2026-10-19T04:00"))?.end == later.end)
    }

    /// 前の日に確定していても、4:00 を過ぎた新しい日はまた置き換えられる（確定は日ごと）
    @Test func settledOnlyForTheConfirmedDay() async throws {
        let t = try TestStore(now: jst("2026-10-19T07:30"))
        try t.seeded()
        let source = NoSleepSource(isAvailable: true, intervals: [lastNight])
        let m = model(t, source: source)
        await confirm(m)
        t.clock.set(jst("2026-10-20T03:59"))
        m.reload()
        #expect(m.isPlanConfirmed)
        t.clock.set(jst("2026-10-20T04:00"))
        m.reload()
        #expect(!m.isPlanConfirmed)
        source.intervals = [DateInterval(start: jst("2026-10-20T00:30"), end: jst("2026-10-20T06:40"))]
        await m.refreshSleep()
        await m.refreshSleep()
        #expect(m.sleepLine(dayStart: jst("2026-10-20T04:00"))?.end == jst("2026-10-20T06:40"))
    }

    /// ヘルスケアを使えない（許可がない・記録がない）ときは、確定しても設定の時刻のまま
    @Test func confirmingWithoutHealthKeepsSetting() async throws {
        let t = try TestStore(now: jst("2026-10-19T07:30"))
        try t.seeded()
        let m = model(t, source: NoSleepSource(isAvailable: false, intervals: [lastNight]))
        await confirm(m)
        #expect(m.sleepLine(dayStart: jst("2026-10-19T04:00"))?.source == .setting)
    }

    /// 手で直した睡眠は、確定しても置き換えない
    @Test func confirmingKeepsManual() async throws {
        let t = try TestStore(now: jst("2026-10-19T07:30"))
        try t.seeded()
        let source = NoSleepSource(isAvailable: true)
        let m = model(t, source: source)
        #expect(m.setSleepManually(start: jst("2026-10-18T23:30"), end: jst("2026-10-19T06:30")))
        source.intervals = [lastNight]
        await confirm(m)
        #expect(m.sleepLine(dayStart: jst("2026-10-19T04:00"))?.source == .manual)
    }

    /// 1分ごとの読み直しは、まだ設定の時刻の日だけ
    @Test func minuteRefreshOnlyWhileSetting() async throws {
        let t = try TestStore(now: jst("2026-10-19T07:30"))
        try t.seeded()
        let source = NoSleepSource(isAvailable: true)
        let m = model(t, source: source)
        #expect(m.setSleepManually(start: jst("2026-10-18T23:30"), end: jst("2026-10-19T06:30")))
        source.intervals = [lastNight]
        await m.refreshSleep(onlyIfSetting: true)
        #expect(m.sleepLine(dayStart: jst("2026-10-19T04:00"))?.source == .manual)
    }
}
