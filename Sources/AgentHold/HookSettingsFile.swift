import Darwin
import Foundation

enum HookSettingsFile {
    private static let maximumConfigurationBytes = 1024 * 1024

    static func update(_ file: URL, replacement: (Data?) throws -> Data?) throws {
        let directory = file.deletingLastPathComponent()
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        // Serialize writes from multiple running copies of Agent Hold.
        let lock = directory.appendingPathComponent(".agent-hold-settings.lock")
        let descriptor = open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure.writeFailed }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw Failure.writeFailed }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw Failure.concurrentChange }

        let original = try read(file)
        guard let data = try replacement(original?.data) else { return }
        guard data.count <= maximumConfigurationBytes else { throw Failure.invalidSettings }
        let temporary = directory.appendingPathComponent(".agent-hold-\(UUID().uuidString)")
        let output = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw Failure.writeFailed }
        let handle = FileHandle(fileDescriptor: output, closeOnDealloc: true)
        defer {
            try? handle.close()
            try? manager.removeItem(at: temporary)
        }
        try handle.write(contentsOf: data)
        guard fchmod(output, original?.mode ?? 0o600) == 0 else { throw Failure.writeFailed }

        // Also detect edits by programs that do not share Agent Hold's lock.
        guard try read(file) == original else { throw Failure.concurrentChange }
        if original == nil {
            // Publishing by link prevents accidentally overwriting a concurrent first writer.
            if link(temporary.path, file.path) != 0 {
                throw errno == EEXIST ? Failure.concurrentChange : Failure.writeFailed
            }
        } else {
            guard rename(temporary.path, file.path) == 0 else { throw Failure.writeFailed }
        }
    }

    struct Snapshot: Equatable {
        let data: Data
        let mode: mode_t
        let device: dev_t
        let inode: ino_t
    }

    static func read(_ file: URL) throws -> Snapshot? {
        let descriptor = open(file.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw Failure.invalidSettings }
            throw Failure.readFailed
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= maximumConfigurationBytes else { throw Failure.invalidSettings }
        let data = try handle.read(upToCount: maximumConfigurationBytes + 1) ?? Data()
        guard data.count <= maximumConfigurationBytes else { throw Failure.invalidSettings }
        return Snapshot(data: data, mode: info.st_mode & 0o777, device: info.st_dev, inode: info.st_ino)
    }

    enum Failure: LocalizedError {
        case concurrentChange, invalidSettings, readFailed, writeFailed

        var errorDescription: String? {
            switch self {
            case .concurrentChange: "配置正在被其他操作修改。请重新检查后重试。"
            case .invalidSettings: "配置超过 1 MiB 或不是常规文件。"
            case .readFailed: "无法读取用户配置。请检查文件权限。"
            case .writeFailed: "无法保存用户配置。请检查文件权限。"
            }
        }
    }
}
