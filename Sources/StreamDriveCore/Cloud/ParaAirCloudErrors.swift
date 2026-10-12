import Foundation
import Darwin

/// Exactly the error table of `contract/paraair-cloud-v1/errors.json` (spec 2.3).
public enum ParaAirCloudErrorCode: String, CaseIterable, Sendable {
    case invalidRequest = "invalid_request", invalidPath = "invalid_path", escapingPath = "escaping_path"
    case nameTooLong = "name_too_long", invalidName = "invalid_name", invalidVersion = "invalid_version"
    case invalidManifest = "invalid_manifest", invalidRange = "invalid_range", invalidMove = "invalid_move"
    case idempotencyMismatch = "idempotency_mismatch", lengthRequired = "length_required", sizeMismatch = "size_mismatch"
    case chunkHashMismatch = "chunk_hash_mismatch", chunkNotInUpload = "chunk_not_in_upload"
    case unsupportedMediaType = "unsupported_media_type", bodyTooLarge = "body_too_large", fileTooLarge = "file_too_large"
    case unauthorized, forbidden, insufficientScope = "insufficient_scope", suspended, readOnly = "read_only"
    case driveLimit = "drive_limit", notFound = "not_found", parentNotFound = "parent_not_found"
    case workspaceNotFound = "workspace_not_found", driveNotFound = "drive_not_found", uploadNotFound = "upload_not_found"
    case chunkNotFound = "chunk_not_found", versionNotFound = "version_not_found", versionConflict = "version_conflict"
    case alreadyExists = "already_exists", notDirectory = "not_directory", isDirectory = "is_directory"
    case notEmpty = "not_empty", busy, moveTooLarge = "move_too_large", transactionFenced = "transaction_fenced"
    case transactionCommitted = "transaction_committed", uploadExpired = "upload_expired", chunksMissing = "chunks_missing"
    case quotaExceeded = "quota_exceeded", nodeLimit = "node_limit", tooManyUploads = "too_many_uploads"
    case rateLimited = "rate_limited", chunkBusy = "chunk_busy", clientTooOld = "client_too_old"
    case `internal`, storageUnavailable = "storage_unavailable", unavailable

    public var httpStatus: Int {
        switch self {
        case .invalidRequest, .invalidPath, .escapingPath, .nameTooLong, .invalidName, .invalidVersion, .invalidManifest,
             .invalidRange, .invalidMove, .sizeMismatch, .chunkNotInUpload: return 400
        case .unauthorized: return 401
        case .forbidden, .insufficientScope, .suspended, .readOnly, .driveLimit: return 403
        case .notFound, .parentNotFound, .workspaceNotFound, .driveNotFound, .uploadNotFound, .chunkNotFound: return 404
        case .idempotencyMismatch, .versionNotFound, .versionConflict, .alreadyExists, .notDirectory, .isDirectory,
             .notEmpty, .busy, .transactionFenced, .transactionCommitted, .chunksMissing: return 409
        case .uploadExpired: return 410
        case .lengthRequired: return 411
        case .bodyTooLarge, .fileTooLarge, .moveTooLarge: return 413
        case .unsupportedMediaType: return 415
        case .chunkHashMismatch: return 422
        case .clientTooOld: return 426
        case .tooManyUploads, .rateLimited: return 429
        case .internal: return 500
        case .storageUnavailable: return 502
        case .chunkBusy, .unavailable: return 503
        case .quotaExceeded, .nodeLimit: return 507
        }
    }

    public var errno: Int32 {
        switch self {
        case .invalidRequest, .invalidPath, .invalidName, .invalidVersion, .invalidManifest, .invalidRange, .invalidMove,
             .idempotencyMismatch: return EINVAL
        case .escapingPath, .unauthorized, .forbidden, .insufficientScope, .suspended: return EACCES
        case .nameTooLong: return ENAMETOOLONG
        case .lengthRequired, .sizeMismatch, .chunkNotInUpload, .unsupportedMediaType, .uploadNotFound, .uploadExpired,
             .chunksMissing: return EPROTO
        case .chunkHashMismatch, .internal, .storageUnavailable, .unavailable: return EIO
        case .bodyTooLarge, .fileTooLarge: return EFBIG
        case .readOnly: return EROFS
        case .driveLimit, .quotaExceeded, .nodeLimit: return EDQUOT
        case .notFound, .parentNotFound, .workspaceNotFound: return ENOENT
        case .driveNotFound: return ENXIO
        case .chunkNotFound, .versionNotFound, .versionConflict, .transactionCommitted: return ESTALE
        case .alreadyExists: return EEXIST
        case .notDirectory: return ENOTDIR
        case .isDirectory: return EISDIR
        case .notEmpty: return ENOTEMPTY
        case .busy: return EBUSY
        case .moveTooLarge: return EXDEV
        case .transactionFenced: return ECANCELED
        case .tooManyUploads, .rateLimited, .chunkBusy: return EAGAIN
        case .clientTooOld: return ENOTSUP
        }
    }

