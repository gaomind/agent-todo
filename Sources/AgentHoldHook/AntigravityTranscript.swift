import Darwin
import Foundation

enum AntigravityTranscript {
    private static let maximumTailBytes = 2 * 1024 * 1024

    struct Reply {
        let turnID: String
        let text: String
        let receivedAt: Date
    }

    private struct Step: Decodable {
        let step_index: Int
        let source: String
        let type: String
        let status: String
        let created_at: String?
        let content: String?
        let truncated_fields: [String]?
        let tool_calls: [ToolCall]?

        struct ToolCall: Decodable {}

        var isFinalResponse: Bool {
            type == "PLANNER_RESPONSE" && source == "MODEL" && status == "DONE"
                && tool_calls?.isEmpty != false && truncated_fields?.contains("tool_calls") != true
        }
    }

    private struct Turn {
        let response: Step
        let user: Step?
    }

    static func reply(at path: String, conversation: String, prompt: String) -> Reply? {
        let userHome = ProcessInfo.processInfo.environment["HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        let home = URL(fileURLWithPath: userHome, isDirectory: true).path
        let directories = [".gemini", "antigravity-cli", "brain", conversation, ".system_generated", "logs"]
        let filename = String(path.split(separator: "/").last ?? "")
        let relativePath = (directories + [filename]).joined(separator: "/")
        guard userHome.hasPrefix("/"), let id = UUID(uuidString: conversation),
              id.uuidString.lowercased() == conversation.lowercased(),
              filename == "transcript_full.jsonl" || filename == "transcript.jsonl",
              path == home + "/" + relativePath || path == "~/" + relativePath else { return nil }

        var directory = open(home, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { return nil }
        defer { close(directory) }
        for component in directories {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { return nil }
            close(directory)
            directory = next
        }

        let decoder = JSONDecoder()
        guard let transcript = lines(in: directory, filename: filename),
              let turn = scan(transcript, decoder: decoder) else { return nil }
        let final = turn.response
        var user = turn.user
        if user == nil, filename == "transcript_full.jsonl", transcript.startsMidFile,
           let compact = lines(in: directory, filename: "transcript.jsonl"),
           let compactTurn = scan(compact, decoder: decoder),
           compactTurn.response.step_index == final.step_index,
           compactTurn.response.created_at == final.created_at {
            // Large tool results can put the prompt beyond the full tail. Use the
            // compact boundary only when both snapshots identify the same response.
            user = compactTurn.user
        }
        guard let user, let timestamp = user.created_at, timestamp.utf8.count <= 64,
              let content = user.content,
              content.hasPrefix("<USER_REQUEST>\n\(prompt)\n</USER_REQUEST>")
                  || (user.truncated_fields?.contains("content") != true && content == prompt),
              let response = original(final, in: directory, decoder: decoder),
              response.isFinalResponse, let text = response.content, let date = response.created_at,
              date.utf8.count <= 64, let receivedAt = parseDate(date) else { return nil }
        return Reply(turnID: "\(user.step_index):\(timestamp)", text: text, receivedAt: receivedAt)
    }

    private static func scan(_ transcript: TranscriptTail, decoder: JSONDecoder) -> Turn? {
        var transcript = transcript
        var lastIndex = Int.max
        var final: Step?
        while let line = transcript.popLastLine() {
            guard let step = try? decoder.decode(Step.self, from: line),
                  step.step_index >= 0, step.step_index < lastIndex,
                  final != nil || step.status != "ERROR" else { return nil }
            lastIndex = step.step_index
            if step.type == "PLANNER_RESPONSE", final == nil {
                guard step.isFinalResponse else { return nil }
                final = step
            }
            if step.type == "USER_INPUT" {
                guard step.source == "USER_EXPLICIT", step.status == "DONE", let final else { return nil }
                return Turn(response: final, user: step)
            }
        }
        return final.map { Turn(response: $0, user: nil) }
    }

    private static func parseDate(_ date: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(date))
            ?? (try? Date.ISO8601FormatStyle().parse(date))
    }

    private static func original(_ step: Step, in directory: Int32, decoder: JSONDecoder) -> Step? {
        guard step.truncated_fields?.contains("content") == true else { return step }
        guard var full = lines(in: directory, filename: "transcript_full.jsonl") else { return nil }
        while let line = full.popLastLine() {
            guard let candidate = try? decoder.decode(Step.self, from: line),
                  candidate.step_index >= step.step_index else { return nil }
            if candidate.step_index == step.step_index {
                guard candidate.created_at == step.created_at, candidate.source == step.source,
                      candidate.type == step.type, candidate.truncated_fields?.contains("content") != true
                else { return nil }
                return candidate
            }
        }
        return nil
    }

    private struct TranscriptTail {
        let data: Data
        let startsMidFile: Bool
        let beginning: Data.Index
        var end: Data.Index

        init(data: Data, startsMidFile: Bool) {
            self.data = data
            self.startsMidFile = startsMidFile
            beginning = startsMidFile ? data.firstIndex(of: 0x0A).map { $0 + 1 } ?? data.endIndex : data.startIndex
            end = data.endIndex
        }

        mutating func popLastLine() -> Data? {
            while end > beginning, data[end - 1] == 0x0A { end -= 1 }
            guard end > beginning else { return nil }
            let start = data[beginning..<end].lastIndex(of: 0x0A).map { $0 + 1 } ?? beginning
            let line = data[start..<end]
            end = start
            return line
        }
    }

    private static func lines(in directory: Int32, filename: String) -> TranscriptTail? {
        let descriptor = openat(directory, filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(), metadata.st_nlink == 1, metadata.st_size > 0 else { return nil }
        let count = Int(min(metadata.st_size, Int64(maximumTailBytes)))
        let offset = UInt64(metadata.st_size) - UInt64(count)
        do {
            try file.seek(toOffset: offset)
            guard let data = try file.read(upToCount: count), data.count == count else { return nil }
            return TranscriptTail(data: data, startsMidFile: offset != 0)
        } catch {
            return nil
        }
    }
}
