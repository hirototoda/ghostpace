import AVFoundation
import Foundation

/// 環境音を鳴らす（TMR-14）。本物は AVAudioEngine で音を作って流す。テスト・見本データでは鳴らさない
@MainActor
protocol AmbientPlaying: AnyObject {
    /// 流す（少しずつ大きくする）。同じ音が流れていれば音量だけ変える
    func play(_ sound: AmbientSound, volume: Double)
    func setVolume(_ volume: Double)
    /// 止める（少しずつ小さくする）
    func stop()
}

@MainActor
final class SilentAmbientPlayer: AmbientPlaying {
    private(set) var playing: AmbientSound?
    private(set) var volume = 0.0
    func play(_ sound: AmbientSound, volume: Double) {
        playing = sound == .none ? nil : sound
        self.volume = volume
    }
    func setVolume(_ volume: Double) { self.volume = volume }
    func stop() { playing = nil }
}

@MainActor
final class EngineAmbientPlayer: AmbientPlaying {
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private var current: AmbientSound?
    private var fadeTask: Task<Void, Never>?
    private var target = 0.0
    /// 止めている途中（音量を変えても止めるのをやめない）
    private var stopping = false

    static let fadeSeconds = 1.0

    func play(_ sound: AmbientSound, volume: Double) {
        guard sound != .none else { return stop() }
        target = volume
        stopping = false
        if current == sound, engine.isRunning { return fade(to: volume) }
        tearDown()
        let session = AVAudioSession.sharedInstance()
        // ほかのアプリの音楽は止めない。画面を消しても流す（バックグラウンドの音の許可）
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        let format = engine.outputNode.inputFormat(forBus: 0)
        let sampleRate = format.sampleRate > 0 ? format.sampleRate : 44_100
        let box = GeneratorBox(NoiseGenerator(sound: sound, sampleRate: sampleRate, seed: UInt64.random(in: 1...UInt64.max)))
        let node = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for frame in 0..<Int(frameCount) {
                let value = box.next()
                for buffer in buffers {
                    buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = value
                }
            }
            return noErr
        }
        let mono = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: mono)
        engine.mainMixerNode.outputVolume = 0
        do { try engine.start() } catch { return tearDown() }
        source = node
        current = sound
        fade(to: volume)
    }

    func setVolume(_ volume: Double) {
        target = volume
        if engine.isRunning, !stopping { fade(to: volume) }
    }

    /// 鳴っていなければ何もしない（毎分の読み直しで、ほかのアプリの音に関わらないように）
    func stop() {
        guard current != nil || engine.isRunning else { return }
        guard engine.isRunning else { return tearDown() }
        stopping = true
        fadeTask?.cancel()
        fadeTask = Task { [weak self] in
            await self?.ramp(to: 0)
            guard !Task.isCancelled else { return }
            self?.tearDown()
        }
    }

    private func fade(to volume: Double) {
        fadeTask?.cancel()
        fadeTask = Task { [weak self] in await self?.ramp(to: volume) }
    }

    /// 約1秒で音量を変える
    private func ramp(to volume: Double) async {
        let steps = 20
        let start = Double(engine.mainMixerNode.outputVolume)
        for step in 1...steps {
            guard !Task.isCancelled else { return }
            engine.mainMixerNode.outputVolume = Float(start + (volume - start) * Double(step) / Double(steps))
            try? await Task.sleep(for: .seconds(Self.fadeSeconds / Double(steps)))
        }
    }

    private func tearDown() {
        stopping = false
        engine.stop()
        if let source { engine.detach(source) }
        source = nil
        current = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// 音を作る処理（音のスレッドで呼ばれる）。1つの音のスレッドからしか触らない
private final class GeneratorBox: @unchecked Sendable {
    private var generator: NoiseGenerator
    init(_ generator: NoiseGenerator) { self.generator = generator }
    func next() -> Float { generator.next() }
}
