import Foundation

/// Screen Time の許可。
enum BlockingAuthorization: Equatable, Sendable {
    case notDetermined
    case approved
    case denied
    /// この版では使えない（Apple の許可が出るまでの TestFlight の版、シミュレーター）
    case unavailable
}

/// iOS の Screen Time（FamilyControls・ManagedSettings・DeviceActivity）への操作。AppModel はこれだけに依存する。
@MainActor
protocol BlockingControlling: AnyObject {
    /// この版でブロックを使えるか
    var isAvailable: Bool { get }
    func authorization() -> BlockingAuthorization
    func requestAuthorization() async -> BlockingAuthorization
    /// 選択に入っているアプリ・カテゴリ・サイトの数
    func selectionCount(_ selection: Data) -> Int
    func shield(selection: Data)
    func unshield()
    /// 集中中の全部ブロック（BLK-04）。`allow` は集中中も使うアプリ（nil なら全部）
    func shieldFocus(allow: Data?)
    func unshieldFocus()
    func startReblockSchedule(_ schedule: ReblockSchedule) throws
    func stopReblockSchedule()
    /// ゲーム・SNS の時間を切り替えるスケジュールを登録し直す（前のものは止める。BLK-10）
    func replaceUnblockSchedules(_ schedules: [ReblockSchedule])
    /// いまかかっているブロックの中身（確認用の記録に出す）
    func shieldSummary() -> String
}

/// 何もしない（見本データ・UI テスト・シミュレーター）。
@MainActor
final class NoBlocking: BlockingControlling {
    let isAvailable: Bool

    init(isAvailable: Bool = false) {
        self.isAvailable = isAvailable
    }

    func authorization() -> BlockingAuthorization { isAvailable ? .approved : .unavailable }
    func requestAuthorization() async -> BlockingAuthorization { authorization() }
    func selectionCount(_ selection: Data) -> Int { selection.isEmpty ? 0 : 1 }
    func shield(selection: Data) {}
    func unshield() {}
    func shieldFocus(allow: Data?) {}
    func unshieldFocus() {}
    func startReblockSchedule(_ schedule: ReblockSchedule) throws {}
    func stopReblockSchedule() {}
    func replaceUnblockSchedules(_ schedules: [ReblockSchedule]) {}
    func shieldSummary() -> String { "" }
}
