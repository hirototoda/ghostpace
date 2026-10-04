import Foundation
import Testing
@testable import FocusApp

@MainActor
struct AppLauncherTests {
    private let clock = FixedClock(date: jst("2026-10-19T11:20"))

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "focusapp-launcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// ロック画面と画面上部（TMR-06）：本物の記録のときだけ出す。見本・UI テストでは `-liveActivity` を付けたときだけ
    @Test func liveActivityOnlyForRealStoreOrWhenAsked() {
        let clock = FixedClock(date: jst("2026-10-19T09:00"))
        #expect(AppLauncher.liveActivity(LaunchOptions(), clock: clock) is ActivityKitLiveActivity)
        #expect(AppLauncher.liveActivity(LaunchOptions(demoScene: .running), clock: clock) is NoLiveActivity)
        #expect(AppLauncher.liveActivity(LaunchOptions(storeName: "ui-a"), clock: clock) is NoLiveActivity)
        #expect(AppLauncher.liveActivity(LaunchOptions(inMemoryStore: true), clock: clock) is NoLiveActivity)
        #expect(AppLauncher.liveActivity(LaunchOptions(demoScene: .running, liveActivity: true), clock: clock) is ActivityKitLiveActivity)
    }

    @Test func resetStoreNeedsStoreName() {
        // -storeName がなければ何も消さない（通常の記録は決して消さない）
        #expect(AppLauncher.filesToReset(LaunchOptions(resetStore: true)).isEmpty)
        #expect(AppLauncher.filesToReset(LaunchOptions(storeName: "ui-a")).isEmpty)
        #expect(AppLauncher.filesToReset(LaunchOptions(storeName: "ui-a", resetStore: true)).count == 3)
    }

    @Test func resetStoreDeletesNamedStoreAndSidecars() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let other = directory.appending(path: "other.store")
        for name in ["ui.store", "ui.store-shm", "ui.store-wal", "other.store"] {
            try Data("garbage".utf8).write(to: directory.appending(path: name))
        }
        var options = LaunchOptions(storeName: "ui", resetStore: true)
        options.storeDirectory = directory

        let launcher = AppLauncher(options: options, clock: clock)
        guard case .ready = launcher.state else { Issue.record("開けなかった: \(launcher.state)"); return }
        #expect(FileManager.default.fileExists(atPath: other.path(percentEncoded: false)))
    }

    @Test func failStoreOpenKeepsExistingFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var options = LaunchOptions(storeName: "keep", failStoreOpen: true)
        options.storeDirectory = directory
        // 一度ふつうに開いて記録を作る
        do {
            var normal = options
            normal.failStoreOpen = false
            let first = AppLauncher(options: normal, clock: clock)
            guard case .ready = first.state else { Issue.record("開けなかった"); return }
        }
        let file = directory.appending(path: "keep.store")
        let before = try Data(contentsOf: file)

        let launcher = AppLauncher(options: options, clock: clock)
        guard case .failed = launcher.state else { Issue.record("失敗するはず"); return }
        #expect(try Data(contentsOf: file) == before)
    }

    @Test func failSaveAppliesAfterDemoSeed() throws {
        let launcher = AppLauncher(options: LaunchOptions(demoScene: .running, failSave: true), clock: clock)
        guard case .ready(let model) = launcher.state else { Issue.record("開けなかった"); return }
        #expect(model.running != nil)
        model.requestEnd()
        #expect(model.errorMessage == AppModel.saveErrorMessage)
        #expect(model.running != nil)
    }

    #if DEBUG
    @Test func switchDemoClearsFailSave() {
        let launcher = AppLauncher(options: LaunchOptions(demoScene: .running, failSave: true), clock: clock)
        launcher.switchDemo(to: .day)
        #expect(!launcher.options.failSave)
        #expect(launcher.options.demoScene == .day)
    }
    #endif
}
