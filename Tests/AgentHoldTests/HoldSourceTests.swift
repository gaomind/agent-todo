import AgentHoldCaptureSupport
import Foundation
import Testing
@testable import AgentHold

@MainActor
struct HoldSourceTests {
    @Test
    func keepsLegacyReadyItemsInWaitingAndAllowsDirectCompletion() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = try #require(UUID(uuidString: fixture.session))
        let original = [("确认版本", HoldStatus.waiting), ("提供工单", .waiting),
                        ("提交审批", .completed), ("安排联调", .dismissed)].map { condition, status in
            HoldItem(id: UUID(), sessionID: session, turnID: "first", cwd: "/example",
                     detectedAt: fixture.receivedAt, evidence: condition, condition: condition,
                     status: status, wasEdited: true)
        }
        var records = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [[String: Any]])
        records[0]["status"] = "ready"
        let legacyData = try JSONSerialization.data(withJSONObject: records)
        try legacyData.write(to: fixture.file)

        let store = HoldStore(file: fixture.file)
        #expect(store.errorMessage == nil)
        #expect(HoldStatus.allCases == [.waiting, .completed, .dismissed])
        #expect(store.items.map(\.id) == original.map(\.id))
        #expect(store.items.map(\.status) == original.map(\.status))
        #expect(try Data(contentsOf: fixture.file) == legacyData)

        let id = original[0].id
        #expect(store.ingest(fixture.reply("恢复条件：确认版本。", turn: "next")))
        #expect(store.items.count == 4)
        #expect(store.changeCondition(of: id, to: "核对审批单"))
        let edited = try #require(store.items.first { $0.id == id })
        let copied = edited.copyText(sourceContext: nil)
        #expect(copied.contains("当前恢复条件\n核对审批单"))
        #expect(copied.contains("状态：等待"))
        #expect(copied.contains("原始 Codex 回复（已保存摘录）\n确认版本"))

        store.changeStatus(of: id, to: .completed)
        let reopened = HoldStore(file: fixture.file)
        #expect(reopened.items.map(\.status) == [.completed, .waiting, .completed, .dismissed])
        #expect(reopened.items.first { $0.id == id }?.condition == "核对审批单")

        reopened.changeStatus(of: id, to: .waiting)
        #expect(HoldStore(file: fixture.file).items.first { $0.id == id }?.status == .waiting)
    }

    @Test
    func sharesOriginalReplyAndRetainsItAcrossManualEditsAndUpdates() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = HoldStore(file: fixture.file)
        let source = """
        调整了 **代理配置**，请参见 `/tmp/example/config.yaml`。

        ```sh
        printf 'ready\n'
        ```
        恢复条件：确认工单。
        恢复条件：安排联调。
        """
        let reply = fixture.reply(source)
        #expect(store.ingest(reply))
        #expect(store.items.count == 2)
        let blobs = try fixture.blobs()
        #expect(blobs.count == 1)
        let originals = store.items
        #expect(originals.allSatisfy { store.sourceContext(for: $0)?.text == source })
        #expect(originals.allSatisfy { store.sourceContext(for: $0)?.isTruncated == false })
        #expect(store.ingest(reply))
        #expect(try fixture.blobs() == blobs)
        let metadata = try String(contentsOf: fixture.file, encoding: .utf8)
        #expect(!metadata.contains("printf"))

        let edited = try #require(originals.first)
        #expect(store.changeCondition(of: edited.id, to: "已核对版本\n等用户回复"))
        store.changeStatus(of: edited.id, to: .completed)
        #expect(try fixture.blobs() == blobs)

        #expect(store.ingest(fixture.reply("恢复条件：等待新审批。", secondsLater: 2)))
        let updated = HoldStore(file: fixture.file)
        let manual = try #require(updated.items.first { $0.id == edited.id })
        #expect(manual.status == .completed)
        #expect(manual.condition == "已核对版本\n等用户回复")
        #expect(updated.sourceContext(for: manual)?.text == source)
        let item = try #require(updated.items.first { $0.id != edited.id })
        #expect(updated.sourceContext(for: item)?.text == "恢复条件：等待新审批。")

        #expect(updated.ingest(fixture.reply("恢复条件：等待新审批。\n额外内容", turn: "next", secondsLater: 3)))
        #expect(updated.items.count == 2)
        #expect(updated.sourceContext(for: item)?.text == "恢复条件：等待新审批。")
        #expect(updated.ingest(fixture.reply("当前没有等待事项。", secondsLater: 4)))
        #expect(try fixture.blobs() == blobs)
    }

    @Test
    func fallsBackForLegacyOrMissingSourceAndOnlyCleansKnownOrphans() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let item = HoldItem(id: UUID(), sessionID: UUID(), turnID: nil, cwd: nil, detectedAt: .now,
                            evidence: "旧摘录", condition: "恢复条件", status: .waiting)
        try JSONEncoder().encode([item]).write(to: fixture.file)
        try FileManager.default.createDirectory(at: fixture.contexts, withIntermediateDirectories: true)
        let orphan = fixture.contexts.appendingPathComponent("agenthold-source-\(UUID().uuidString).txt")
        let unknown = fixture.contexts.appendingPathComponent("not-an-agenthold-snapshot.txt")
        try Data("保留陌生文件".utf8).write(to: unknown)
        try Data("孤立快照".utf8).write(to: orphan)
        let store = HoldStore(file: fixture.file)
        #expect(store.sourceContext(for: item) == nil)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(FileManager.default.fileExists(atPath: unknown.path))

        #expect(store.ingest(fixture.reply("恢复条件：新条件。")))
        let added = try #require(store.items.last)
        let blob = try #require(try fixture.blobs().first)
        try Data([0xFF]).write(to: blob)
        #expect(store.sourceContext(for: added) == nil)
        try Data("损坏的元数据".utf8).write(to: fixture.file)
        _ = HoldStore(file: fixture.file)
        #expect(FileManager.default.fileExists(atPath: blob.path))
        try FileManager.default.removeItem(at: blob)
        #expect(store.sourceContext(for: added) == nil)
    }

    @Test
    func removesTheStagedSourceAfterMetadataFailureAndRetries() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = HoldStore(file: fixture.file)
        try FileManager.default.createDirectory(at: fixture.file, withIntermediateDirectories: false)
        let reply = fixture.reply("恢复条件：等测试通过。")
        #expect(store.ingest(reply) == false)
        #expect(try fixture.blobs().isEmpty)
        #expect(store.items.isEmpty)
        try FileManager.default.removeItem(at: fixture.file)
        #expect(store.ingest(reply))
        let item = try #require(store.items.first)
        #expect(store.sourceContext(for: item)?.text == reply.message)
    }

    @Test
    func hookPreservesTheFullByteBudgetAndMarksOverflowWithoutJoiningForDetection() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let complete = "恢复条件：确认正常回复。\n"
        let normal = complete + String(repeating: "a", count: 65_536 - complete.utf8.count)
        let ordinary = try fixture.capture(normal)
        #expect(ordinary.message == normal)
        #expect(ordinary.messageTruncated != true)
        #expect(ordinary.trailingMessage == nil)

        // The complete condition in the first, unbroken line survives a cut in the second sentence.
        let long = complete.replacingOccurrences(of: "\n", with: "") + "恢复条件：缺失末段"
            + String(repeating: "甲", count: 30_000) + "\n恢复条件：尾部只用于复制。\n末尾🪶"
        let truncated = try fixture.capture(long)
        #expect(truncated.messageTruncated == true)
        #expect(truncated.trailingMessage?.hasSuffix("末尾🪶") == true)
        #expect(truncated.detectedConditions == ["确认正常回复"])
        let store = HoldStore(file: fixture.file)
        #expect(store.ingest(truncated))
        let item = try #require(store.items.first)
        let context = try #require(store.sourceContext(for: item))
        #expect(context.isTruncated)
        #expect(context.text.utf8.count <= 65_536)
        #expect(context.text.contains("此处省略回复中间内容"))
        #expect(context.text.hasSuffix("末尾🪶"))
        let escaped = try fixture.capture(complete + String(repeating: "\u{0001}", count: 40_000) + "转义输入结尾")
        #expect(escaped.messageTruncated == true)
        #expect(escaped.trailingMessage?.hasSuffix("转义输入结尾") == true)
    }

    private struct Fixture {
        let directory: URL
        let session = UUID().uuidString
        let receivedAt = Date()
        var file: URL { directory.appendingPathComponent("holds.json") }
        var contexts: URL { directory.appendingPathComponent("Contexts") }

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }

        func reply(_ text: String, turn: String = "first", secondsLater: TimeInterval = 0) -> CodexReply {
            CodexReply(sessionID: session, turnID: turn, cwd: "/example", message: text,
                       receivedAt: receivedAt.addingTimeInterval(secondsLater))
        }

        func blobs() throws -> [URL] {
            try FileManager.default.contentsOfDirectory(at: contexts, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("agenthold-source-") }
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }

        func capture(_ text: String) throws -> CodexReply {
            let input = directory.appendingPathComponent("input")
            try JSONEncoder().encode([
                "hook_event_name": "Stop", "session_id": session, "turn_id": UUID().uuidString,
                "last_assistant_message": text,
            ]).write(to: input)
            let binaries = Bundle(for: TestBundleMarker.self).bundleURL.deletingLastPathComponent()
            let queue = directory.appendingPathComponent(UUID().uuidString)
            let process = Process()
            process.executableURL = binaries.appendingPathComponent("AgentHoldHook")
            process.arguments = ["--agent-hold-stop-hook", "--spool", queue.path]
            let handle = try FileHandle(forReadingFrom: input)
            defer { try? handle.close() }
            process.standardInput = handle
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            let data = try #require(try ReplySpool(root: queue).pending().first?.data)
            return try JSONDecoder().decode(CodexReply.self, from: data)
        }
    }

    private final class TestBundleMarker: NSObject {}
}
