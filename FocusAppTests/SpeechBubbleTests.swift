import CoreGraphics
import Testing
@testable import FocusApp

/// ゴーストの吹き出しの置き場所（GHO-12）。円の端で画面の外に切れないようにする
struct SpeechBubbleTests {
    private let bounds = CGSize(width: 320, height: 320)
    private let bubble = CGSize(width: 100, height: 22)

    @Test func staysOutwardWhenItFits() {
        // 右上：外側にずらしても円の中に収まる → 今までどおり
        let center = TrackRunner.bubbleCenter(point: CGPoint(x: 200, y: 60), outward: CGVector(dx: 0.6, dy: -0.8),
                                              size: bubble, bounds: bounds)
        #expect(center == CGPoint(x: 200 + 0.6 * 44, y: 60 - 0.8 * 34))
    }

    @Test func leftEdgeMovesInsideAndAboveTheGhost() {
        // 左の真ん中：外側（左）にずらすと切れる → 横は収まるところまで戻し、ゴーストの上に置く
        let ghost = CGPoint(x: 50, y: 160)
        let center = TrackRunner.bubbleCenter(point: ghost, outward: CGVector(dx: -1, dy: 0), size: bubble, bounds: bounds)
        #expect(center.x - bubble.width / 2 >= -TrackRunner.bubbleOverhang)
        #expect(center.y + bubble.height / 2 <= ghost.y - 14)  // おばけ（高さ28）に重ならない
    }

    @Test func rightEdgeMovesInsideAndAboveTheGhost() {
        let ghost = CGPoint(x: 270, y: 160)
        let center = TrackRunner.bubbleCenter(point: ghost, outward: CGVector(dx: 1, dy: 0), size: bubble, bounds: bounds)
        #expect(center.x + bubble.width / 2 <= bounds.width + TrackRunner.bubbleOverhang)
        #expect(center.y + bubble.height / 2 <= ghost.y - 14)
    }
}
