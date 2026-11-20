import Darwin
import Foundation

public struct ReplySpool: Sendable {
    public static let maximumInputBytes = 4 * 1024 * 1024
    public static let maximumEventBytes = 128 * 1024
    private static let maximumFiles = 256
    private let root: URL

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AgentHold/ReplySpool", isDirectory: true)
    }

    public init(root: URL = ReplySpool.defaultDirectory) {
        self.root = root
    }

    public func append(_ data: Data) throws {
        guard data.count <= Self.maximumEventBytes else { throw SpoolError.eventTooLarge }
        try withLock {
            let files = try entries()
            let overflow = files.count - Self.maximumFiles + 1
            let wallTime = UInt64(max(0, Date().timeIntervalSince1970 * 1_000_000))
            let previous = files.last.flatMap { UInt64($0.lastPathComponent.prefix(20)) } ?? 0
            let next = previous < UInt64.max ? previous + 1 : previous
            let timestamp = String(format: "%020llu", max(wallTime, next))
            let name = "\(timestamp)-\(UUID().uuidString).json"
            try data.write(to: root.appendingPathComponent(name), options: [.atomic])
            if overflow > 0 {
                for file in files.prefix(overflow) {
                    try unlinkEntry(at: file)
                }
            }
        }
    }

    public struct Entry: Sendable {
        public let url: URL
        public let data: Data?
    }

    public func pending(limit: Int = 32) throws -> [Entry] {
        try withLock {
            try entries().prefix(limit).map { url in
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink == false,
                      let size = values.fileSize, size <= Self.maximumEventBytes else {
                    return Entry(url: url, data: nil)
                }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: Self.maximumEventBytes + 1)
                return Entry(url: url, data: data.flatMap { $0.count <= Self.maximumEventBytes ? $0 : nil })
            }
        }
    }

    public func remove(_ entries: [Entry]) throws {
        try withLock {
            for entry in entries {
                try unlinkEntry(at: entry.url)
            }
        }
    }

    private func entries() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            .filter { url in
                let name = url.deletingPathExtension().lastPathComponent
                let pieces = name.split(separator: "-", maxSplits: 1)
                return url.pathExtension == "json"
                    && pieces.count == 2 && pieces[0].count == 20
                    && UInt64(pieces[0]) != nil && UUID(uuidString: String(pieces[1])) != nil
            }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func unlinkEntry(at url: URL) throws {
        if unlink(url.path) != 0 && errno != ENOENT {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func withLock<Result>(_ operation: () throws -> Result) throws -> Result {
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let directory = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard directory.isDirectory == true, directory.isSymbolicLink == false else {
            throw SpoolError.invalidDirectory
        }
        let lockPath = root.appendingPathComponent(".lock").path
        let descriptor = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return try operation()
    }

    private enum SpoolError: Error {
        case eventTooLarge
        case invalidDirectory
    }
}
