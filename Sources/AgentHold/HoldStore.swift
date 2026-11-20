import Foundation
import SwiftUI

@MainActor
final class HoldStore: ObservableObject {
    @Published private(set) var items: [HoldItem] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var capacityMessage: String?

    private static let capacity = 300
    private static let sourcePrefix = "agenthold-source-"
    private static let omission = "\n\n[Agent Todo：此处省略回复中间内容]\n\n"
    private let file: URL
    private var canSave = true
    private var contexts: URL {
        let name = file.lastPathComponent == "holds.json" ? "Contexts" : file.lastPathComponent + ".contexts"
        return file.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
    }

    init(file: URL? = nil) {
        self.file = file ?? URL.applicationSupportDirectory
            .appending(path: "AgentHold", directoryHint: .isDirectory)
            .appending(path: "holds.json")
        do {
            items = try JSONDecoder().decode([HoldItem].self, from: Data(contentsOf: self.file))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // A new installation has no stored items yet.
        } catch {
            canSave = false
            errorMessage = "读取本地待办失败，暂时无法保存更新。"
        }
        if canSave { removeOrphanedSources() }
    }

    @discardableResult
    func ingest(_ reply: CodexReply, conditions recognizedConditions: [String]? = nil) -> Bool {
        guard reply.provider != .unknown, let session = UUID(uuidString: reply.sessionID),
              reply.message.utf8.count <= HoldDetector.maximumReplyBytes else { return true }

        let conditions = recognizedConditions ?? reply.detectedConditions
        let turnID = reply.turnID.flatMap { $0.isEmpty || $0.utf8.count > 128 ? nil : $0 }
        var nextItems = items.filter { item in
            item.provider != reply.provider || item.sessionID != session || item.turnID != turnID || turnID == nil
                || reply.messageTruncated == true || item.detectedAt > reply.receivedAt
                || item.wasEdited || conditions.contains(item.evidence)
        }
        let additions = conditions.filter { condition in
            !nextItems.contains { item in
                guard item.provider == reply.provider, item.sessionID == session,
                      item.evidence == condition else { return false }
                if reply.provider.canReopenWithoutTurnID && turnID == nil {
                    // Without a turn ID, only a later Stop can reopen a closed condition.
                    return item.status == .waiting || (item.closedAt ?? item.detectedAt) >= reply.receivedAt
                }
                return turnID == nil || item.turnID == turnID || item.status == .waiting
            }
        }
        guard nextItems.count != items.count || !additions.isEmpty else { return true }

        let sourceID = additions.isEmpty ? nil : UUID()
        let truncated = reply.messageTruncated == true
        for condition in additions {
            nextItems.append(HoldItem(id: UUID(), sessionID: session, turnID: turnID,
                                      cwd: reply.cwd.flatMap { $0.utf8.count > 4096 ? nil : $0 },
                                      detectedAt: reply.receivedAt, evidence: condition,
                                      condition: condition, status: .waiting,
                                      sourceID: sourceID, sourceTruncated: truncated ? true : nil,
                                      capturedProvider: reply.provider))
        }
        while nextItems.count > Self.capacity {
            guard let inactive = nextItems.firstIndex(where: {
                $0.status == .completed || $0.status == .dismissed
            }) else {
                capacityMessage = "待办已满。完成或忽略一些现有事项后，再接收新的待办。"
                return false
            }
            nextItems.remove(at: inactive)
        }
        if let sourceID {
            var source = reply.message
            if truncated, let tail = reply.trailingMessage,
               source.utf8.count + Self.omission.utf8.count + tail.utf8.count <= HoldDetector.maximumReplyBytes {
                source += Self.omission + tail
            }
            do {
                guard canSave else { return false }
                try writeSource(source, id: sourceID)
            } catch {
                errorMessage = "保存待办来源失败，将重试。"
                return false
            }
        }
        guard save(nextItems) else {
            if let sourceID { removeSource(sourceFile(sourceID)) }
            return false
        }
        capacityMessage = nil
        return true
    }

    func sourceContext(for item: HoldItem) -> (text: String, isTruncated: Bool)? {
        guard let sourceID = item.sourceID, isContextDirectory() else { return nil }
        let url = sourceFile(sourceID)
        let limit = HoldDetector.maximumReplyBytes
        guard let metadata = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              metadata.isRegularFile == true, metadata.isSymbolicLink == false,
              let length = metadata.fileSize, length > 0, length <= limit,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit + 1), !data.isEmpty, data.count <= limit,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return (text, item.sourceTruncated == true)
    }

    func changeStatus(of id: UUID, to status: HoldStatus) {
        guard let index = index(of: id) else { return }
        var nextItems = items
        nextItems[index].status = status
        nextItems[index].wasEdited = true
        if nextItems[index].provider.canReopenWithoutTurnID, nextItems[index].turnID == nil {
            nextItems[index].closedAt = status == .waiting ? nil : Date()
        }
        save(nextItems)
    }

    func changeCondition(of id: UUID, to draft: String) -> Bool {
        let condition = String(draft.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
        guard !condition.isEmpty, let index = index(of: id) else { return false }
        guard items[index].condition != condition else { return true }
        var nextItems = items
        nextItems[index].condition = condition
        nextItems[index].wasEdited = true
        return save(nextItems)
    }

    private func index(of id: UUID) -> Int? {
        items.firstIndex { $0.id == id }
    }

    private func sourceFile(_ id: UUID) -> URL {
        contexts.appendingPathComponent(Self.sourcePrefix + id.uuidString + ".txt")
    }

    private func isContextDirectory() -> Bool {
        let metadata = try? contexts.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return metadata?.isDirectory == true && metadata?.isSymbolicLink == false
    }

    private func writeSource(_ text: String, id: UUID) throws {
        try FileManager.default.createDirectory(at: contexts, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard isContextDirectory() else { throw CocoaError(.fileWriteInvalidFileName) }
        try Data(text.utf8).write(to: sourceFile(id), options: .atomic)
    }

    private func removeSource(_ url: URL) {
        guard let metadata = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              metadata.isRegularFile == true, metadata.isSymbolicLink == false else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func removeOrphanedSources() {
        guard isContextDirectory(),
              let files = try? FileManager.default.contentsOfDirectory(at: contexts, includingPropertiesForKeys: nil)
        else { return }
        let referenced = Set(items.compactMap(\.sourceID))
        for url in files {
            let name = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "txt", name.hasPrefix(Self.sourcePrefix),
                  let id = UUID(uuidString: String(name.dropFirst(Self.sourcePrefix.count))),
                  url.lastPathComponent == sourceFile(id).lastPathComponent, !referenced.contains(id) else { continue }
            removeSource(url)
        }
    }

    @discardableResult
    private func save(_ nextItems: [HoldItem]) -> Bool {
        guard canSave else { return false }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(nextItems).write(to: file, options: .atomic)
            let oldSources = Set(items.compactMap(\.sourceID))
            let retiredSources = oldSources.subtracting(nextItems.compactMap(\.sourceID))
            items = nextItems
            for id in retiredSources where isContextDirectory() { removeSource(sourceFile(id)) }
            errorMessage = nil
            return true
        } catch {
            errorMessage = "保存本地待办失败，请检查 Application Support 中 AgentHold 目录的权限。"
            return false
        }
    }
}
