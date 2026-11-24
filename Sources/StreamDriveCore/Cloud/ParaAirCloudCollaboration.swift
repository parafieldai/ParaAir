import Foundation
import Darwin

// Shared-editing shapes of the ParaAir Cloud service (cloud README: "Version history", "Change feed", "Folder access",
// "Conflict copies"). Times stay the service's RFC 3339 strings, so the CLI passes them on unchanged. Encoders write
// the same keys the service sends, with explicit nulls where the service has them.

/// Who made a version or a change: a member (`userId`, `email`), or a service credential (`credential`, `name`) and
/// the member who created it (`createdBy`).
public struct ParaAirCloudAuthor: Codable, Equatable, Sendable {
    public struct Person: Codable, Equatable, Sendable {
        public var userId: String?
        public var email: String?
        public init(userId: String?, email: String?) { self.userId = userId; self.email = email }
        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(userId, forKey: .userId); try container.encode(email, forKey: .email)
        }
    }
    public var userId: String?
    public var email: String?
    public var credential: String?
    public var name: String?
    public var createdBy: Person?

    public init(userId: String? = nil, email: String? = nil, credential: String? = nil, name: String? = nil, createdBy: Person? = nil) {
        self.userId = userId; self.email = email; self.credential = credential; self.name = name; self.createdBy = createdBy
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let credential {
            try container.encode(credential, forKey: .credential); try container.encode(name, forKey: .name)
            try container.encode(createdBy, forKey: .createdBy)
        } else {
            try container.encode(userId, forKey: .userId); try container.encode(email, forKey: .email)
        }
    }
    var isValid: Bool {
        [userId, email, credential, name, createdBy?.userId, createdBy?.email].allSatisfy { $0.map { $0.utf8.count <= 320 } ?? true }
    }
}

/// One kept version of a file (`GET /v1/drives/{d}/versions`), newest first.
public struct ParaAirCloudFileVersion: Codable, Equatable, Sendable {
    public var version: String
    public var size: Int64
    public var createdAt: String
    public var author: ParaAirCloudAuthor
    public var current: Bool
    public var expiresAt: String?

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version); try container.encode(size, forKey: .size)
        try container.encode(createdAt, forKey: .createdAt); try container.encode(author, forKey: .author)
        try container.encode(current, forKey: .current); try container.encode(expiresAt, forKey: .expiresAt)
    }
}

/// A page of a file's versions; pass `nextBefore` as `before` for the next one (nil: no more).
public struct ParaAirCloudVersionPage: Codable, Equatable, Sendable {
    public var path: String
    public var versions: [ParaAirCloudFileVersion]
    public var nextBefore: Int64?

    public init(path: String, versions: [ParaAirCloudFileVersion], nextBefore: Int64?) {
        self.path = path; self.versions = versions; self.nextBefore = nextBefore
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path); try container.encode(versions, forKey: .versions)
        try container.encode(nextBefore, forKey: .nextBefore)
    }
    func isValid(path expected: String, limit: Int) -> Bool {
        (try? canonicalPath(path)) == path && versions.count <= limit && nextBefore.map { $0 >= 1 } ?? true
            && versions.allSatisfy { ParaAirCloudIDs.isFileVersion($0.version) && $0.size >= 0 && $0.author.isValid }
            && path.precomposedStringWithCanonicalMapping == expected.precomposedStringWithCanonicalMapping
    }
}

/// One entry of a drive's change feed (`GET /v1/drives/{d}/changes`). `change` is create, write, delete, move,
/// restore, mkdir or purge; `kind` is file or directory; `rescan` asks to list that folder's subtree again.
public struct ParaAirCloudChange: Codable, Equatable, Sendable {
    public var cursor: Int64
    public var change: String
    public var kind: String
    public var path: String
    public var fromPath: String?
    public var rescan: Bool?
    public var version: String?
    public var at: String
    public var author: ParaAirCloudAuthor

