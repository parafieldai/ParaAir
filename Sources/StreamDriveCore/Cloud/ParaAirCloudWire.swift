import Foundation
import Darwin

/// Spec 2.2 `Entry`. Ids are JSON integers below 2^53 and `mtimeNs` is a decimal string.
public struct WireEntry: Codable, Equatable, Sendable {
    public var id: Int64
    public var path: String
    public var kind: String
    public var size: Int64
    public var mtimeNs: String
    public var version: String
    public var mode: UInt32

    public init(id: Int64, path: String, kind: String, size: Int64, mtimeNs: String, version: String, mode: UInt32) {
        self.id = id; self.path = path; self.kind = kind; self.size = size; self.mtimeNs = mtimeNs; self.version = version; self.mode = mode
    }

    /// Rejects a malformed entry with EIO; `expectingPath` is the path the caller asked about.
    public func fileEntry(expectingPath: String?) throws -> FileEntry {
        let malformed = DriveError(EIO, "ParaAir Cloud returned malformed file metadata")
        guard (1...Self.maxID).contains(id), (try? canonicalPath(path)) == path, expectingPath.map({ $0 == path }) ?? true,
              let nodeKind = NodeKind(rawValue: kind), size >= 0, nodeKind == .file || size == 0, mode <= 0o7777,
              mtimeNs.range(of: "^(0|[1-9][0-9]{0,18})$", options: .regularExpression) != nil, let mtime = Int64(mtimeNs),
              version.range(of: nodeKind == .file ? "^pv:[1-9][0-9]{0,15}$" : "^pd:[1-9][0-9]{0,15}$", options: .regularExpression) != nil else {
            throw malformed
        }
        return FileEntry(id: UInt64(id), path: path, kind: nodeKind, size: size, modifiedNanoseconds: mtime, version: version, mode: mode)
    }

    static let maxID: Int64 = (1 << 53) - 1
}

public struct ParaAirCloudDrive: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var workspaceId: String
    public var name: String
    public var role: String
    public var writable: Bool
    public var chunkSize: Int
    public var createdAt: Date
    public init(id: String, workspaceId: String, name: String, role: String, writable: Bool, chunkSize: Int, createdAt: Date) {
        self.id = id; self.workspaceId = workspaceId; self.name = name; self.role = role
        self.writable = writable; self.chunkSize = chunkSize; self.createdAt = createdAt
    }
    func validated() throws -> ParaAirCloudDrive {
        guard ParaAirCloudIDs.isDriveID(id), ParaAirCloudIDs.isWorkspaceID(workspaceId), !name.isEmpty, name.utf8.count <= 255,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains), chunkSize == ParaAirCloudConfiguration.chunkSize else {
            throw DriveError(EIO, "ParaAir Cloud returned malformed drive details")
        }
        return self
    }
}

public struct ParaAirCloudCapacity: Codable, Equatable, Sendable {
    public var quotaBytes: Int64
    public var usedBytes: Int64
    public var retainedBytes: Int64
    public var reservedBytes: Int64
    public var availableBytes: Int64
    public init(quotaBytes: Int64, usedBytes: Int64, retainedBytes: Int64, reservedBytes: Int64, availableBytes: Int64) {
        self.quotaBytes = quotaBytes; self.usedBytes = usedBytes; self.retainedBytes = retainedBytes
        self.reservedBytes = reservedBytes; self.availableBytes = availableBytes
    }
}

public struct ParaAirCloudLimits: Codable, Equatable, Sendable {
    public var chunkSize: Int
    public var maxFileBytes: Int64
    public var maxManifestChunks: Int
    public var maxListPage: Int
    public var maxMoveDescendants: Int
    public var readTokenSeconds: Int
}

public struct ParaAirCloudDriveDetail: Codable, Equatable, Sendable {
    public var drive: ParaAirCloudDrive
    public var capacity: ParaAirCloudCapacity
    public var limits: ParaAirCloudLimits
}

