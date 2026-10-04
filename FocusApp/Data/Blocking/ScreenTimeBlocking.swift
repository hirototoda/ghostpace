import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings

/// 本物の Screen Time。Family Controls の許可が入った実機の版で使う（ios-constraints.md）。
@MainActor
final class ScreenTimeBlocking: BlockingControlling {
    var isAvailable: Bool { BlockingBuild.isEntitled }

    func authorization() -> BlockingAuthorization {
        guard isAvailable else { return .unavailable }
        switch AuthorizationCenter.shared.authorizationStatus {
        case .approved: return .approved
        case .denied: return .denied
        default: return .notDetermined
        }
    }

    func requestAuthorization() async -> BlockingAuthorization {
        guard isAvailable else { return .unavailable }
        try? await AuthorizationCenter.shared.requestAuthorization(for: .individual)
        return authorization()
    }

    func selectionCount(_ selection: Data) -> Int {
        guard let value = ShieldControl.decode(selection) else { return 0 }
        return value.applicationTokens.count + value.categoryTokens.count + value.webDomainTokens.count
    }

    func shield(selection: Data) {
        guard let value = ShieldControl.decode(selection) else { return }
        ShieldControl.apply(value)
    }

    func unshield() {
        let store = ShieldControl.store
        store.shield.applications = nil
        store.shield.applicationCategories = nil
        store.shield.webDomains = nil
        store.shield.webDomainCategories = nil
        store.clearAllSettings()
    }

    func shieldFocus(allow: Data?) {
        ShieldControl.applyFocus(allow: allow.flatMap(ShieldControl.decode))
    }

    func unshieldFocus() {
        ShieldControl.clearFocus()
    }

    func shieldSummary() -> String {
        let shield = ShieldControl.store.shield
        return "apps=\(shield.applications?.count ?? 0) categories=\(shield.applicationCategories == nil ? "nil" : "set") "
            + "web=\(shield.webDomains?.count ?? 0) webCategories=\(shield.webDomainCategories == nil ? "nil" : "set")"
    }

    func startReblockSchedule(_ schedule: ReblockSchedule) throws {
        try DeviceActivityCenter().startMonitoring(ShieldControl.unlockActivity, during: Self.activitySchedule(schedule))
    }

    func replaceUnblockSchedules(_ schedules: [ReblockSchedule]) {
        let center = DeviceActivityCenter()
        center.stopMonitoring(ShieldControl.unblockActivities)
        for (name, schedule) in zip(ShieldControl.unblockActivities, schedules) {
            // 登録できなくても、GhostPace を開いたときに決定表で合わせる
            do {
                try center.startMonitoring(name, during: Self.activitySchedule(schedule))
            } catch {
                BlockDebugTrace.add("unblock schedule failed: \(error)", now: schedule.start)
            }
        }
    }

    private static func activitySchedule(_ schedule: ReblockSchedule) -> DeviceActivitySchedule {
        let calendar = Calendar.current
        let parts: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute]
        return DeviceActivitySchedule(
            intervalStart: calendar.dateComponents(parts, from: schedule.start),
            intervalEnd: calendar.dateComponents(parts, from: schedule.end),
            repeats: false,
            warningTime: schedule.warningMinutes.map { DateComponents(minute: $0) })
    }

    func stopReblockSchedule() {
        DeviceActivityCenter().stopMonitoring([ShieldControl.unlockActivity])
    }
}

/// Family Controls の許可が入った版（project.yml の BLOCKING_ENTITLED）。シミュレーターでは動かない。
enum BlockingBuild {
    #if BLOCKING_ENTITLED && !targetEnvironment(simulator)
    static let isEntitled = true
    #else
    static let isEntitled = false
    #endif
}
