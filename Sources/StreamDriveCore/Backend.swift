import Foundation
import Darwin

public enum NodeKind: String, Codable, Sendable { case file, directory }

public struct FileEntry: Codable, Equatable, Sendable {
    public var id: UInt64
    public var path: String
    public var kind: NodeKind
    public var size: Int64
    public var modifiedNanoseconds: Int64
    /// Optional for compatibility with existing caches and older native libraries.
    public var accessedNanoseconds: Int64?
    public var version: String
    public var mode: UInt32
    public var name: String { path == "/" ? "/" : (path as NSString).lastPathComponent }
    public init(id: UInt64, path: String, kind: NodeKind, size: Int64, modifiedNanoseconds: Int64, version: String, mode: UInt32 = 0o644, accessedNanoseconds: Int64? = nil) {
        self.id = id; self.path = path; self.kind = kind; self.size = size
        self.modifiedNanoseconds = modifiedNanoseconds; self.version = version; self.mode = mode
        self.accessedNanoseconds = accessedNanoseconds
    }
}

public struct WriteExtent: Codable, Sendable {
    public var offset: Int64
    public var length: Int64
    public var blobURL: URL
    public init(offset: Int64, length: Int64, blobURL: URL) {
        self.offset = offset; self.length = length; self.blobURL = blobURL
    }
}

public struct FileCommit: Codable, Sendable {
    public var transactionID: String
    public var path: String
    public var expectedVersion: String?
    public var finalSize: Int64
    /// Truncate the cloned base to this size before extending to finalSize.
    /// This prevents data resurrection after truncate followed by extension.
    public var baseVisibleSize: Int64
    public var mode: UInt32
    public var extents: [WriteExtent]
    public init(transactionID: String, path: String, expectedVersion: String?, finalSize: Int64, baseVisibleSize: Int64? = nil, mode: UInt32 = 0o644, extents: [WriteExtent]) {
        self.transactionID = transactionID; self.path = path; self.expectedVersion = expectedVersion
        self.finalSize = finalSize; self.baseVisibleSize = baseVisibleSize ?? finalSize; self.mode = mode; self.extents = extents
    }
}

public struct TransferMetrics: Codable, Sendable {
    public var objectReadBytes: Int64
    public var objectGetRequests: Int64
    public init(objectReadBytes: Int64 = 0, objectGetRequests: Int64 = 0) {
        self.objectReadBytes = objectReadBytes; self.objectGetRequests = objectGetRequests
    }
}

/// The sole transport boundary. Reads are bounded ranges; commits must stage then
/// atomically replace under a cooperative volume lock and reject stale versions.
/// transactionID identifies an acknowledged commit after a client crash.
public protocol StorageBackend: AnyObject {
    func stat(_ path: String) throws -> FileEntry
    func list(_ path: String) throws -> [FileEntry]
    func read(_ path: String, offset: Int64, length: Int) throws -> Data
    func readSnapshot(_ path: String, version: String, offset: Int64, length: Int) throws -> Data
    func commit(_ commit: FileCommit) throws -> FileEntry
    func createDirectory(_ path: String) throws -> FileEntry
    func move(_ source: String, to destination: String) throws
    func remove(_ path: String, directory: Bool) throws
    func close() throws
    func transferMetrics() throws -> TransferMetrics?
}

public extension StorageBackend {
    func close() throws {}
    func transferMetrics() throws -> TransferMetrics? { nil }
    func readSnapshot(_ path: String, version: String, offset: Int64, length: Int) throws -> Data {
        guard try stat(path).version == version else { throw DriveError(ESTALE, "File changed before range read") }
        let bytes = try read(path, offset: offset, length: length)
        guard try stat(path).version == version else { throw DriveError(ESTALE, "File changed during range read") }
        return bytes
    }
}

public struct DriveError: Error, LocalizedError, Sendable {
    public let code: Int32
    public let message: String
    public init(_ code: Int32, _ message: String) { self.code = code; self.message = message }
    public var errorDescription: String? { message }
}

/// Rejects traversal, NULs, reserved internals and alternate spellings of a path.
public func canonicalPath(_ value: String) throws -> String {
    guard value.hasPrefix("/"), !value.contains("\0") else { throw DriveError(22, "Expected an absolute drive path") }
    let parts = value.split(separator: "/", omittingEmptySubsequences: true)
    guard !parts.contains(".."), !parts.contains("."), parts.first != ".streamdrive" else {
        throw DriveError(13, "Reserved or escaping drive path")
    }
    return parts.isEmpty ? "/" : "/" + parts.joined(separator: "/")
}