    /// The server records a transaction fence before returning this code from reserve or commit.
    public var fencesTransaction: Bool {
        switch self {
        case .invalidRequest, .invalidPath, .escapingPath, .nameTooLong, .invalidVersion, .invalidManifest, .fileTooLarge,
             .readOnly, .parentNotFound, .versionConflict, .alreadyExists, .notDirectory, .isDirectory,
             .transactionFenced, .quotaExceeded, .nodeLimit: return true
        default: return false
        }
    }

    /// Fixed text; the service's own message is never shown because it is not localized.
    var message: String {
        switch self {
        case .invalidRequest: return "ParaAir Cloud rejected the request"
        case .invalidPath: return "ParaAir Cloud rejected the file path"
        case .escapingPath: return "Reserved or escaping drive path"
        case .nameTooLong: return "A file or folder name is too long for ParaAir Cloud"
        case .invalidName: return "ParaAir Cloud rejected the drive name"
        case .invalidVersion: return "ParaAir Cloud rejected the file version"
        case .invalidManifest: return "ParaAir Cloud rejected the upload manifest"
        case .invalidRange: return "ParaAir Cloud rejected the byte range"
        case .invalidMove: return "This rename is not possible"
        case .idempotencyMismatch: return "ParaAir Cloud saw a repeated request with different contents"
        case .lengthRequired, .unsupportedMediaType: return "ParaAir Cloud rejected the request format"
        case .sizeMismatch, .chunkHashMismatch: return "Uploaded data did not match its checksum"
        case .chunkNotInUpload: return "ParaAir Cloud rejected an upload chunk"
        case .bodyTooLarge: return "The request is too large for ParaAir Cloud"
        case .fileTooLarge: return "The file is larger than ParaAir Cloud allows"
        case .unauthorized: return "Sign in to ParaAir Cloud again"
        case .forbidden: return "Your ParaAir Cloud role does not allow this"
        case .insufficientScope: return "ParaAir needs drive access. Sign in to ParaAir Cloud again"
        case .suspended: return "This ParaAir Cloud workspace is suspended"
        case .readOnly: return "This ParaAir Cloud workspace is read-only"
        case .driveLimit: return "This ParaAir Cloud plan has no room for another drive"
        case .notFound: return "The file or folder does not exist"
        case .parentNotFound: return "The enclosing folder does not exist"
        case .workspaceNotFound: return "The ParaAir Cloud workspace does not exist"
        case .driveNotFound: return "The ParaAir Cloud drive is unavailable to this account"
        case .uploadNotFound, .uploadExpired: return "The upload session ended before it finished"
        case .chunkNotFound, .versionNotFound: return "The file changed on the server"
        case .versionConflict, .transactionCommitted: return "The file changed on the server"
        case .alreadyExists: return "An item with that name already exists"
        case .notDirectory: return "Not a folder"
        case .isDirectory: return "Is a folder"
        case .notEmpty: return "The folder is not empty"
        case .busy: return "The drive root cannot be changed"
        case .moveTooLarge: return "The folder is too large to rename in one step"
        case .transactionFenced: return "The upload was cancelled and will be retried"
        case .chunksMissing: return "ParaAir Cloud is missing uploaded data"
        case .quotaExceeded: return "Your ParaAir Cloud storage is full"
        case .nodeLimit: return "This ParaAir Cloud drive has too many files"
        case .tooManyUploads: return "Too many uploads are in progress"
        case .rateLimited, .chunkBusy: return "ParaAir Cloud is busy. Try again shortly"
        case .clientTooOld: return "Update ParaAir to keep using ParaAir Cloud"
        case .internal, .storageUnavailable, .unavailable: return "ParaAir Cloud is temporarily unavailable"
        }
    }
}

