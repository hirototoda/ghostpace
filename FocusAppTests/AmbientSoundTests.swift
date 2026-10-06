import Foundation
import Testing
@testable import FocusApp

/// 環境音（TMR-14）
struct AmbientSoundTests {
    private func samples(_ sound: AmbientSound, count: Int = 44_100, seed: UInt64 = 7) -> [Float] {
        var generator = NoiseGenerator(sound: sound, seed: seed)
        return (0..<count).map { _ in generator.next() }
    }

    @Test func soundsStayInRangeAndAreRepeatable() {
        for sound in AmbientSound.allCases {
            let values = samples(sound)
            #expect(values.allSatisfy { $0 >= -1 && $0 <= 1 })
            #expect(values == samples(sound))
        }
        #expect(samples(.none).allSatisfy { $0 == 0 })
        #expect(samples(.white).contains { $0 != 0 })
    }

    /// ブラウンノイズは低い音（となりの値との差が小さい）
    @Test func brownIsLowerThanWhite() {
        func roughness(_ values: [Float]) -> Float {
            zip(values, values.dropFirst()).map { abs($1 - $0) }.reduce(0, +) / Float(values.count)
        }
        #expect(roughness(samples(.brown)) < roughness(samples(.white)) / 4)
    }

    @Test func rainHasDrops() {
        // 1秒に約30粒：粒のある所は大きく跳ねる
        let peaks = samples(.rain).filter { abs($0) > 0.45 }.count
        #expect(peaks > 0)
    }

    @Test func storedValuesReadBack() {
        #expect(AmbientSound(stored: "rain") == .rain)
        #expect(AmbientSound(stored: nil) == .none)
        #expect(AmbientSound(stored: "cafe") == .none)
    }
}

/// 本体：タイマーに合わせて流す・止める、前回の音を覚える
@MainActor
struct AmbientModelTests {
    @Test func playsWithTheTimerAndRemembersTheSound() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        let c = try t.seeded()
        let settings = MemorySettings()
        settings.didShowBlockingIntro = true
        let player = SilentAmbientPlayer()
        let m = AppModel(store: t.store, clock: t.clock, timeZone: { tokyo }, settings: settings, ambient: player)
        m.skipPlan()
        // 初めは「なし」なので流さない
        m.startUnplanned(category: c[0], minutes: nil)
        #expect(player.playing == nil)
        m.setAmbientSound(.rain)
        #expect(player.playing == .rain)
        m.setAmbientVolume(0.3)
        #expect(player.volume == 0.3)
        m.pause()
        #expect(player.playing == nil)
        m.resume()
        #expect(player.playing == .rain)
        t.clock.advance(120)
        m.requestEnd()
        #expect(player.playing == nil)
        // 次のタイマーは前回の音で自動で流れる（開き直しても）
        let next = SilentAmbientPlayer()
        let reopened = AppModel(store: t.store, clock: t.clock, timeZone: { tokyo }, settings: settings, ambient: next)
        reopened.startUnplanned(category: c[0], minutes: 25)
        #expect(next.playing == .rain)
        #expect(next.volume == 0.3)
        reopened.setAmbientSound(.none)
        #expect(next.playing == nil)
    }

    @Test func reopeningFollowsTheTimerState() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        let c = try t.seeded()
        let settings = MemorySettings()
        settings.didShowBlockingIntro = true
        settings.ambientSound = AmbientSound.brown.rawValue
        let first = AppModel(store: t.store, clock: t.clock, timeZone: { tokyo }, settings: settings, ambient: SilentAmbientPlayer())
        first.skipPlan()
        first.startUnplanned(category: c[0], minutes: nil)
        // 開き直すと、動いているタイマーなら流す
        let running = SilentAmbientPlayer()
        _ = AppModel(store: t.store, clock: t.clock, timeZone: { tokyo }, settings: settings, ambient: running)
        #expect(running.playing == .brown)
        // 一時停止中に開き直すと流さない
        first.pause()
        let paused = SilentAmbientPlayer()
        _ = AppModel(store: t.store, clock: t.clock, timeZone: { tokyo }, settings: settings, ambient: paused)
        #expect(paused.playing == nil)
    }

    @Test func volumeIsKeptBetweenZeroAndOne() throws {
        let t = try TestStore(now: jst("2026-10-19T09:00"))
        try t.seeded()
        let m = AppModel(store: t.store, clock: t.clock, timeZone: { tokyo }, settings: MemorySettings())
        m.setAmbientVolume(2)
        #expect(m.ambientVolume == 1)
        m.setAmbientVolume(-1)
        #expect(m.ambientVolume == 0)
    }
}
