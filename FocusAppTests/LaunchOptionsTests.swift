import Foundation
import Testing
@testable import FocusApp

struct LaunchOptionsTests {
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    @Test func noArgumentsMeansRealTimeAndNoDemoData() {
        let options = LaunchOptions.parse(["FocusApp"], timeZone: tokyo)

        #expect(options == LaunchOptions())
    }

    @Test func fixedNowWithoutTimeZoneUsesGivenTimeZone() throws {
        let options = LaunchOptions.parse(["FocusApp", "-fixedNow", "2026-10-19T14:30"], timeZone: tokyo)

        let fixedNow = try #require(options.fixedNow)
        // 2026-10-19 14:30 JST = 05:30 UTC
        #expect(fixedNow == Date(timeIntervalSince1970: 1_792_387_800))
    }

    @Test func fixedNowAcceptsSeconds() throws {
        let options = LaunchOptions.parse(["-fixedNow", "2026-10-19T14:30:15"], timeZone: tokyo)

        #expect(try #require(options.fixedNow) == Date(timeIntervalSince1970: 1_792_387_815))
    }

    @Test func fixedNowAcceptsExplicitUTC() throws {
        let options = LaunchOptions.parse(["-fixedNow", "2026-10-19T05:30:00Z"], timeZone: tokyo)

        #expect(try #require(options.fixedNow) == Date(timeIntervalSince1970: 1_792_387_800))
    }

    @Test func invalidOrMissingFixedNowIsIgnored() {
        #expect(LaunchOptions.parse(["-fixedNow", "yesterday"], timeZone: tokyo).fixedNow == nil)
        #expect(LaunchOptions.parse(["-fixedNow"], timeZone: tokyo).fixedNow == nil)
    }

    @Test func seedDemoDataSceneParsing() {
        let plain = LaunchOptions.parse(["-seedDemoData", "-fixedNow", "2026-10-19T14:30"], timeZone: tokyo)
        #expect(plain.demoScene == .day)
        #expect(plain.fixedNow != nil)

        #expect(LaunchOptions.parse(["-seedDemoData", "running"]).demoScene == .running)

        // 知らない名前は場面として読まず、次の処理に回す
        let unknown = LaunchOptions.parse(["-seedDemoData", "dawn", "-inMemoryStore"])
        #expect(unknown.demoScene == .day)
        #expect(unknown.inMemoryStore)
    }

    @Test func storeOptions() {
        let options = LaunchOptions.parse(["-storeName", "ui-a", "-resetStore", "-failSave", "-failStoreOpen", "-inMemoryStore"])
        #expect(options.storeName == "ui-a")
        #expect(options.resetStore)
        #expect(options.failSave)
        #expect(options.failStoreOpen)
        #expect(options.inMemoryStore)
        #expect(LaunchOptions.parse(["-storeName"]).storeName == nil)
    }

    @Test func liveActivityOptions() {
        let options = LaunchOptions.parse(["-seedDemoData", "running", "-liveActivity", "-liveGallery"])
        #expect(options.liveActivity)
        #expect(options.liveGallery)
        #expect(options.demoScene == .running)
        #expect(!LaunchOptions.parse([]).liveActivity)
    }

    @Test func realAmbientOption() {
        #expect(LaunchOptions.parse(["-seedDemoData", "running", "-realAmbient"]).realAmbient)
        #expect(!LaunchOptions.parse(["-seedDemoData", "running"]).realAmbient)
    }

    @Test func openStartSheetOption() {
        #expect(!LaunchOptions.parse([]).openStartSheet)
        #expect(LaunchOptions.parse(["-seedDemoData", "day", "-openStartSheet"]).openStartSheet)
    }

    @Test func makeClockUsesFixedNowAsStart() {
        let start = Date(timeIntervalSince1970: 1_792_387_800)
        let base = FixedClock(date: Date(timeIntervalSince1970: 1_700_000_000))
        let options = LaunchOptions(fixedNow: start)

        #expect(options.makeClock(base: base).now() == start)
        #expect(LaunchOptions().makeClock(base: base).now() == base.now())
    }

    @Test func parsesFlipRace() {
        #expect(!LaunchOptions.parse([]).raceStartsFlipped)
        #expect(LaunchOptions.parse(["-flipRace"]).raceStartsFlipped)
        #expect(LaunchOptions.parse(["-flipRace", "points"]).raceStartsFlipped)
        // 次が場面名でなければ読み飛ばさない
        let options = LaunchOptions.parse(["-flipRace", "-seedDemoData", "day"])
        #expect(options.raceStartsFlipped)
        #expect(options.demoScene == .day)
    }