/// A parsed error envelope, kept for callers that react to a specific code.
struct ParaAirCloudFailure: Sendable {
    let status: Int
    let code: ParaAirCloudErrorCode?
    let missing: [String]
    let retryAfterSeconds: Int?
}

enum ParaAirCloudErrorMap {
    enum Phase { case other, reserveOrCommit }

    static func parse(status: Int, body: Data, headers: [String: String] = [:]) -> ParaAirCloudFailure {
        var code: ParaAirCloudErrorCode?, missing: [String] = [], retry: Int?
        if body.count <= 1_048_576, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let error = object["error"] as? [String: Any] {
            if let raw = error["code"] as? String, let known = ParaAirCloudErrorCode(rawValue: raw), known.httpStatus == status { code = known }
            missing = (error["missing"] as? [String] ?? []).filter(isSHA256)
            if let value = error["retryAfterSeconds"] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() { retry = value.intValue }
        }
        if retry == nil, let header = headers.first(where: { $0.key.lowercased() == "retry-after" })?.value, let seconds = Int(header) { retry = seconds }
        return ParaAirCloudFailure(status: status, code: code, missing: missing, retryAfterSeconds: retry.map { max(0, $0) })
    }

    /// Parses the envelope. An unknown code (or one sent with another status) maps
    /// by class: 4xx → EPROTO, 5xx → EIO. Messages are fixed per code plus the request id.
    /// Disposition: reserveOrCommit && fences → .transactionAbsent; other 4xx →
    /// .attemptNotDispatched; 5xx → .ambiguous.
    static func error(status: Int, body: Data, requestID: String?, phase: Phase) -> DriveError {
        error(parse(status: status, body: body), requestID: requestID, phase: phase)
    }

    static func error(_ failure: ParaAirCloudFailure, requestID: String?, phase: Phase) -> DriveError {
        let suffix = requestID.flatMap(validRequestID).map { " (request \($0))" } ?? ""
        let disposition: CommitDisposition
        if phase == .reserveOrCommit, failure.code?.fencesTransaction == true { disposition = .transactionAbsent }
        else if (400...499).contains(failure.status) { disposition = .attemptNotDispatched }
        else { disposition = .ambiguous }
        if let code = failure.code { return DriveError(code.errno, code.message + suffix, disposition: disposition) }
        if (400...499).contains(failure.status) {
            return DriveError(EPROTO, "ParaAir Cloud returned an unexpected response (HTTP \(failure.status))" + suffix, disposition: disposition)
        }
        return DriveError(EIO, "ParaAir Cloud is temporarily unavailable (HTTP \(failure.status))" + suffix, disposition: disposition)
    }

    /// Spec 2.4: connection-level failures never reached the service.
    static func transport(_ error: Error) -> DriveError {
        if let drive = error as? DriveError { return drive }
        guard let url = error as? URLError else { return DriveError(EIO, "ParaAir Cloud returned an invalid response", disposition: .ambiguous) }
        switch url.code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            return DriveError(ENETDOWN, "This Mac is offline", disposition: .attemptNotDispatched)
        case .cannotFindHost, .dnsLookupFailed:
            return DriveError(EHOSTUNREACH, "ParaAir Cloud could not be found", disposition: .attemptNotDispatched)
        case .cannotConnectToHost:
            return DriveError(ECONNREFUSED, "ParaAir Cloud could not be reached", disposition: .attemptNotDispatched)
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired:
            return DriveError(EIO, "A secure connection to ParaAir Cloud could not be made", disposition: .attemptNotDispatched)
        case .appTransportSecurityRequiresSecureConnection:
            return DriveError(EACCES, "This ParaAir build can’t reach that service address", disposition: .attemptNotDispatched)
        case .networkConnectionLost:
            return DriveError(ECONNRESET, "The connection to ParaAir Cloud was lost", disposition: .ambiguous)
        case .timedOut:
            return DriveError(ETIMEDOUT, "ParaAir Cloud did not respond in time", disposition: .ambiguous)
        case .cancelled:
            return DriveError(EBADF, "The ParaAir Cloud connection is closed", disposition: .ambiguous)
        default:
            return DriveError(EIO, "ParaAir Cloud returned an invalid response", disposition: .ambiguous)
        }
    }

    /// Request ids are logged and shown; accept only the documented shape.
    static func validRequestID(_ value: String) -> String? {
        value.range(of: "^req_[0-9A-Za-z]{1,40}$", options: .regularExpression) != nil ? value : nil
    }

    static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
