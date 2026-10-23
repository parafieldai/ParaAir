import Foundation
import Darwin

/// When a file's failed uploads stop looking like a passing blip: after `minFailures`
/// attempts, or once it has kept failing for `minDurationNanoseconds`. Background retries
/// back off from 2 s, doubling, so four failures take about half a minute; a file that
/// waits offline (no attempts while the connection is down) reaches the duration instead.
public struct UploadFailurePolicy: Sendable, Equatable {
    public var minFailures: Int
    public var minDurationNanoseconds: Int64
    public init(minFailures: Int, minDurationNanoseconds: Int64) {
        self.minFailures = minFailures; self.minDurationNanoseconds = minDurationNanoseconds
    }
    public static let standard = UploadFailurePolicy(minFailures: 4, minDurationNanoseconds: 900_000_000_000)
}

public extension UploadRecord {
    /// A change that never uploads by itself and waits for a decision: the file changed in
    /// storage (a conflict), or storage refuses changes from this Mac (EROFS: another Mac
    /// owns the drive, or a read-only ParaAir Cloud plan).
    var needsDecision: Bool { state == "conflict" || lastErrno == EROFS }

    /// Uploads of this file keep failing. ParaAir keeps retrying; the change stays on this Mac.
    func isFailing(now: Int64, policy: UploadFailurePolicy = .standard) -> Bool {
        guard !needsDecision, lastErrno != nil else { return false }
        if failures >= policy.minFailures { return true }
        guard let since = failingSinceNanoseconds, now >= since else { return false }
        return now - since >= policy.minDurationNanoseconds
    }
}

/// Files whose uploads keep failing, for one notice: how many, the most common cause and
/// the oldest change among them.
public struct UploadFailureSummary: Codable, Sendable, Equatable {
    public var count: Int
    public var errno: Int32
    /// Wall-clock nanoseconds of the oldest change waiting in these files.
    public var oldestChangeNanoseconds: Int64
    public init(count: Int, errno: Int32, oldestChangeNanoseconds: Int64) {
        self.count = count; self.errno = errno; self.oldestChangeNanoseconds = oldestChangeNanoseconds
    }

    /// Nil when no file is failing. `excluding` leaves out files another notice covers.
    public static func make(_ uploads: [UploadRecord], now: Int64, policy: UploadFailurePolicy = .standard,
                            excluding: (UploadRecord) -> Bool = { _ in false }) -> UploadFailureSummary? {
        let failing = uploads.filter { $0.isFailing(now: now, policy: policy) && !excluding($0) }
        guard !failing.isEmpty else { return nil }
        var counts: [Int32: Int] = [:]
        for upload in failing { counts[upload.lastErrno!, default: 0] += 1 }
        // Most files first; a tie goes to the lower errno, so the answer doesn't change between polls.
        let code = counts.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }!.key
        let oldest = failing.map { $0.pendingSinceNanoseconds ?? $0.modifiedNanoseconds ?? now }.min() ?? now
        return UploadFailureSummary(count: failing.count, errno: code, oldestChangeNanoseconds: oldest)
    }
}

/// Why uploads fail, in plain words, from the errno storage reported. Lowercase, so it
/// follows "Couldn’t upload 3 files:".
public enum UploadFailureReason {
    public static func text(_ code: Int32, cloud: Bool) -> String {
        switch code {
        case ENETDOWN, ENETUNREACH, EHOSTUNREACH, ETIMEDOUT, ECONNRESET, ECONNREFUSED, ENOTCONN:
            return cloud ? "ParaAir Cloud can’t be reached" : "your storage can’t be reached"
        case EACCES, EPERM:
            return cloud ? "ParaAir Cloud needs you to sign in again" : "your storage refused access; its key may have been revoked"
        case ENOENT, ENXIO:
            return cloud ? "this drive no longer exists in ParaAir Cloud" : "the bucket, or the drive’s folder in it, is missing"
        case EDQUOT, ENOSPC: return cloud ? "your ParaAir Cloud storage is full" : "your storage is full"
        case EFBIG: return "the file is larger than your storage accepts"
        case ENAMETOOLONG: return "the file’s name is too long for your storage"
        case EAGAIN, EBUSY: return "your storage is busy"
        case ENOTSUP: return cloud ? "ParaAir Cloud needs a newer version of ParaAir" : "your storage doesn’t support this upload"
        case EIO: return cloud ? "ParaAir Cloud couldn’t save the file" : "your storage didn’t accept the upload"
        default: return "the upload failed (error \(code))"
        }
    }
}
