import Foundation
import Testing
@testable import AgentHold

struct HoldTests {
    @Test
    func rejectsUnknownHoldStatus() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(HoldStatus.self, from: Data("\"unknown\"".utf8))
        }
    }

    @MainActor
    @Test(arguments: HoldStatus.allCases)
    func copiesTheEntireEditedConditionAndSavedExcerpt(status: HoldStatus) {
        let condition = "中文恢复条件\n**核对审批单**\n`AH-02` 已确认\n最后一行保留"
        let item = HoldItem(id: UUID(), sessionID: UUID(), turnID: nil, cwd: "/example",
                            detectedAt: .now, evidence: "编辑前的原回复", condition: condition,
                            status: status, wasEdited: true)
        var copied: [String] = []
        let row = HoldRow(item: item, onStatus: { _ in }, onCondition: { _ in false }) { text in
            copied.append(text)
            return true
        }

        #expect(row.copyCondition())
        #expect(copied == ["""
        ⌘ Codex · 待办

        当前恢复条件
        \(condition)

        状态：\(status.label)
        项目：example
        项目目录：/example
        Codex 会话：\(item.sessionID.uuidString.lowercased())
        记录时间：\(item.detectedAt.ISO8601Format())

        原始 Codex 回复（已保存摘录）
        编辑前的原回复
        """])
    }

    @MainActor
    @Test
    func summarizesTheRowAndReadsCompleteReplyOnlyOnCopy() throws {
        let condition = "等待事项：麻烦您先确认 AH-02\n不要更换 Envoy 版本"
        let item = HoldItem(id: UUID(), sessionID: UUID(), turnID: "turn-2", cwd: nil,
                            detectedAt: .now, evidence: "旧恢复条件", condition: condition,
                            status: .waiting, wasEdited: true)
        let source = "原始回复首段\n\n" + String(repeating: "- **保留 Markdown**\n", count: 2_000) + "最后保留的一行\n"
        var reads = 0
        var copied: [String] = []
        let row = HoldRow(item: item, onStatus: { _ in }, onCondition: { _ in false }, sourceContext: {
            reads += 1
            return (source, true)
        }) { text in
            copied.append(text)
            return true
        }

        #expect(item.actionTitle == "先确认 AH-02 不要更换 Envoy 版本")
        #expect(reads == 0)
        #expect(row.copyCondition())
        #expect(reads == 1)
        let text = try #require(copied.first)
        #expect(text.hasPrefix("⌘ Codex · 待办\n\n当前恢复条件\n\(condition)\n\n"))
        #expect(text.contains("\n轮次：turn-2\n"))
        #expect(!text.contains("项目目录"))
        #expect(!text.contains("旧恢复条件"))
        #expect(text.hasSuffix("\n\n原始 Codex 回复（已截断）\n\(source)"))
    }

    @Test(arguments: [
        ("我还需要你确认发布版本，然后我再继续…", "确认发布版本"),
        ("部署已发起，等发布状态变绿后再验收", "等发布状态变绿后再验收"),
        ("我还需要你确认 AH-02，然后我再继续，但不要部署", "确认 AH-02，然后我再继续，但不要部署"),
        ("请不要跳过 HTNN 身份校验", "不要跳过 HTNN 身份校验"),
    ])
    func prioritizesActionsAndKeepsMaterialDetails(example: (condition: String, title: String)) {
        let item = HoldItem(id: UUID(), sessionID: UUID(), turnID: nil, cwd: nil,
                            detectedAt: .now, evidence: example.condition, condition: example.condition,
                            status: .waiting)
        #expect(item.actionTitle == example.title)
    }

    @Test
    func detectsExplicitChineseAndEnglishBlockers() {
        #expect(HoldDetector.conditions(in: """
        已完成配置。
        **我还需要你在 ArgoCD 手动同步，之后我再做只读验收。**
        等待审批通过后再发布。
        I can't continue until you provide the approved release ID.
        部署已发起，等发布状态变绿后再验收。
        目前尚未创建文件。请提供目标仓库路径，我会先检查该目录。
        """) == [
            "我还需要你在 ArgoCD 手动同步，之后我再做只读验收",
            "等待审批通过后再发布",
            "I can't continue until you provide the approved release ID",
            "部署已发起，等发布状态变绿后再验收",
            "请提供目标仓库路径，我会先检查该目录",
        ])
    }

    @Test
    func recognizesStandaloneConditionsUnderExplicitLabels() {
        #expect(HoldDetector.conditions(in: """
        - **等待事项：** 灰度审批
        - **Waiting for:** production release approval
        """) == ["灰度审批", "production release approval"])
    }

    @Test
    func preservesInlinePunctuationAndSplitsSentenceEndings() {
        #expect(HoldDetector.conditions(in:
            "恢复条件：保留 app.example/path!?segment。恢复条件：中文审批！？恢复条件：Approve build!?\u{00a0}恢复条件：尾部句号."
        ) == [
            "保留 app.example/path!?segment",
            "中文审批",
            "Approve build",
            "尾部句号",
        ])
    }

    @Test
    func recognizesAConditionAfterAnUnbrokenPunctuationRun() {
        let run = String(repeating: "!?", count: 8_190)
        #expect(HoldDetector.conditions(in: "\(run)a。恢复条件：收到审批后继续。") == ["收到审批后继续"])
    }

    @Test
    func excludesSuggestionsCompletedWorkAndExamples() {
        let message = [
            "我已经确认并验证了配置。",
            "我不再等待审批，已继续完成。",
            "如果你愿意，我可以继续加一轮测试。",
            "我正在检查后台进度。",
            "> 我需要你确认权限。",
            "```text",
            "I need you to provide the credentials.",
            "```",
            "I need your approval only if you want me to deploy later.",
        ].joined(separator: "\n")
        #expect(HoldDetector.conditions(in: message).isEmpty)
    }

    @MainActor
    @Test
    func deduplicatesAndPersistsManualCorrection() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "holds.json")
        let store = HoldStore(file: file)
        let session = UUID().uuidString

        func reply(_ message: String, turn: String = "turn-1") -> CodexReply {
            CodexReply(sessionID: session, turnID: turn, cwd: "/tmp/John's project",
                       message: message, receivedAt: .now)
        }

        let original = reply("我需要你确认发布版本。")
        store.ingest(original)
        store.ingest(original)
        let item = try #require(store.items.first)
        #expect(store.items.count == 1)
        #expect(item.resumeCommand == "codex -C '/tmp/John'\"'\"'s project' resume \(session.lowercased())")

        store.changeStatus(of: item.id, to: .dismissed)
        #expect(store.changeCondition(of: item.id, to: "确认发布单上的版本"))
        store.ingest(reply("我需要你确认正式发布版本。"))
        #expect(store.items.count == 2)
        #expect(store.items.last?.status == .waiting)
        store.ingest(reply("已完成。"))
        #expect(store.items.count == 1)
        #expect(store.items.first?.id == item.id)
        #expect(store.items.first?.status == .dismissed)
        #expect(store.items.first?.condition == "确认发布单上的版本")
        #expect(store.items.first?.evidence == "我需要你确认发布版本")

        let restored = HoldStore(file: file)
        #expect(restored.items.first?.status == .dismissed)
        #expect(restored.items.first?.id == item.id)
    }

    @MainActor
    @Test
    func retriesTheSameReplyAfterWriteFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "holds.json")
        let store = HoldStore(file: file)
        let reply = CodexReply(sessionID: UUID().uuidString, turnID: "turn-1", cwd: nil,
                               message: "等待审批通过后再发布。", receivedAt: .now)

        try Data().write(to: directory)
        #expect(!store.ingest(reply))
        #expect(store.items.isEmpty)
        #expect(store.errorMessage != nil)

        try FileManager.default.removeItem(at: directory)
        #expect(store.ingest(reply))
        #expect(store.items.count == 1)
        #expect(store.errorMessage == nil)
        #expect(HoldStore(file: file).items.count == 1)
    }

    @MainActor
    @Test
    func keepsActiveItemsWhenCapacityIsReached() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "holds.json")
        let existing = (1...300).map { index in
            HoldItem(id: UUID(), sessionID: UUID(), turnID: nil, cwd: nil, detectedAt: .now,
                     evidence: "事项 \(index)", condition: "事项 \(index)", status: .waiting)
        }
        try JSONEncoder().encode(existing).write(to: file)
        let store = HoldStore(file: file)
        let reply = CodexReply(sessionID: UUID().uuidString, turnID: "turn-1", cwd: nil,
                               message: "等待审批通过后再发布。", receivedAt: .now)

        #expect(!store.ingest(reply))
        #expect(store.capacityMessage != nil)
        #expect(store.items.map(\.id) == existing.map(\.id))

        store.changeStatus(of: existing[0].id, to: .completed)
        #expect(store.ingest(reply))
        #expect(store.capacityMessage == nil)
        #expect(store.items.count == 300)
        #expect(Array(store.items.dropLast()).map(\.id) == Array(existing.dropFirst()).map(\.id))
        #expect(store.items.last?.condition == "等待审批通过后再发布")
    }
}