    /// 見本データで比べる相手と、裏のグラフを1日全体で始める（GHO-13 の撮影用）
    @Test func parsesOpponentAndWholeDay() {
        #expect(LaunchOptions.parse([]).opponent == nil)
        #expect(!LaunchOptions.parse([]).raceStartsWholeDay)
        let options = LaunchOptions.parse(["-opponent", "goal", "-raceWholeDay", "-seedDemoData", "day"])
        #expect(options.opponent == .goal)
        #expect(options.raceStartsWholeDay)
        #expect(options.demoScene == .day)
        #expect(!options.raceStartsReplay)
        #expect(LaunchOptions.parse(["-raceReplay", "-flipRace"]).raceStartsReplay)
        #expect(LaunchOptions.parse(["-slowRaceIntro"]).slowRaceIntro)
        #expect(!LaunchOptions.parse([]).slowRaceIntro)
    }

    /// 分析のタブを開いて始める（NAV-01・ANA-04・05 の撮影用）
    @Test func parsesAnalysisOpeners() {
        let none = LaunchOptions.parse([])
        #expect(!none.openAnalysis && !none.openPoints && none.openDay == nil)
        #expect(LaunchOptions.parse(["-openAnalysis"]).openAnalysis)
        #expect(LaunchOptions.parse(["-openPoints"]).openPoints)
        let day = LaunchOptions.parse(["-openDay", "1", "-seedDemoData", "day"])
        #expect(day.openPoints)
        #expect(day.openDay == 1)
        #expect(day.demoScene == .day)
        // 数でなければ読み飛ばさない
        #expect(LaunchOptions.parse(["-openDay", "-seedDemoData", "day"]).openDay == nil)
        // 知らない名前は読み飛ばさない
        let unknown = LaunchOptions.parse(["-opponent", "-seedDemoData", "day"])
        #expect(unknown.opponent == nil)
        #expect(unknown.demoScene == .day)
    }

    /// 自己ベストを期間つきで開く・ポイントの推移を前の期間で開く（ANA-04・06 の撮影用）
    @Test func parsesBestAndPointsPage() {
        #expect(LaunchOptions.parse([]).openBest == nil)
        #expect(LaunchOptions.parse(["-openBest", "week"]).openBest == .week)
        // 期間がなければ全期間。次の引数は読み飛ばさない
        let plain = LaunchOptions.parse(["-openBest", "-seedDemoData", "day"])
        #expect(plain.openBest == .all)
        #expect(plain.demoScene == .day)
        let page = LaunchOptions.parse(["-pointsPage", "2"])
        #expect(page.openPoints)
        #expect(page.pointsPage == 2)
    }

    /// ラップ表の相手と、自己ベストを送る先（ANA-06・09・11 の撮影用）
    @Test func parsesLapTargetAndBestScroll() {
        #expect(LaunchOptions.parse([]).lapTarget == nil)
        #expect(LaunchOptions.parse(["-lapTarget", "average"]).lapTarget == .average)
        #expect(LaunchOptions.parse(["-lapTarget", "sectionBest"]).lapTarget == .sectionBest)
        // 知らない相手は読み飛ばさず、次の引数をそのまま読む
        let unknown = LaunchOptions.parse(["-lapTarget", "-openBest", "week"])
        #expect(unknown.lapTarget == nil)
        #expect(unknown.openBest == .week)
        #expect(LaunchOptions.parse(["-bestScroll", "top10"]).bestScroll == "top10")
    }

    /// 見本データの今日の目標（計画より多い目標の撮影用、GHO-10）
    @Test func parsesDemoGoalMinutes() {
        #expect(LaunchOptions.parse([]).demoGoalMinutes == nil)
        let options = LaunchOptions.parse(["-seedDemoData", "day", "-goalMinutes", "600"])
        #expect(options.demoGoalMinutes == 600)
        #expect(options.demoScene == .day)
        #expect(LaunchOptions.parse(["-goalMinutes", "-seedDemoData"]).demoGoalMinutes == nil)
    }

    /// 見本のヘルスケアに睡眠の記録がない（「ヘルスケアから読み直す」の撮影用、DTX-02）
    @MainActor @Test func parsesNoHealthSleep() async {
        #expect(!LaunchOptions.parse([]).noHealthSleep)
        let options = LaunchOptions.parse(["-seedDemoData", "gamePlan", "-noHealthSleep"])
        #expect(options.noHealthSleep)
        let source = await AppLauncher.sleepSource(options, clock: FixedClock(date: jst("2026-10-19T07:30")))
        #expect(await source.sleepIntervals(from: .distantPast, to: .distantFuture).isEmpty)
    }
}