public struct ParaAirCloudMe: Codable, Equatable, Sendable {
    public struct User: Codable, Equatable, Sendable {
        public var id: String; public var email: String; public var createdAt: Date
        public init(id: String, email: String, createdAt: Date) { self.id = id; self.email = email; self.createdAt = createdAt }
    }
    public struct Session: Codable, Equatable, Sendable {
        public var id: String; public var clientId: String; public var createdAt: Date; public var expiresAt: Date
        public init(id: String, clientId: String, createdAt: Date, expiresAt: Date) {
            self.id = id; self.clientId = clientId; self.createdAt = createdAt; self.expiresAt = expiresAt
        }
    }
    public struct Plan: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var storageLimitBytes: Int64
        public var transferAllowanceBytes: Int64
        public var retentionDays: Int
        public var retentionCapBytes: Int64
        public var seats: Int
        /// Only https on a parafield.ai host; anything else decodes as nil.
        public var manageUrl: URL?
        enum CodingKeys: String, CodingKey {
            case id, name, storageLimitBytes, transferAllowanceBytes, retentionDays, retentionCapBytes, seats, manageUrl
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
            storageLimitBytes = try c.decode(Int64.self, forKey: .storageLimitBytes)
            transferAllowanceBytes = try c.decode(Int64.self, forKey: .transferAllowanceBytes)
            retentionDays = try c.decode(Int.self, forKey: .retentionDays)
            retentionCapBytes = try c.decode(Int64.self, forKey: .retentionCapBytes)
            seats = try c.decode(Int.self, forKey: .seats)
            manageUrl = (try? c.decodeIfPresent(String.self, forKey: .manageUrl)).flatMap { $0 }.flatMap(Self.manageURL)
        }
        public init(id: String, name: String, storageLimitBytes: Int64, transferAllowanceBytes: Int64, retentionDays: Int,
                    retentionCapBytes: Int64, seats: Int, manageUrl: URL?) {
            self.id = id; self.name = name; self.storageLimitBytes = storageLimitBytes; self.transferAllowanceBytes = transferAllowanceBytes
            self.retentionDays = retentionDays; self.retentionCapBytes = retentionCapBytes; self.seats = seats
            self.manageUrl = manageUrl.flatMap { Self.manageURL($0.absoluteString) }
        }
        static func manageURL(_ value: String) -> URL? {
            guard let url = URL(string: value), let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  c.scheme == "https", c.user == nil, c.password == nil, let host = c.host?.lowercased(),
                  host.hasSuffix(".parafield.ai") else { return nil }
            return url
        }
    }
    public struct Usage: Codable, Equatable, Sendable {
        public var storedBytes: Int64
        public var retainedBytes: Int64
        public var reservedBytes: Int64
        public var transferBytes: Int64
        public var uploadedBytes: Int64
        public var periodStart: Date
        public var periodEnd: Date
        public var throttled: Bool
        public var reconciledAt: Date?
        public init(storedBytes: Int64, retainedBytes: Int64, reservedBytes: Int64, transferBytes: Int64, uploadedBytes: Int64,
                    periodStart: Date, periodEnd: Date, throttled: Bool, reconciledAt: Date?) {
            self.storedBytes = storedBytes; self.retainedBytes = retainedBytes; self.reservedBytes = reservedBytes
            self.transferBytes = transferBytes; self.uploadedBytes = uploadedBytes; self.periodStart = periodStart
            self.periodEnd = periodEnd; self.throttled = throttled; self.reconciledAt = reconciledAt
        }
    }
    public struct Workspace: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var kind: String
        public var role: String
        public var status: String
        public var plan: Plan?
        public var usage: Usage?
        /// Absent before the service had billing; a malformed object is nil too, so billing UI fails closed.
        public var billing: ParaAirCloudBilling?
        enum CodingKeys: String, CodingKey { case id, name, kind, role, status, plan, usage, billing }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
            kind = try c.decode(String.self, forKey: .kind); role = try c.decode(String.self, forKey: .role)
            status = try c.decode(String.self, forKey: .status)
            plan = try c.decodeIfPresent(Plan.self, forKey: .plan); usage = try c.decodeIfPresent(Usage.self, forKey: .usage)
            billing = (try? c.decodeIfPresent(ParaAirCloudBilling.self, forKey: .billing)) ?? nil
        }
        public init(id: String, name: String, kind: String, role: String, status: String, plan: Plan?, usage: Usage?,
                    billing: ParaAirCloudBilling? = nil) {
            self.id = id; self.name = name; self.kind = kind; self.role = role; self.status = status
            self.plan = plan; self.usage = usage; self.billing = billing
        }
    }
    public var user: User
    public var session: Session
    public var workspaces: [Workspace]
    public init(user: User, session: Session, workspaces: [Workspace]) {
        self.user = user; self.session = session; self.workspaces = workspaces
    }

    func validated() throws -> ParaAirCloudMe {
        guard ParaAirCloudIDs.isUserID(user.id), !user.email.isEmpty, user.email.utf8.count <= 254,
              !user.email.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              workspaces.allSatisfy({ ParaAirCloudIDs.isWorkspaceID($0.id) }) else {
            throw DriveError(EIO, "ParaAir Cloud returned malformed account details")
        }
        return self
    }
}

public struct ParaAirCloudManifestPage: Codable, Equatable, Sendable {
    public struct ChunkRef: Codable, Equatable, Sendable {
        public var index: Int
        public var sha256: String
        public var size: Int
        public init(index: Int, sha256: String, size: Int) { self.index = index; self.sha256 = sha256; self.size = size }
    }
    public var version: String
    public var size: Int64
    public var chunkSize: Int
    public var chunkCount: Int
    public var start: Int
    public var chunks: [ChunkRef]
    public var nextStart: Int?
    public var workspaceId: String
    public var readToken: String
    public var readTokenExpiresAt: Date

