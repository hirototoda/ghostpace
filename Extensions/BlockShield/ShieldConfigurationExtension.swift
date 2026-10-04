import ManagedSettings
import ManagedSettingsUI
import UIKit

/// シールドの見た目（BLK-05、docs/product/features/app-blocking.md「シールド」）。
/// 本体が書いた差の材料から、今の時刻の分まで計算して出す。出すたびに「シールドが出た」を記録する。
final class ShieldConfigurationExtension: ShieldConfigurationDataSource {
    override func configuration(shielding application: Application) -> ShieldConfiguration { make() }

    override func configuration(shielding application: Application, in category: ActivityCategory) -> ShieldConfiguration {
        make()
    }

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration { make() }

    override func configuration(shielding webDomain: WebDomain, in category: ActivityCategory) -> ShieldConfiguration {
        make()
    }

    private func make() -> ShieldConfiguration {
        let now = SystemClock().now()
        BlockDebugTrace.add("shield shown", now: now)
        let store = BlockShared.defaults.map(UserDefaultsBlockStore.init)
        let text = ShieldText.make(snapshot: store?.raceSnapshot, now: now, calendar: .app(timeZone: .current),
                                   isFocusBlocking: store?.state.isFocusBlocking ?? false)
        if let url = BlockShared.eventLogURL {
            try? FileBlockEventLog(url: url).append(
                BlockEvent(occurredAt: now, timeZoneId: TimeZone.current.identifier, kind: .shieldShown))
        }
        // 色は本体の Theme.focus（indigo）とそろえる
        return ShieldConfiguration(
            backgroundBlurStyle: .systemMaterial,
            icon: UIImage(systemName: "lock.fill")?.withTintColor(.systemIndigo, renderingMode: .alwaysOriginal),
            title: ShieldConfiguration.Label(text: text.title, color: .label),
            subtitle: ShieldConfiguration.Label(text: text.subtitle, color: .secondaryLabel),
            primaryButtonLabel: ShieldConfiguration.Label(text: text.primaryButton, color: .white),
            primaryButtonBackgroundColor: .systemIndigo,
            secondaryButtonLabel: ShieldConfiguration.Label(text: text.secondaryButton, color: .systemIndigo))
    }
}