    public init(cursor: Int64, change: String, kind: String, path: String, fromPath: String? = nil, rescan: Bool? = nil,
                version: String? = nil, at: String, author: ParaAirCloudAuthor) {
        self.cursor = cursor; self.change = change; self.kind = kind; self.path = path; self.fromPath = fromPath
        self.rescan = rescan; self.version = version; self.at = at; self.author = author
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cursor, forKey: .cursor); try container.encode(change, forKey: .change)
        try container.encode(kind, forKey: .kind); try container.encode(path, forKey: .path)
        try container.encodeIfPresent(fromPath, forKey: .fromPath)
        if rescan == true { try container.encode(true, forKey: .rescan) }
        try container.encode(version, forKey: .version); try container.encode(at, forKey: .at)
        try container.encode(author, forKey: .author)
    }
    var isValid: Bool {
        cursor >= 1 && (try? canonicalPath(path)) == path && fromPath.map { (try? canonicalPath($0)) == $0 } ?? true
            && ["file", "directory"].contains(kind) && change.utf8.count <= 32 && version.map(ParaAirCloudIDs.isFileVersion) ?? true
            && author.isValid
    }
}

/// A page of the change feed: the changes after `since`, the cursor to pass next, whether more are waiting, and
/// `reset` when changes after `since` were pruned (rescan, then follow from `cursor`).
public struct ParaAirCloudChangePage: Codable, Equatable, Sendable {
    public var changes: [ParaAirCloudChange]
    public var cursor: Int64
    public var more: Bool
    public var reset: Bool
    public init(changes: [ParaAirCloudChange], cursor: Int64, more: Bool, reset: Bool) {
        self.changes = changes; self.cursor = cursor; self.more = more; self.reset = reset
    }
}

/// Levels of a folder rule (cloud README, "Folder access").
public enum ParaAirCloudAccessLevel: String, Codable, CaseIterable, Sendable { case none, read, create, write }

/// Whom a folder rule names: one member by email, everyone of a role (`members` or `viewers`), or a service credential.
public enum ParaAirCloudAccessPrincipal: Equatable, Sendable {
    case email(String)
    case role(String)
    case credential(String)

    var field: (name: String, value: String) {
        switch self {
        case .email(let value): return ("email", value)
        case .role(let value): return ("role", value)
        case .credential(let value): return ("credential", value)
        }
    }
}

/// One folder rule of a drive (`GET /v1/drives/{d}/access`).
public struct ParaAirCloudAccessRule: Codable, Equatable, Sendable {
    public var userId: String?
    public var email: String?
    public var role: String?
    public var credential: String?
    public var name: String?
    public var path: String
    public var access: String
    public var updatedAt: String

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let role { try container.encode(role, forKey: .role) }
        else if let credential { try container.encode(credential, forKey: .credential); try container.encode(name, forKey: .name) }
        else { try container.encode(userId, forKey: .userId); try container.encode(email, forKey: .email) }
        try container.encode(path, forKey: .path); try container.encode(access, forKey: .access)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
    var isValid: Bool {
        (try? canonicalPath(path)) == path && ParaAirCloudAccessLevel(rawValue: access) != nil
            && [userId, email, role, credential, name].allSatisfy { $0.map { $0.utf8.count <= 320 } ?? true }
    }
}

/// A service credential of a workspace (`GET /v1/workspaces/{ws}/credentials`): a backend's login, made by an owner or
/// admin, that sees only the folders folder rules give it (`ParaAirCloudAccessPrincipal.credential`). Never holds the
/// token.
public struct ParaAirCloudServiceCredential: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var createdAt: String
    /// Email of the owner or admin who made it; null once that account is gone.
    public var createdBy: String?
    public var lastUsedAt: String?
    public var revokedAt: String?

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id); try container.encode(name, forKey: .name)
        try container.encode(createdAt, forKey: .createdAt); try container.encode(createdBy, forKey: .createdBy)
        try container.encode(lastUsedAt, forKey: .lastUsedAt); try container.encode(revokedAt, forKey: .revokedAt)
    }
    var isValid: Bool {
        ParaAirCloudIDs.isCredentialID(id) && !name.isEmpty && name.utf16.count <= 100
            && ParaAirCloudJSON.parseDate(createdAt) != nil
            && [lastUsedAt, revokedAt].allSatisfy { $0.map { ParaAirCloudJSON.parseDate($0) != nil } ?? true }
            && createdBy.map { $0.utf8.count <= 320 } ?? true
    }
}

