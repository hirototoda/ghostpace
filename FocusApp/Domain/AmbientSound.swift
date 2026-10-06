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

/// 音の波を1つずつ作る。同じ種（seed）なら同じ音になる（テストで確かめるため）。値は −1〜1
struct NoiseGenerator {
    let sound: AmbientSound
    let sampleRate: Double
    private var state: UInt64
    private var brown = 0.0
    /// 雨：ざーっという音（低めのノイズ）と、ときどき落ちる粒
    private var rainLow = 0.0
    private var drop = 0.0
    private var dropDecay = 0.0

    init(sound: AmbientSound, sampleRate: Double = 44_100, seed: UInt64 = 0x9E37_79B9_7F4A_7C15) {
        self.sound = sound
        self.sampleRate = sampleRate
        state = seed == 0 ? 1 : seed
    }

    /// 0〜1 の乱数（xorshift）
    private mutating func random() -> Double {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Double(state % 1_000_000) / 1_000_000
    }

    mutating func next() -> Float {
        switch sound {
        case .none:
            return 0
        case .white:
            return Float((random() * 2 - 1) * 0.35)
        case .brown:
            // 白い音を積み上げて低い音に。離れすぎないよう少しずつ0へ戻す
            brown = (brown + (random() * 2 - 1) * 0.02) * 0.998
            return Float(max(-1, min(1, brown * 3.5)))
        case .rain:
            rainLow += ((random() * 2 - 1) - rainLow) * 0.08
            if random() < 30 / sampleRate {  // 1秒に約30粒
                drop = 0.25 + random() * 0.35
                dropDecay = 0.9990 - random() * 0.004
            }
            drop *= dropDecay
            let value = rainLow * 0.55 + (random() * 2 - 1) * drop
            return Float(max(-1, min(1, value)))
        }
    }
}
