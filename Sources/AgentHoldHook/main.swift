import AgentHoldCaptureSupport
import Foundation

private struct StopInput: Decodable {
    let hook_event_name: String?
    let hookEventName: String?
    let session_id: String?
    let sessionId: String?
    let turn_id: String?
    let prompt_id: String?
    let promptId: String?
    let cwd: String?
    let last_assistant_message: String?
    let lastAssistantMessage: String?
    let reason: String?
    let prompt_response: String?
    let timestamp: String?
}

private struct AntigravityStopInput: Decodable {
    let hookEventName: String?
    let conversationId: String?
    let cwd: String?
    let workspacePaths: [String]?
    let transcriptPath: String?
    let lastUserInput: String?
    let executionNum: Int?
    let terminationReason: String?
    let error: String?
    let fullyIdle: Bool?
    let continuationActive: Bool?
}

private struct Reply: Encodable {
    let provider: HoldProvider
    let sessionID: String
    let turnID: String?
    let cwd: String?
    let message: String
    let receivedAt: Date
    let messageTruncated: Bool?
    let trailingMessage: String?
}

private func retainedText(_ message: String, maximumBytes: Int) -> (String, String?) {
    let bytes = message.utf8
    guard bytes.count > maximumBytes else { return (message, nil) }
    // Divide the budget between the beginning and end, avoiding split UTF-8 scalars.
    // Leave room for the marker inserted when Agent Todo presents the two fragments.
    let budget = maximumBytes - 128
    let front = budget * 2 / 3
    var end = bytes.index(bytes.startIndex, offsetBy: front)
    while bytes[end] & 0b1100_0000 == 0b1000_0000 { bytes.formIndex(before: &end) }
    var start = bytes.index(bytes.endIndex, offsetBy: -(budget - front))
    while bytes[start] & 0b1100_0000 == 0b1000_0000 { bytes.formIndex(after: &start) }
    return (String(decoding: bytes[..<end], as: UTF8.self), String(decoding: bytes[start...], as: UTF8.self))
}

private func capture() throws {
    var arguments = CommandLine.arguments.dropFirst()
    guard arguments.popFirst() == "--agent-hold-stop-hook" else { return }
    var provider = HoldProvider.codex
    if arguments.first == "--provider" {
        arguments.removeFirst()
        guard let option = arguments.popFirst(), let selected = HoldProvider(rawValue: option),
              selected != .unknown else { return }
        provider = selected
    }
    let spool: ReplySpool
    if arguments.isEmpty {
        spool = ReplySpool()
    } else {
        guard arguments.popFirst() == "--spool", let path = arguments.popFirst(),
              arguments.isEmpty else { return }
        spool = ReplySpool(root: URL(fileURLWithPath: path, isDirectory: true))
    }

    var input = Data()
    while let chunk = try FileHandle.standardInput.read(upToCount: 32 * 1024), !chunk.isEmpty {
        guard chunk.count <= ReplySpool.maximumInputBytes - input.count else { return }
        input.append(chunk)
    }
    let stop = try JSONDecoder().decode(StopInput.self, from: input)
    let sessionID: String?
    let turn: String?
    let text: String?
    var workspace = stop.cwd
    var sourceDate: Date?
    switch provider {
    case .grok:
        guard (stop.hookEventName == "stop" || stop.hook_event_name == "Stop"),
              stop.reason == "end_turn" else { return }
        sessionID = stop.sessionId ?? stop.session_id
        turn = stop.promptId ?? stop.prompt_id
        text = stop.lastAssistantMessage ?? stop.last_assistant_message
    case .gemini:
        guard stop.hook_event_name == "AfterAgent" else { return }
        sessionID = stop.session_id
        turn = nil
        text = stop.prompt_response
    case .antigravity:
        let stop = try JSONDecoder().decode(AntigravityStopInput.self, from: input)
        guard stop.hookEventName == nil || stop.hookEventName == "Stop",
              stop.fullyIdle == true, stop.continuationActive != true, stop.error?.isEmpty != false,
              stop.terminationReason == "NO_TOOL_CALL" || stop.terminationReason == "model_stop",
              let executionNum = stop.executionNum, executionNum >= 0,
              let conversation = stop.conversationId, UUID(uuidString: conversation) != nil,
              let path = stop.transcriptPath, let prompt = stop.lastUserInput, !prompt.isEmpty,
              let response = AntigravityTranscript.reply(at: path, conversation: conversation, prompt: prompt)
        else { return }
        sessionID = conversation
        turn = response.turnID
        text = response.text
        workspace = stop.cwd.flatMap { $0.hasPrefix("/") ? $0 : nil }
            ?? stop.workspacePaths?.first(where: { $0.hasPrefix("/") })
        sourceDate = response.receivedAt
    case .codex, .claude:
        guard stop.hook_event_name == "Stop" else { return }
        sessionID = stop.session_id
        turn = provider == .claude ? (stop.prompt_id ?? stop.turn_id) : stop.turn_id
        text = stop.last_assistant_message
    case .unknown:
        return
    }
    guard let sessionID, UUID(uuidString: sessionID) != nil, let message = text,
          !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

    let turnID = turn.flatMap { $0.isEmpty || $0.utf8.count > 128 ? nil : $0 }
    let cwd = workspace.flatMap { $0.utf8.count > 4096 ? nil : $0 }
    let encoder = JSONEncoder()
    encoder.outputFormatting = .withoutEscapingSlashes
    let now = Date()
    let receivedAt: Date
    // Gemini emits the local event timestamp but no turn ID. A re-delivered
    // event can retain its receipt time without claiming to have a turn ID.
    if provider == .gemini, let timestamp = stop.timestamp, timestamp.utf8.count <= 64,
       let eventDate = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(timestamp),
       eventDate >= Date(timeIntervalSince1970: 946_684_800), eventDate <= now.addingTimeInterval(60) {
        receivedAt = eventDate
    } else {
        receivedAt = sourceDate ?? now
    }
    func encode(maximumBytes: Int) throws -> Data {
        let (front, tail) = retainedText(message, maximumBytes: maximumBytes)
        return try encoder.encode(Reply(
            provider: provider, sessionID: sessionID, turnID: turnID, cwd: cwd,
            message: front, receivedAt: receivedAt,
            messageTruncated: tail == nil ? nil : true, trailingMessage: tail
        ))
    }
    let encoded = try encode(maximumBytes: 64 * 1024)
    // Unusually escape-heavy text can exceed the spool envelope even within the UTF-8 limit.
    let event = encoded.count <= ReplySpool.maximumEventBytes ? encoded : try encode(maximumBytes: 16 * 1024)
    try spool.append(event)
}

try? capture()
print("{}")