/// A credential just made and its token (`pcs_cred_….<secret>`), which the service shows in that reply only and keeps
/// as a hash. Printing, logging or dumping this value leaves the token out; read `token` to hand it over.
public struct ParaAirCloudCreatedCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let credential: ParaAirCloudServiceCredential
    public let token: String

    public var description: String { "ParaAirCloudCreatedCredential(\(credential.id), token: <redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["credential": credential, "token": "<redacted>"]) }
}

/// Where a conflict copy came from: the file it was saved beside, the version this Mac's change was based on, and the
/// version in storage it lost to. Kept by the service per file (`PUT`/`GET /v1/drives/{d}/conflicts`), so every Mac can
/// answer it; the service adds `createdAt` and `author`.
public struct ParaAirCloudConflictRecord: Codable, Equatable, Sendable {
    public var path: String
    public var original: String
    public var baseVersion: String?
    public var theirsVersion: String?
    public var createdAt: String?
    public var author: ParaAirCloudAuthor?

    public init(path: String, original: String, baseVersion: String?, theirsVersion: String?, createdAt: String? = nil,
                author: ParaAirCloudAuthor? = nil) {
        self.path = path; self.original = original; self.baseVersion = baseVersion; self.theirsVersion = theirsVersion
        self.createdAt = createdAt; self.author = author
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path); try container.encode(original, forKey: .original)
        try container.encode(baseVersion, forKey: .baseVersion); try container.encode(theirsVersion, forKey: .theirsVersion)
        try container.encodeIfPresent(createdAt, forKey: .createdAt); try container.encodeIfPresent(author, forKey: .author)
    }
    var isValid: Bool {
        (try? canonicalPath(path)) == path && (try? canonicalPath(original)) == original
            && [baseVersion, theirsVersion].allSatisfy { $0.map(ParaAirCloudIDs.isFileVersion) ?? true }
            && author?.isValid ?? true
    }
}

extension ParaAirCloudIDs {
    /// A file version id, `pv:` and a positive integer below 2^53.
    static func isFileVersion(_ value: String) -> Bool { value.range(of: "^pv:[1-9][0-9]{0,15}$", options: .regularExpression) != nil }
}

/// A workspace role (cloud README, "Members"). Only owners make owners; owners and admins manage members.
public enum ParaAirCloudMemberRole: String, Codable, CaseIterable, Sendable { case owner, admin, member, viewer }

/// One member of a workspace (`GET /v1/workspaces/{ws}/members`). `status` is "active" (signed in since being added),
/// "invited" (not yet) or "disabled" (by the operator).
public struct ParaAirCloudWorkspaceMember: Codable, Equatable, Sendable {
    public var userId: String
    public var email: String
    public var role: String
    public var addedAt: String
    public var status: String

    var isValid: Bool {
        ParaAirCloudIDs.isUserID(userId) && email.contains("@") && email.utf8.count <= 320 && ParaAirCloudMemberRole(rawValue: role) != nil
            && ParaAirCloudJSON.parseDate(addedAt) != nil && !status.isEmpty && status.utf8.count <= 32
    }
}

/// The answer to adding a member (`POST /v1/workspaces/{ws}/members`). `added` is false when the address already was a
/// member with that role; `notified` is true only when the service emailed the person an invitation.
public struct ParaAirCloudMemberAdded: Codable, Equatable, Sendable {
    public var member: ParaAirCloudWorkspaceMember
    public var added: Bool
    public var notified: Bool
}

/// A workspace's members and the seats they use (owners and admins only).
public struct ParaAirCloudMemberList: Codable, Equatable, Sendable {
    public struct Workspace: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var kind: String
        public var plan: String
        public var seats: Int
        public var seatsUsed: Int
    }
    public var workspace: Workspace
    public var members: [ParaAirCloudWorkspaceMember]
}
