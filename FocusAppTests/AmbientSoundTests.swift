import AVFoundation
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

    private func rms(_ values: [Float]) -> Double {
        sqrt(values.map { Double($0 * $0) }.reduce(0, +) / Double(values.count))
    }

    /// 高い音の多さ：となりとの差の大きさ ÷ 大きさ（まったくのホワイトノイズで約1.41）
    private func brightness(_ values: [Float]) -> Double {
        rms(zip(values, values.dropFirst()).map { $1 - $0 }) / rms(values)
    }

    /// 10ミリ秒ごとの大きさのばらつき（はじける粒が多いと大きい）
    private func crackle(_ values: [Float], sampleRate: Double = 44_100) -> Double {
        let window = Int(sampleRate / 100)
        let levels = stride(from: 0, to: values.count - window, by: window).map { rms(Array(values[$0..<$0 + window])) }
        let mean = levels.reduce(0, +) / Double(levels.count)
        return sqrt(levels.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(levels.count)) / mean
    }

    /// ブラウンノイズは低い音（となりの値との差が小さい）
    @Test func brownIsLowerThanWhite() {
        #expect(brightness(samples(.brown)) < brightness(samples(.white)) / 4)
    }

    /// 3つの音はだいたい同じ大きさ（-21 dBFS 前後）で、上限で切れない（割れない）。実機で「勢いがすごい」と言われた
    @Test func soundsAreEvenAndNeverClip() {
        let levels = [AmbientSound.white, .brown, .rain].map { sound -> Double in
            let values = samples(sound, count: 44_100 * 5)
            #expect(values.allSatisfy { abs($0) < 0.9 }, "\(sound) が割れる")
            return 20 * log10(rms(values))
        }
        #expect(levels.allSatisfy { (-25 ... -18).contains($0) }, "\(levels)")
        #expect(levels.max()! - levels.min()! < 3)
    }

    /// ホワイトノイズは高い「シャー」を少し落とす
    @Test func whiteIsSoftenedAtTheTop() {
        #expect(brightness(samples(.white)) < 1.2)
    }

    /// 雨は細かい粒があるが、はじけるガサガサにはしない（実機で「ガサガサ」と言われた。前は約0.45）
    @Test func rainHasFineDropsWithoutCrackle() {
        let rain = crackle(samples(.rain, count: 44_100 * 5))
        #expect(rain < 0.2)
        #expect(rain > crackle(samples(.white, count: 44_100 * 5)) * 2)
    }

    /// サンプルの速さ（iPhone は 48kHz が多い）が違っても同じような音
    @Test func soundsMatchAcrossSampleRates() {
        for sound in [AmbientSound.white, .brown, .rain] {
            var at48 = NoiseGenerator(sound: sound, sampleRate: 48_000, seed: 7)
            let fast = (0..<48_000 * 5).map { _ in at48.next() }
            let slow = samples(sound, count: 44_100 * 5)
            #expect(abs(20 * log10(rms(fast) / rms(slow))) < 1.5, "\(sound)")
        }
    }

    /// 音を作る処理は音のスレッドから呼ばれる。メインのスレッド以外のエンジンで描いても落ちずに音が出る
    /// （MainActor の中で作って実機で落ちた不具合の再発防止）
    @Test func sourceRendersOffTheMainThread() async throws {
        let peak: Float = try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                do {
                    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
                    let engine = AVAudioEngine()
                    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
                    let node = EngineAmbientPlayer.makeSource(.white, sampleRate: 44_100, seed: 1)
                    engine.attach(node)
                    engine.connect(node, to: engine.mainMixerNode, format: format)
                    try engine.start()
                    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 512))
                    _ = try engine.renderOffline(512, to: buffer)
                    engine.stop()
                    let samples = UnsafeBufferPointer(start: buffer.floatChannelData?[0], count: Int(buffer.frameLength))
                    continuation.resume(returning: samples.map(abs).max() ?? 0)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        #expect(peak > 0)
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
