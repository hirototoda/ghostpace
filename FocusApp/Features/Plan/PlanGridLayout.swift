import CoreGraphics
import Foundation

/// 時間の格子（PLN-10、docs/product/features/daily-plan.md「時間の格子」）の位置と吸い付き。
/// 縦の位置は朝4:00からの経過分で決める（1時間 = `hourHeight`）。開始・終わりは :00 と :30 に吸い付く
struct PlanGridLayout {
    /// 1時間の高さ（2026-10-06 オーナー決定：44pt と比べて、名前が読めて指で動かしやすい 60pt）
    static let hourHeight: CGFloat = 60
    static let snapMinutes = 30
    static let dayMinutes = 24 * 60
    /// 長さの範囲（ブロックの追加と同じ、5分〜3時間）
    static let minMinutes = PlanDraft.minuteStep
    static let maxMinutes = 180  // LengthSlider.minuteRange の上限と同じ（View の定数は MainActor なので写す）

    let dayStart: Date
    var hourHeight: CGFloat

    var totalHeight: CGFloat { height(minutes: Self.dayMinutes) }
    var dayEnd: Date { dayStart.addingTimeInterval(Double(Self.dayMinutes * 60)) }

    func height(minutes: Int) -> CGFloat { CGFloat(minutes) * hourHeight / 60 }

    func y(for date: Date) -> CGFloat { CGFloat(date.timeIntervalSince(dayStart) / 60) * hourHeight / 60 }

    private func minutes(_ date: Date) -> Int { Int((date.timeIntervalSince(dayStart) / 60).rounded()) }
    private func date(_ minutes: Int) -> Date { dayStart.addingTimeInterval(Double(minutes * 60)) }
    private func minutes(dy: CGFloat) -> Int { Int((dy * 60 / hourHeight).rounded()) }

    /// ドラッグで動かした先。開始を近い :00/:30 に合わせ、1日（4:00〜翌4:00）の中に収める。長さは変えない
    func moved(_ block: PlanBlockDraft, by dy: CGFloat) -> PlanBlockDraft {
        let latest = Self.dayMinutes - block.minutes
        var start = Int((Double(minutes(block.start) + minutes(dy: dy)) / Double(Self.snapMinutes)).rounded()) * Self.snapMinutes
        if start > latest { start = latest / Self.snapMinutes * Self.snapMinutes }
        var moved = block
        moved.start = date(max(0, start))
        return moved
    }

    /// 下の端をドラッグした先。終わりを近い :00/:30 に合わせる。開始より前・同じになるときは、開始より後の最初の :00/:30。
    /// 長さは5分〜3時間、終わりは翌4:00 まで。ゲーム・SNS の時間は変えない
    func resized(_ block: PlanBlockDraft, by dy: CGFloat) -> PlanBlockDraft {
        guard Self.canResize(block) else { return block }
        let start = minutes(block.start)
        let step = Double(Self.snapMinutes)
        var end = Int((Double(start + block.minutes + minutes(dy: dy)) / step).rounded()) * Self.snapMinutes
        if end < start + Self.minMinutes {
            end = Int((Double(start + Self.minMinutes) / step).rounded(.up)) * Self.snapMinutes
        }
        end = min(end, start + Self.maxMinutes, Self.dayMinutes)
        var resized = block
        resized.minutes = max(Self.minMinutes, end - start)
        return resized
    }

    /// VoiceOver の「30分早く」「30分遅く」。今の時刻から動かす（吸い付かない）
    func shifted(_ block: PlanBlockDraft, minutes delta: Int) -> PlanBlockDraft {
        var shifted = block
        shifted.start = date(min(max(0, minutes(block.start) + delta), Self.dayMinutes - block.minutes))
        return shifted
    }

    /// 空いた所を押したときの開始。押した位置の :00/:30 に切り下げる
    func tapStart(y: CGFloat) -> Date {
        let raw = Int((y * 60 / hourHeight).rounded(.down))
        return date(min(max(0, raw / Self.snapMinutes * Self.snapMinutes), Self.dayMinutes - Self.snapMinutes))
    }

    static func canResize(_ block: PlanBlockDraft) -> Bool { !block.isUnblock }

    /// 開いたときに見せる時刻（4:00 からの時間、0〜23）。確定した日（計画のタブ）は今の1時間前、下書き（朝・明日）は起きた時刻
    static func initialHour(confirmedDay: Bool, now: Date, wake: Date, dayStart: Date) -> Int {
        let target = confirmedDay ? now.addingTimeInterval(-3600) : wake
        return min(max(0, Int(target.timeIntervalSince(dayStart) / 3600)), 23)
    }

    /// 確定した日（計画のタブ）は、もう始まった・終わったブロックを格子で動かさない（2026-10-06 オーナー決定）
    static func canMove(_ block: PlanBlockDraft, confirmedDay: Bool, now: Date) -> Bool {
        !confirmedDay || block.start > now
    }

    /// 起きている時間。寝る時刻が起きた時刻より前なら1日全部
    static func awake(wake: Date, bed: Date, dayStart: Date) -> ClosedRange<Date> {
        let dayEnd = dayStart.addingTimeInterval(Double(dayMinutes * 60))
        let lower = min(max(wake, dayStart), dayEnd), upper = min(max(bed, dayStart), dayEnd)
        return lower < upper ? lower...upper : dayStart...dayEnd
    }
}
