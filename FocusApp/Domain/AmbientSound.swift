import Foundation

/// 環境音（TMR-14、docs/product/features/focus-timer.md「環境音」）。アプリの中で作る（録音は入れない）
enum AmbientSound: String, CaseIterable, Identifiable {
    case none
    case white
    case brown
    case rain

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "なし"
        case .white: "ホワイトノイズ"
        case .brown: "ブラウンノイズ"
        case .rain: "雨"
        }
    }

    var symbol: String {
        switch self {
        case .none: "speaker.slash"
        case .white: "waveform"
        case .brown: "water.waves"
        case .rain: "cloud.rain"
        }
    }

    /// 保存した値から読む。知らない値は「なし」
    init(stored: String?) { self = stored.flatMap(AmbientSound.init(rawValue:)) ?? .none }
}

/// 音の波を1つずつ作る。同じ種（seed）なら同じ音になる（テストで確かめるため）。値は −1〜1。
/// 3つの音はだいたい同じ大きさにそろえ、上限で切れ（割れ）ないようにする
struct NoiseGenerator {
    let sound: AmbientSound
    let sampleRate: Double
    private var state: UInt64

    /// ホワイトノイズ：高い「シャー」を少し落とす
    private var whiteLow = OnePole()
    private var brown = 0.0
    /// 雨：ざーっという地の音（中くらいの高さの帯）と、細かい雨粒。全体の強さはゆっくり揺らす
    private var bedLow = OnePole(), bedHigh = OnePole()
    private var dropLow = OnePole(), dropHigh = OnePole()
    private var dropLevel = 0.0, dropSmooth = OnePole()
    private var dropDecay = 0.0
    private var swell = OnePole(), swellTarget = 1.0, swellCountdown = 0

    private let c: Coefficients

    init(sound: AmbientSound, sampleRate: Double = 44_100, seed: UInt64 = 0x9E37_79B9_7F4A_7C15) {
        self.sound = sound
        self.sampleRate = sampleRate
        state = seed == 0 ? 1 : seed
        c = Coefficients(sampleRate: sampleRate)
        swell.value = 1
    }

    /// 0〜1 の乱数（xorshift）
    private mutating func random() -> Double {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Double(state >> 11) / Double(1 << 53)
    }

    private mutating func noise() -> Double { random() * 2 - 1 }

    mutating func next() -> Float {
        let value: Double
        switch sound {
        case .none:
            return 0
        case .white:
            value = whiteLow.run(noise(), c.white) * Gain.white
        case .brown:
            // 白い音を積み上げて低い音に。離れすぎないよう少しずつ0へ戻す
            brown = (brown + noise() * 0.02) * c.brownLeak
            value = brown * Gain.brown
        case .rain:
            // 地の音：400Hz〜2.5kHz あたりの帯のノイズ
            let raw = noise()
            let bed = bedLow.run(raw, c.bedLow) - bedHigh.run(raw, c.bedHigh)
            // 雨粒：1秒に約150粒。小さく短く（数ミリ秒）、立ち上がりをなめらかに（はじける音にしない）
            if random() < 150 / sampleRate {
                let size = random() < 0.08 ? 0.35 + random() * 0.25 : 0.08 + random() * 0.17
                dropLevel = max(dropLevel, size)
                dropDecay = c.dropDecay(random())
            }
            dropLevel *= dropDecay
            let envelope = dropSmooth.run(dropLevel, c.dropAttack)
            let tick = noise() * envelope
            let drops = dropLow.run(tick, c.dropLow) - dropHigh.run(tick, c.dropHigh)
            // 強さのゆらぎ：0.5秒ごとに次の強さを選び、ゆっくり近づく
            if swellCountdown <= 0 {
                swellTarget = 0.8 + random() * 0.4
                swellCountdown = Int(sampleRate / 2)
            }
            swellCountdown -= 1
            let level = swell.run(swellTarget, c.swell)
            value = (bed * Gain.rainBed + drops * Gain.rainDrops) * level
        }
        return Float(max(-1, min(1, value)))
    }

    /// 音の大きさ（3つをだいたい -21 dBFS にそろえる。ブラウンは低い音で小さく聞こえるので少し大きめ）
    private enum Gain {
        static let white = 0.25
        static let brown = 0.5
        static let rainBed = 0.45
        static let rainDrops = 1.0
    }

    private struct Coefficients {
        let white, bedLow, bedHigh, dropLow, dropHigh, dropAttack, swell, brownLeak: Double
        let sampleRate: Double

        init(sampleRate: Double) {
            self.sampleRate = sampleRate
            white = OnePole.coefficient(hertz: 5_000, sampleRate: sampleRate)
            bedLow = OnePole.coefficient(hertz: 2_500, sampleRate: sampleRate)
            bedHigh = OnePole.coefficient(hertz: 400, sampleRate: sampleRate)
            dropLow = OnePole.coefficient(hertz: 6_000, sampleRate: sampleRate)
            dropHigh = OnePole.coefficient(hertz: 1_000, sampleRate: sampleRate)
            dropAttack = OnePole.coefficient(hertz: 400, sampleRate: sampleRate)
            swell = OnePole.coefficient(hertz: 0.5, sampleRate: sampleRate)
            // 44.1kHz で 0.998 と同じ戻り方（サンプルの速さが違っても同じ音に）
            brownLeak = pow(0.998, 44_100 / sampleRate)
        }

        /// 雨粒の消え方：2〜8ミリ秒
        func dropDecay(_ random: Double) -> Double {
            exp(-1 / ((0.002 + random * 0.006) * sampleRate))
        }
    }
}

/// 1次のローパス（高い音を落とす）。ハイパスは「元 − ローパス」で作る
private struct OnePole {
    var value = 0.0

    mutating func run(_ input: Double, _ coefficient: Double) -> Double {
        value += (input - value) * coefficient
        return value
    }

    static func coefficient(hertz: Double, sampleRate: Double) -> Double {
        1 - exp(-2 * Double.pi * hertz / sampleRate)
    }
}
