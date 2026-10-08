import Foundation
import Darwin

/// Explicit fixture backend for local testing. Production managed storage uses
/// JuiceFSBackend; this class is never selected as an implicit fallback.
public final class LocalDirectoryBackend: StorageBackend {
    private let root: URL
    private let internalRoot: URL
    private let lock: StateLock
    private let marker = "dev.streamdrive.transaction"
    public init(root: URL) throws {
        self.root = root.standardizedFileURL
        try DurableIO.directory(self.root)
        internalRoot = self.root.appendingPathComponent(".streamdrive")
        try DurableIO.directory(internalRoot)
        lock = try StateLock(internalRoot.appendingPathComponent("lock"))
    }
    private func location(_ value: String) throws -> URL {
        let path = try canonicalPath(value)
        var url = root
        for component in path.split(separator: "/") {
            url.appendPathComponent(String(component))
            var info = Darwin.stat()
            if Darwin.lstat(url.path, &info) == 0 {
                guard (info.st_mode & S_IFMT) != S_IFLNK else { throw DriveError(ELOOP, "Fixture backend does not follow symlinks") }
            } else if errno != ENOENT { throw DriveError(errno, "Cannot inspect fixture path") }
        }
        return url
    }
    private func inspect(_ value: String) throws -> FileEntry {
        let path = try canonicalPath(value), url = try location(path)
        var info = Darwin.stat()
        guard Darwin.lstat(url.path, &info) == 0 else { throw DriveError(errno, "Fixture path is unavailable") }
        let type = info.st_mode & S_IFMT
        guard type == S_IFREG || type == S_IFDIR else { throw DriveError(ENOTSUP, "Only regular files and directories are supported") }
        let modified = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        let changed = Int64(info.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(info.st_ctimespec.tv_nsec)
        let accessed = Int64(info.st_atimespec.tv_sec) * 1_000_000_000 + Int64(info.st_atimespec.tv_nsec)
        return FileEntry(id: UInt64(info.st_ino), path: path, kind: type == S_IFDIR ? .directory : .file,
                         size: type == S_IFDIR ? 0 : Int64(info.st_size), modifiedNanoseconds: modified,
                         version: "\(info.st_ino):\(info.st_size):\(modified):\(changed)", mode: UInt32(info.st_mode & 0o7777),
                         accessedNanoseconds: accessed)
    }
    public func stat(_ path: String) throws -> FileEntry { try lock.withLock { try inspect(path) } }
    public func list(_ value: String) throws -> [FileEntry] {
        try lock.withLock {
            let path = try canonicalPath(value)
            guard try inspect(path).kind == .directory else { throw DriveError(ENOTDIR, "Path is not a directory") }
            return try FileManager.default.contentsOfDirectory(atPath: location(path).path)
                .filter { !(path == "/" && $0 == ".streamdrive") }
                .map { try inspect((path == "/" ? "" : path) + "/" + $0) }.sorted { $0.name < $1.name }
        }
    }
    public func read(_ path: String, offset: Int64, length: Int) throws -> Data {
        try lock.withLock {
            guard offset >= 0, length >= 0 else { throw DriveError(EINVAL, "Invalid fixture read range") }
            let entry = try inspect(path)
            guard entry.kind == .file else { throw DriveError(EISDIR, "Cannot read a directory") }
            if offset >= entry.size { return Data() }
            let count = Int(min(Int64(length), entry.size - offset))
            let fd = Darwin.open(try location(path).path, O_RDONLY | O_NOFOLLOW)
            guard fd >= 0 else { throw DriveError(errno, "Cannot open fixture file") }; defer { Darwin.close(fd) }
            var bytes = Data(count: count)
            try bytes.withUnsafeMutableBytes { raw in
                var done = 0
                while done < count {
                    let n = Darwin.pread(fd, raw.baseAddress!.advanced(by: done), count - done, off_t(offset + Int64(done)))
                    if n < 0 { if errno == EINTR { continue }; throw DriveError(errno, "Fixture read failed") }
                    guard n > 0 else { throw DriveError(EIO, "Fixture changed during read") }; done += n
                }
            }
            return bytes
        }
    }
    public func readSnapshot(_ path: String, version: String, offset: Int64, length: Int) throws -> Data {
        try lock.withLock {
            guard try inspect(path).version == version else { throw DriveError(ESTALE, "Fixture version changed") }
            let result = try read(path, offset: offset, length: length)
            guard try inspect(path).version == version else { throw DriveError(ESTALE, "Fixture changed during read") }
            return result
        }
    }
    private func receipt(_ url: URL) -> String? {
        var bytes = [UInt8](repeating: 0, count: 256)
        let count = getxattr(url.path, marker, &bytes, bytes.count, 0, XATTR_NOFOLLOW)
        return count > 0 ? String(bytes: bytes.prefix(count), encoding: .utf8) : nil
    }
    public func commit(_ commit: FileCommit) throws -> FileEntry {
        try lock.withLock {
            let destination = try location(commit.path)
            guard commit.path != "/", commit.finalSize >= 0, commit.baseVisibleSize >= 0,
                  commit.baseVisibleSize <= commit.finalSize, UUID(uuidString: commit.transactionID) != nil else { throw DriveError(EINVAL, "Invalid fixture commit") }
            if receipt(destination) == commit.transactionID { return try inspect(commit.path) }
            let current: FileEntry?
            do { current = try inspect(commit.path) }
            catch let error as DriveError where error.code == ENOENT { current = nil }
            guard current?.version == commit.expectedVersion else { throw DriveError(ESTALE, "Remote file changed; local writes were retained") }
            if let current, current.kind != .file { throw DriveError(EISDIR, "Cannot replace a directory") }
            let stage = internalRoot.appendingPathComponent("stage-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: stage) }
            if current != nil { try FileManager.default.copyItem(at: destination, to: stage) }
            let fd = Darwin.open(stage.path, O_RDWR | O_CREAT | O_NOFOLLOW, mode_t(commit.mode))
            guard fd >= 0 else { throw DriveError(errno, "Cannot stage fixture commit") }; defer { Darwin.close(fd) }
            guard Darwin.ftruncate(fd, off_t(commit.baseVisibleSize)) == 0, Darwin.ftruncate(fd, off_t(commit.finalSize)) == 0 else { throw DriveError(errno, "Cannot set fixture size") }
            for extent in commit.extents {
                guard extent.offset >= 0, extent.length >= 0, extent.length <= commit.finalSize,
                      extent.offset <= commit.finalSize - extent.length else { throw DriveError(EINVAL, "Invalid fixture write extent") }
                let source = Darwin.open(extent.blobURL.path, O_RDONLY | O_NOFOLLOW)
                guard source >= 0 else { throw DriveError(errno, "Journal payload unavailable") }; defer { Darwin.close(source) }
                var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
                var at: Int64 = 0
                while at < extent.length {
                    let count = Int(min(Int64(buffer.count), extent.length - at))
                    let n = Darwin.pread(source, &buffer, count, off_t(at))
                    if n < 0 { if errno == EINTR { continue }; throw DriveError(errno, "Cannot read journal payload") }
                    guard n > 0 else { throw DriveError(EIO, "Journal payload is short") }
                    try buffer.withUnsafeBytes { bytes in
                        var done = 0
                        while done < n {
                            let wrote = Darwin.pwrite(fd, bytes.baseAddress!.advanced(by: done), n - done, off_t(extent.offset + at + Int64(done)))
                            if wrote < 0 { if errno == EINTR { continue }; throw DriveError(errno, "Cannot write fixture stage") }
                            guard wrote > 0 else { throw DriveError(EIO, "Fixture write made no progress") }; done += wrote
                        }
                    }
                    at += Int64(n)
                }
            }
            let token = Data(commit.transactionID.utf8)
            let marked = token.withUnsafeBytes { fsetxattr(fd, marker, $0.baseAddress, token.count, 0, 0) }
            guard marked == 0, Darwin.fsync(fd) == 0 else { throw DriveError(errno, "Cannot persist fixture commit") }
            guard Darwin.rename(stage.path, destination.path) == 0 else { throw DriveError(errno, "Cannot publish fixture commit") }
            try DurableIO.syncDirectory(destination.deletingLastPathComponent())
            return try inspect(commit.path)
        }
    }
    public func createDirectory(_ path: String) throws -> FileEntry {
        try lock.withLock {
            let url = try location(path)
            guard Darwin.mkdir(url.path, 0o755) == 0 else { throw DriveError(errno, "Cannot create directory") }
            try DurableIO.syncDirectory(url.deletingLastPathComponent()); return try inspect(path)
        }
    }
    public func move(_ source: String, to destination: String) throws {
        try lock.withLock {
            guard source != "/", destination != "/" else { throw DriveError(EBUSY, "Cannot rename root") }
            let from = try location(source), to = try location(destination)
            guard Darwin.rename(from.path, to.path) == 0 else { throw DriveError(errno, "Cannot rename fixture path") }
            try DurableIO.syncDirectory(from.deletingLastPathComponent()); try DurableIO.syncDirectory(to.deletingLastPathComponent())
        }
    }
    public func remove(_ path: String, directory: Bool) throws {
        try lock.withLock {
            guard path != "/" else { throw DriveError(EBUSY, "Cannot delete root") }
            let url = try location(path)
            let code = directory ? Darwin.rmdir(url.path) : Darwin.unlink(url.path)
            guard code == 0 else { throw DriveError(errno, "Cannot remove fixture path") }
            try DurableIO.syncDirectory(url.deletingLastPathComponent())
        }
    }
}
