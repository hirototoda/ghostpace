import SwiftUI

/// 円のトラック（GHO-12）。一番上から時計回りに1周する。
struct TrackGeometry {
    var rect: CGRect

    private var radius: CGFloat { min(rect.width, rect.height) / 2 }
    private func angle(_ progress: Double) -> Double { 2 * .pi * progress }

    /// 1周を 0〜1 として、その地点
    func point(at progress: Double) -> CGPoint {
        CGPoint(x: rect.midX + radius * sin(angle(progress)), y: rect.midY - radius * cos(angle(progress)))
    }

    /// 進む向きが左なら true（走る人の向きを変える）
    func movesLeft(at progress: Double) -> Bool { cos(angle(progress)) < -0.001 }

    /// 外向きの向き（吹き出しを置く方向）
    func outward(at progress: Double) -> CGVector { CGVector(dx: sin(angle(progress)), dy: -cos(angle(progress))) }
}

/// レーンの線（`progress` までを塗る）。アニメーションの途中も線が伸びる。
struct TrackLane: Shape {
    var progress: Double
    /// 外側の枠から内側へのずらし
    var inset: CGFloat

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let rect = Self.laneRect(rect, inset: inset)
        var path = Path()
        let to = min(max(progress, 0), 1)
        guard to > 0 else { return path }
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2,
                    startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * to), clockwise: false)
        return path
    }

    static func laneRect(_ rect: CGRect, inset: CGFloat) -> CGRect {
        let side = min(rect.width, rect.height)
        return CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side).insetBy(dx: inset, dy: inset)
    }
}

/// レーンの上を走る人（自分）かゴースト。`fraction` は開いたときのアニメーションの進み（0〜1）。
struct TrackRunner: View, @MainActor Animatable {
    enum Kind { case me, ghost }

    var kind: Kind
    /// 着く地点（1周＝1）
    var progress: Double
    var fraction: Double
    var inset: CGFloat
    /// 吹き出し（ゴーストだけ）。値はアニメーションに合わせて数え上がる
    var bubbleTitle: String?
    var bubbleSeconds: Int = 0
    @State private var bubbleSize = CGSize.zero

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    var body: some View {
        GeometryReader { proxy in
            let geometry = TrackGeometry(rect: TrackLane.laneRect(CGRect(origin: .zero, size: proxy.size), inset: inset))
            let at = min(max(progress, 0), 1) * fraction
            let point = geometry.point(at: min(at, 0.99999))
            let flips = geometry.movesLeft(at: at)
            ZStack {
                if let bubbleTitle {
                    let out = geometry.outward(at: at)
                    SpeechBubble(text: "\(bubbleTitle) \(DurationFormat.japanese(Int(Double(bubbleSeconds) * fraction)))")
                        .fixedSize()
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { bubbleSize = $0 }
                        .position(Self.bubbleCenter(point: point, outward: out, size: bubbleSize, bounds: proxy.size))
                }
                figure
                    .scaleEffect(x: flips ? -1 : 1)
                    .position(point)
            }
        }
        .accessibilityHidden(true)
    }

    /// 吹き出しが円の枠からはみ出してよい幅（画面の端までは届かない）
    static let bubbleOverhang: CGFloat = 8

    /// 吹き出しの中心。ふだんは走っている所から円の外側へずらす。
    /// 円の左右の端で外にずらすと画面の外に切れるときは、横は収まる所まで戻し、おばけの真上に置く
    static func bubbleCenter(point: CGPoint, outward: CGVector, size: CGSize, bounds: CGSize) -> CGPoint {
        let ideal = CGPoint(x: point.x + outward.dx * 44, y: point.y + outward.dy * 34)
        let minX = size.width / 2 - bubbleOverhang, maxX = bounds.width - size.width / 2 + bubbleOverhang
        guard ideal.x < minX || ideal.x > maxX else { return ideal }
        // おばけ（高さ28）の上に、少しあけて置く
        return CGPoint(x: min(max(ideal.x, minX), maxX), y: point.y - 14 - size.height / 2 - 4)
    }

    @ViewBuilder
    private var figure: some View {
        switch kind {
        case .me:
            Image(systemName: "figure.run")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Theme.focus))
                .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 2))
                .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
        case .ghost:
            GhostShape()
                .fill(Theme.ghost.opacity(0.85))
                .overlay(GhostEyes().fill(Color(uiColor: .systemBackground)))
                .frame(width: 24, height: 28)
                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
        }
    }
}

/// 吹き出し。相手がこの時刻までに集中した時間（GHO-12）
struct SpeechBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.bold().monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
                    .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
            )
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }
}

/// おばけの形（GhostPace のゴースト）
struct GhostShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height, x = rect.minX, y = rect.minY
        path.move(to: CGPoint(x: x, y: y + h))
        path.addLine(to: CGPoint(x: x, y: y + w / 2))
        path.addArc(center: CGPoint(x: x + w / 2, y: y + w / 2), radius: w / 2,
                    startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: x + w, y: y + h))
        // すその波
        let waves = 3
        for i in 0..<waves {
            let right = x + w - CGFloat(i) * w / CGFloat(waves)
            let left = right - w / CGFloat(waves)
            path.addQuadCurve(to: CGPoint(x: left, y: y + h),
                              control: CGPoint(x: (left + right) / 2, y: y + h - h * 0.22))
        }
        path.closeSubpath()
        return path
    }
}

private struct GhostEyes: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        for cx in [0.36, 0.64] {
            path.addEllipse(in: CGRect(x: rect.minX + w * cx - w * 0.08, y: rect.minY + h * 0.3, width: w * 0.16, height: h * 0.18))
        }
        return path
    }
}