    /// Chunk geometry must follow spec 2.6 exactly; anything else is EIO.
    func validated(version expected: String, start expectedStart: Int) throws -> ParaAirCloudManifestPage {
        let malformed = DriveError(EIO, "ParaAir Cloud returned a malformed file manifest")
        // Geometry first, so the count below can neither divide by zero nor overflow.
        guard chunkSize == ParaAirCloudConfiguration.chunkSize, size >= 0 else { throw malformed }
        let c = Int64(chunkSize)
        let count = Int(size / c + (size % c == 0 ? 0 : 1))
        guard version == expected, start == expectedStart, chunkCount == count, ParaAirCloudIDs.isWorkspaceID(workspaceId),
              ParaAirCloudReadToken.isToken(readToken) else { throw malformed }
        for (offset, chunk) in chunks.enumerated() {
            let index = start + offset
            let expectedSize = Int(min(c, size - Int64(index) * c))
            guard chunk.index == index, index < chunkCount, chunk.size == expectedSize, ParaAirCloudErrorMap.isSHA256(chunk.sha256) else { throw malformed }
        }
        if let nextStart {
            guard nextStart == start + chunks.count, nextStart < chunkCount, !chunks.isEmpty else { throw malformed }
        } else {
            guard start + chunks.count == chunkCount else { throw malformed }
        }
        return self
    }
}

public struct ParaAirCloudReadToken: Codable, Equatable, Sendable {
    public var workspaceId: String
    public var readToken: String
    public var expiresAt: Date
    static func isToken(_ value: String) -> Bool {
        value.hasPrefix("prt1.") && value.utf8.count <= 2048 && value.utf8.allSatisfy { (0x21...0x7e).contains($0) }
    }
}

public struct ParaAirCloudReserveRequest: Encodable, Equatable, Sendable {
    public struct Chunk: Codable, Equatable, Sendable {
        public var sha256: String
        public var size: Int
        public init(sha256: String, size: Int) { self.sha256 = sha256; self.size = size }
    }
    public var transactionId: String
    public var path: String
    public var expectedVersion: String?
    public var finalSize: Int64
    public var mode: UInt32
    public var chunkSize: Int
    public var chunks: [Chunk]
    public init(transactionId: String, path: String, expectedVersion: String?, finalSize: Int64, mode: UInt32,
                chunkSize: Int = ParaAirCloudConfiguration.chunkSize, chunks: [Chunk]) {
        self.transactionId = transactionId; self.path = path; self.expectedVersion = expectedVersion
        self.finalSize = finalSize; self.mode = mode; self.chunkSize = chunkSize; self.chunks = chunks
    }
    enum CodingKeys: String, CodingKey { case transactionId, path, expectedVersion, finalSize, mode, chunkSize, chunks }
    /// `expectedVersion: null` is sent explicitly: it means create-only.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(transactionId, forKey: .transactionId); try c.encode(path, forKey: .path)
        try c.encode(expectedVersion, forKey: .expectedVersion); try c.encode(finalSize, forKey: .finalSize)
        try c.encode(mode, forKey: .mode); try c.encode(chunkSize, forKey: .chunkSize); try c.encode(chunks, forKey: .chunks)
    }
}

public enum ParaAirCloudReserveResult: Equatable, Sendable {
    case committed(FileEntry)
    case open(uploadID: String, missing: [String], missingBytes: Int64, expiresAt: Date)
}

public struct ParaAirCloudCommitResult: Equatable, Sendable {
    public var entry: FileEntry
    public var capacity: ParaAirCloudCapacity
}

public enum ParaAirCloudFenceResult: Equatable, Sendable {
    case fenced
    case committed(FileEntry)
}

public struct ParaAirCloudTrashPage: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public var nodeId: Int64
        public var path: String
        public var size: Int64
        public var version: String
        public var deletedAt: Date
        public var expiresAt: Date
    }
    public var items: [Item]
    public var nextCursor: String?
}

enum ParaAirCloudIDs {
    static func isDriveID(_ value: String) -> Bool { UUID(uuidString: value) != nil && value == value.lowercased() }
    static func isWorkspaceID(_ value: String) -> Bool { value.range(of: "^ws_[0-9A-Z]{26}$", options: .regularExpression) != nil }
    static func isUserID(_ value: String) -> Bool { value.range(of: "^usr_[0-9A-Z]{26}$", options: .regularExpression) != nil }
    static func isUploadID(_ value: String) -> Bool { value.range(of: "^upl_[0-9A-Za-z]{1,64}$", options: .regularExpression) != nil }
}

enum ParaAirCloudJSON {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            guard let date = parseDate(value) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid RFC 3339 date"))
            }
            return date
        }
        return decoder
    }
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer(); try container.encode(formatDate(date))
        }
        return encoder
    }
    static func parseDate(_ value: String) -> Date? {
        let precise = ISO8601DateFormatter(); precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = precise.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
    static func formatDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
    /// Decodes a 2xx body; any shape mismatch is EIO, which callers treat as a malformed reply.
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try decoder().decode(T.self, from: data) }
        catch { throw DriveError(EIO, "ParaAir Cloud returned a malformed response", disposition: .ambiguous) }
    }
}
