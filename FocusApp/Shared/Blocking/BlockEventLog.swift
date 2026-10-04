import Foundation
import Synchronization

/// ブロックの記録1件（BLK-06、data-model.md「BlockEvent」）。足すだけで消さない。
struct BlockEvent: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case shieldShown
        case unlockRequested
        case holdCancelled
        case unlocked
        case reblocked
        /// いつものブロックを始めた（BLK-11。対象がない状態から選んだ。ここからデトックスを数える）
        case started
        /// 対象の選択が読めず消した（BLK-11。選び直すまでブロックがない）
        case selectionLost
        /// GhostPace を開いて、Screen Time の許可が外れているのに気づいた（BLK-11）
        case authorizationLost
        /// GhostPace を開いて、許可が戻っているのに気づいた（BLK-11）
        case authorizationRestored
        /// ゲーム・SNS の時間でいつものブロックを外した（BLK-10・BLK-11。実際に外した時刻）
        case unblockStarted
        /// ゲーム・SNS の時間が終わって（または集中・開けたことで）外していた状態が終わった（BLK-10・BLK-11）
        case unblockEnded
    }

    enum ReblockReason: String, Codable, Sendable {
        /// 自動で戻すしくみが戻した
        case expired
        /// 「今すぐ戻す」
        case manual
        /// 本体を開いたら期限が過ぎていた
        case appForeground
    }

    var id = UUID()
    var occurredAt: Date
    var timeZoneId: String
    var kind: Kind
    var unlockMinutes: Int?
    var reblockReason: ReblockReason?
    var activeSessionId: UUID?
    /// authorizationLost のとき、前に許可を確かめた時刻（そこから外れていたとみなす）
    var sinceAt: Date?
}

/// ブロックの記録の置き場。
protocol BlockEventLogging: Sendable {
    func append(_ event: BlockEvent) throws
    /// 読めた記録を古い順に。壊れた行は読み飛ばす
    func all() throws -> [BlockEvent]
}

/// App Group の JSON Lines ファイル。1件を1行として、追記モードで1回で書く（複数のプロセスが同時に書いても混ざらない）。
struct FileBlockEventLog: BlockEventLogging {
    let url: URL

    func append(_ event: BlockEvent) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var line = try encoder.encode(event)
        line.append(0x0A)
        // 前の行が途中で切れていたら、新しい行から書く
        if endsWithoutNewline() { line.insert(0x0A, at: 0) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path(percentEncoded: false), O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        let written = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == line.count else { throw CocoaError(.fileWriteUnknown) }
    }

    func all() throws -> [BlockEvent] {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return [] }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(BlockEvent.self, from: Data($0)) }
    }

    private func endsWithoutNewline() -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd(), end > 0 else { return false }
        try? handle.seek(toOffset: end - 1)
        return (try? handle.read(upToCount: 1))?.first != 0x0A
    }
}

/// メモリ内の記録（テスト・見本データ用）。
final class MemoryBlockEventLog: BlockEventLogging {
    private let events = Mutex<[BlockEvent]>([])

    init() {}

    func append(_ event: BlockEvent) throws { events.withLock { $0.append(event) } }
    func all() throws -> [BlockEvent] { events.withLock { $0 } }
}
