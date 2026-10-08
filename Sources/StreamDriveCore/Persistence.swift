import Foundation
import Darwin
import CSQLite

final class Database {
    private var handle: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular else { throw DriveError(EACCES, "State database must be a regular file") }
        }
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw DriveError(EIO, "Cannot open state database")
        }
        sqlite3_busy_timeout(handle, 10_000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=FULL")
        try execute("PRAGMA fullfsync=ON")
        try execute("PRAGMA checkpoint_fullfsync=ON")
        try execute("CREATE TABLE IF NOT EXISTS records (kind TEXT NOT NULL, key TEXT NOT NULL, value BLOB NOT NULL, PRIMARY KEY(kind,key))")
    }
    deinit { sqlite3_close(handle) }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DriveError(EIO, "State database statement failed")
        }
        return statement
    }
    private func bind(_ value: String, at index: Int32, to statement: OpaquePointer) {
        _ = sqlite3_bind_text(statement, index, value, -1, transient)
    }
    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw DriveError(EIO, "State database transaction failed") }
    }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let result = try body(); try execute("COMMIT"); return result }
        catch { try? execute("ROLLBACK"); throw error }
    }
    func put<T: Encodable>(_ kind: String, _ key: String, _ value: T) throws {
        let data = try JSONEncoder().encode(value)
        let stmt = try prepare("INSERT INTO records(kind,key,value) VALUES(?,?,?) ON CONFLICT(kind,key) DO UPDATE SET value=excluded.value")
        defer { sqlite3_finalize(stmt) }
        bind(kind, at: 1, to: stmt); bind(key, at: 2, to: stmt)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, 3, $0.baseAddress, Int32(data.count), transient) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw DriveError(EIO, "Cannot persist drive state") }
    }
    func get<T: Decodable>(_ kind: String, _ key: String, as: T.Type = T.self) throws -> T? {
        let stmt = try prepare("SELECT value FROM records WHERE kind=? AND key=?")
        defer { sqlite3_finalize(stmt) }; bind(kind, at: 1, to: stmt); bind(key, at: 2, to: stmt)
        let code = sqlite3_step(stmt)
        if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW else { throw DriveError(EIO, "Cannot read drive state") }
        return try decode(stmt, as: T.self)
    }
    func all<T: Decodable>(_ kind: String, as: T.Type = T.self) throws -> [T] {
        let stmt = try prepare("SELECT value FROM records WHERE kind=? ORDER BY key")
        defer { sqlite3_finalize(stmt) }; bind(kind, at: 1, to: stmt)
        var values: [T] = []
        while true {
            let code = sqlite3_step(stmt)
            if code == SQLITE_DONE { return values }
            guard code == SQLITE_ROW else { throw DriveError(EIO, "Cannot enumerate drive state") }
            values.append(try decode(stmt, as: T.self))
        }
    }
    func delete(_ kind: String, _ key: String) throws {
        let stmt = try prepare("DELETE FROM records WHERE kind=? AND key=?")
        defer { sqlite3_finalize(stmt) }; bind(kind, at: 1, to: stmt); bind(key, at: 2, to: stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw DriveError(EIO, "Cannot update drive state") }
    }
    func clear(_ kind: String) throws {
        let stmt = try prepare("DELETE FROM records WHERE kind=?")
        defer { sqlite3_finalize(stmt) }; bind(kind, at: 1, to: stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw DriveError(EIO, "Cannot clear drive state") }
    }
    private func decode<T: Decodable>(_ stmt: OpaquePointer, as: T.Type) throws -> T {
        let count = Int(sqlite3_column_bytes(stmt, 0))
        guard let pointer = sqlite3_column_blob(stmt, 0), count > 0 else { throw DriveError(EIO, "Invalid persisted drive state") }
        return try JSONDecoder().decode(T.self, from: Data(bytes: pointer, count: count))
    }
}

final class StateLock {
    private let local = NSRecursiveLock()
    private let fd: Int32
    private var depth = 0
    init(_ url: URL) throws {
        fd = Darwin.open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw DriveError(errno, "Cannot lock drive state") }
    }
    deinit { Darwin.close(fd) }
    func withLock<T>(_ body: () throws -> T) throws -> T {
        local.lock(); defer { local.unlock() }
        if depth == 0 {
            while flock(fd, LOCK_EX) != 0 {
                if errno != EINTR { throw DriveError(errno, "Cannot acquire drive state lock") }
            }
        }
        depth += 1
        defer { depth -= 1; if depth == 0 { flock(fd, LOCK_UN) } }
        return try body()
    }
}

enum DurableIO {
    static func directory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeDirectory else { throw DriveError(EACCES, "State path must be a directory") }
    }
    static func write(_ data: Data, to url: URL) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".tmp-" + UUID().uuidString)
        let fd = Darwin.open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw DriveError(errno, "Cannot stage local data") }
        defer { Darwin.close(fd); try? FileManager.default.removeItem(at: temp) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < data.count {
                let wrote = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), data.count - offset)
                if wrote < 0 { if errno == EINTR { continue }; throw DriveError(errno, "Local write failed") }
                guard wrote > 0 else { throw DriveError(EIO, "Local write made no progress") }
                offset += wrote
            }
        }
        guard Darwin.fsync(fd) == 0, fcntl(fd, F_FULLFSYNC) == 0 else { throw DriveError(errno, "Cannot persist local data") }
        guard Darwin.rename(temp.path, url.path) == 0 else { throw DriveError(errno, "Cannot publish local data") }
        try syncDirectory(url.deletingLastPathComponent())
    }
    static func syncDirectory(_ url: URL) throws {
        let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw DriveError(errno, "Cannot open state directory") }
        defer { Darwin.close(fd) }
        guard Darwin.fsync(fd) == 0 else { throw DriveError(errno, "Cannot persist state directory") }
    }
    static func allocatedBytes(_ url: URL) -> Int64 {
        var s = Darwin.stat()
        return url.path.withCString { Darwin.lstat($0, &s) } == 0 ? Int64(s.st_blocks) * 512 : 0
    }
    static func freeBytes(_ url: URL) throws -> Int64 {
        let attrs = try FileManager.default.attributesOfFileSystem(forPath: url.path)
        guard let number = attrs[.systemFreeSize] as? NSNumber else { throw DriveError(EIO, "Cannot read local free space") }
        return number.int64Value
    }
}
