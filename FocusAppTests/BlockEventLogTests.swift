import Foundation
import Testing
@testable import FocusApp

/// ブロックの記録（BLK-06、data-model.md「ブロックの共有データ」）。足すだけで消さない。
struct BlockEventLogTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "blockEvents-\(UUID().uuidString).jsonl")
    }

    private func event(_ kind: BlockEvent.Kind, at text: String, minutes: Int? = nil,
                       reason: BlockEvent.ReblockReason? = nil, session: UUID? = nil) -> BlockEvent {
        BlockEvent(occurredAt: jst(text), timeZoneId: "Asia/Tokyo", kind: kind, unlockMinutes: minutes,
                   reblockReason: reason, activeSessionId: session)
    }

    @Test func appendedEventsSurviveReopening() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = UUID()
        let events = [
            event(.shieldShown, at: "2026-10-19T11:00"),
            event(.unlockRequested, at: "2026-10-19T11:00:05"),
            event(.holdCancelled, at: "2026-10-19T11:00:20"),
            event(.unlocked, at: "2026-10-19T11:01", minutes: 15, session: session),
            event(.reblocked, at: "2026-10-19T11:16", reason: .expired),
        ]
        let log = FileBlockEventLog(url: url)
        for item in events { try log.append(item) }

        // 開き直しても同じ順で読める
        let reopened = FileBlockEventLog(url: url)
        #expect(try reopened.all() == events)
    }

    @Test func emptyWhenFileMissing() throws {
        #expect(try FileBlockEventLog(url: tempURL()).all().isEmpty)
    }

    @Test func brokenLineIsSkippedAndKept() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let log = FileBlockEventLog(url: url)
        let first = event(.unlocked, at: "2026-10-19T11:01", minutes: 5)
        try log.append(first)
        // 途中で書き込みが切れた行
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"id\":\"broken".utf8))
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.close()
        let second = event(.reblocked, at: "2026-10-19T11:06", reason: .manual)
        try log.append(second)

        #expect(try log.all() == [first, second])
        // 壊れた行も消さない（NFR-02）
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("broken"))
    }

    @Test func appendAfterLineWithoutNewlineStartsNewLine() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{\"half".utf8).write(to: url)
        let log = FileBlockEventLog(url: url)
        let item = event(.shieldShown, at: "2026-10-19T11:00")
        try log.append(item)
        #expect(try log.all() == [item])
    }

    @Test func memoryLogKeepsOrder() throws {
        let log = MemoryBlockEventLog()
        let a = event(.shieldShown, at: "2026-10-19T11:00")
        let b = event(.unlockRequested, at: "2026-10-19T11:00:03")
        try log.append(a)
        try log.append(b)
        #expect(try log.all() == [a, b])
    }
}
