import Foundation

/// 睡眠（docs/product/features/digital-detox.md「睡眠」、DTX-02）。
extension AppModel {
    /// 睡眠の時刻（0:00 からの分）。設定に出す
    var sleepStartMinutes: Int { sleepSettings.start }
    var sleepEndMinutes: Int { sleepSettings.end }

    /// 朝の計画・計画のタブに出す睡眠（その日のもの。なければ nil）
    func sleepLine(dayStart: Date) -> SleepLine? {
        guard let sleep, sleep.dayKey == DayBoundary.dayKey(containing: dayStart, calendar: calendar) else { return nil }
        return sleep.line
    }

    /// その日と、その前の6日のうち、まだ睡眠を保存していない日に設定の時刻で保存する（開かなかった日も、次に開いたとき）。
    /// そのあとで設定を変えても、保存した日は変わらない
    func ensureSleep(dayStart: Date, calendar: Calendar) throws {
        let settings = sleepSettings
        for offset in 0..<7 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: dayStart) else { continue }
            let key = DayBoundary.dayKey(containing: day, calendar: calendar)
            if try sleepStore.sleep(dayKey: key) == nil {
                try sleepStore.saveSleep(.fromSetting(startMinutes: settings.start, endMinutes: settings.end, dayStart: day,
                                                      calendar: calendar), dayKey: key, timeZone: calendar.timeZone)
            }
        }
        let key = DayBoundary.dayKey(containing: dayStart, calendar: calendar)
        sleep = try sleepStore.sleep(dayKey: key).map { (key, $0) }
    }

    /// ヘルスケアを読み直す（起動・前面に来たとき・1分ごと・朝の計画を確定したとき）。その日のうち（翌朝4:00まで）だけ、
    /// 手で直していなければ置き換える。今日の計画を確定した後は、ヘルスケアの値で決まっていれば置き換えない（2026-10-03）。
    /// `onlyIfSetting` なら、まだ設定の時刻のときだけ読む（1分ごとの読み直し用）。`confirming` は確定した瞬間の読み直し
    func refreshSleep(onlyIfSetting: Bool = false, confirming: Bool = false) async {
        if onlyIfSetting, sleep?.line.source != .setting { return }
        healthNeedsRequest = await sleepSource.shouldRequestAuthorization()
        if !confirming, isSleepSettled { return }
        guard sleepSource.isAvailable, let current = sleep, current.line.source != .manual else { return }
        let calendar = self.calendar
        let dayStart = DayBoundary.dayStart(containing: clock.now(), calendar: calendar)
        guard current.dayKey == DayBoundary.dayKey(containing: dayStart, calendar: calendar) else { return }
        let (from, to) = SleepPicker.searchRange(dayStart: dayStart, calendar: calendar)
        let intervals = await sleepSource.sleepIntervals(from: from, to: to)
        guard let picked = SleepPicker.pick(intervals, dayStart: dayStart, calendar: calendar) else { return }
        // 読んでいる間に手で直した・日が変わった・確定してヘルスケアの値で決まったときは置き換えない
        guard let latest = sleep, latest.dayKey == current.dayKey, latest.line.source != .manual,
              confirming || !isSleepSettled else { return }
        let line = SleepLine(start: picked.start, end: picked.end, source: .health)
        guard line != latest.line else { return }
        // 裏で読み直すので、保存に失敗しても知らせない（次に開いたときにまた読む）
        try? sleepStore.saveSleep(line, dayKey: current.dayKey, timeZone: calendar.timeZone)
        if (try? sleepStore.sleep(dayKey: current.dayKey)) == line { sleep = (current.dayKey, line) }
    }

    /// 今日の計画を確定し、睡眠がヘルスケアの値で決まっている（それ以上置き換えない、2026-10-03）
    private var isSleepSettled: Bool { isPlanConfirmed && sleep?.line.source == .health }

    /// 「ヘルスケアから読む」。許可を聞いて読み直す
    func requestHealthAccess() async {
        await sleepSource.requestAuthorization()
        await refreshSleep()
    }

    /// 睡眠を直す画面に「ヘルスケアから読み直す」を出すか（ヘルスケアのない端末では出さない）
    var canRereadHealth: Bool { sleepSource.isAvailable }

    enum HealthRereadResult: Equatable {
        /// ヘルスケアの値にした（前と同じ値も含む）
        case replaced
        /// ヘルスケアに記録がなかった（今のまま）
        case noRecord
        /// 置き換えなかった：保存に失敗した（エラーを出す）、またはシートを開いたまま4:00を過ぎた（新しい日を出す）
        case notReplaced
    }

    /// 「ヘルスケアから読み直す」（2026-10-03）。許可をまだ聞いていなければ聞いてから、その日の睡眠を読み直す。
    /// 自分で押したときなので、計画を確定したあとでも・手で直していても置き換える（自動の読み直しの決まりは変えない）
    func rereadSleepFromHealth() async -> HealthRereadResult {
        if await sleepSource.shouldRequestAuthorization() { await sleepSource.requestAuthorization() }
        healthNeedsRequest = await sleepSource.shouldRequestAuthorization()
        guard sleepSource.isAvailable else { return .noRecord }
        let calendar = self.calendar
        let dayStart = DayBoundary.dayStart(containing: clock.now(), calendar: calendar)
        let dayKey = DayBoundary.dayKey(containing: dayStart, calendar: calendar)
        let (from, to) = SleepPicker.searchRange(dayStart: dayStart, calendar: calendar)
        let intervals = await sleepSource.sleepIntervals(from: from, to: to)
        // 画面に出ている睡眠の日（開いたまま4:00を過ぎたら、その日のものではないので置き換えない）
        guard sleep?.dayKey == dayKey else {
            reload(quietly: true)
            return .notReplaced
        }
        guard let picked = SleepPicker.pick(intervals, dayStart: dayStart, calendar: calendar) else { return .noRecord }
        let line = SleepLine(start: picked.start, end: picked.end, source: .health)
        do {
            try sleepStore.saveSleep(line, dayKey: dayKey, timeZone: calendar.timeZone)
        } catch {
            errorMessage = Self.saveErrorMessage
            return .notReplaced
        }
        // ホームの数字（ポイント・目標のゴースト）もすぐ数え直す。reload が今日の睡眠を読み直す
        reload(quietly: true)
        return .replaced
    }

    /// 寝た・起きた時刻を手で直す（ヘルスケアで置き換えなくなる）。起きた時刻が寝た時刻より後で、24時間未満でなければ false。
    /// 画面は寝た時刻を前の夜に合わせてから渡すので、ふつうは通らない（念のための確かめ）
    @discardableResult
    func setSleepManually(start: Date, end: Date) -> Bool {
        guard let current = sleep, end > start, end.timeIntervalSince(start) < 24 * 3600 else {
            errorMessage = Self.invalidSleepMessage
            return false
        }
        saveSleep(SleepLine(start: start, end: end, source: .manual), dayKey: current.dayKey)
        return true
    }

    /// 設定の睡眠の時刻を変える。これから保存する日から効く（保存した日は変わらない）
    func setSleepSetting(startMinutes: Int, endMinutes: Int) {
        // 寝る時刻と起きる時刻が同じだと24時間寝たことになるので、変えない
        guard startMinutes != endMinutes else { return }
        sleepSettings = (startMinutes, endMinutes)
        storeSleepSettings()
    }

    static let invalidSleepMessage = "起きた時刻は、寝た時刻より後にしてください"

    private func saveSleep(_ line: SleepLine, dayKey: String) {
        do {
            try sleepStore.saveSleep(line, dayKey: dayKey, timeZone: calendar.timeZone)
            // 保存したものを読み直す（手で直したときに残した「直す前」も入れる）
            sleep = (dayKey, (try? sleepStore.sleep(dayKey: dayKey)) ?? line)
        } catch {
            errorMessage = Self.saveErrorMessage
        }
    }
}
