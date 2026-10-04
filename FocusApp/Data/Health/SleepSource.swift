import Foundation
import HealthKit

/// ヘルスケアの睡眠の記録（DTX-02）。AppModel はこれだけに依存する。
@MainActor
protocol SleepSource: AnyObject {
    /// この端末でヘルスケアを使えるか
    var isAvailable: Bool { get }
    /// 読む許可をまだ聞いていないか（断ったかどうかは iPhone の仕組みで分からない）
    func shouldRequestAuthorization() async -> Bool
    func requestAuthorization() async
    /// 期間に入っている「寝ていた」記録
    func sleepIntervals(from: Date, to: Date) async -> [DateInterval]
}

/// 決まった記録を返す（テスト・見本・ヘルスケアのない端末）。
@MainActor
final class NoSleepSource: SleepSource {
    var intervals: [DateInterval]
    var needsRequest: Bool
    let isAvailable: Bool

    init(isAvailable: Bool = false, needsRequest: Bool = false, intervals: [DateInterval] = []) {
        self.isAvailable = isAvailable
        self.needsRequest = needsRequest
        self.intervals = intervals
    }

    func shouldRequestAuthorization() async -> Bool { isAvailable && needsRequest }
    func requestAuthorization() async { needsRequest = false }
    func sleepIntervals(from: Date, to: Date) async -> [DateInterval] {
        intervals.filter { $0.end > from && $0.start < to }
    }
}

/// 本物のヘルスケア。読むだけで書かない。
@MainActor
final class HealthKitSleepSource: SleepSource {
    private let store = HKHealthStore()
    private let type = HKCategoryType(.sleepAnalysis)

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func shouldRequestAuthorization() async -> Bool {
        guard isAvailable else { return false }
        let status = try? await store.statusForAuthorizationRequest(toShare: [], read: [type])
        return status == .shouldRequest
    }

    func requestAuthorization() async {
        guard isAvailable else { return }
        try? await store.requestAuthorization(toShare: [], read: [type])
    }

    func sleepIntervals(from: Date, to: Date) async -> [DateInterval] {
        guard isAvailable else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to)
        let descriptor = HKSampleQueryDescriptor(predicates: [.categorySample(type: type, predicate: predicate)],
                                                 sortDescriptors: [SortDescriptor(\.startDate)])
        let samples = (try? await descriptor.result(for: store)) ?? []
        // 「寝ていた」だけ（ベッドにいた・起きていたは除く）。Garmin などは寝ていた段階ごとに書く
        let asleep = HKCategoryValueSleepAnalysis.allAsleepValues.map(\.rawValue)
        return samples.filter { asleep.contains($0.value) }.map { DateInterval(start: $0.startDate, end: $0.endDate) }
    }
}
