import Foundation
import Darwin
import FSKit
import StreamDriveCore

/// A timeout reports an uncertain operation without launching another one.
/// FSKit has no cancellation API: a late successful reply must still be saved.
@MainActor
final class NativeMountOperation {
    enum Event {
        case pending
        case finished(Result<URL, Error>)
    }
    private let report: (Event) -> Void
    private var timer: Task<Void, Never>?
    private var reportedPending = false
    private var started = false
    private var activeResource: FSPathURLResource?
    private(set) var isWaiting = true

    init(report: @escaping (Event) -> Void) { self.report = report }

    /// The caller also checks the OS version and live Mounter entitlement.
    /// Keeping this switch allows older signing configurations to opt out.
    static func enabledByConfiguration(_ info: [String: Any]) -> Bool {
        info["ParaAirUseNativeMount"] as? Bool == true
    }

    @available(macOS 27.0, *)
    func start(stateRoot: URL, profileName: String) throws {
        guard !started, isWaiting else { throw DriveError(EBUSY, "This native mount has already started") }
        try DriveProfile.validateName(profileName)
        guard stateRoot.isFileURL else { throw DriveError(EINVAL, "Use the saved local state directory") }
        let profiles = try ProfileStore(root: stateRoot).list()
        guard profiles.count == 1, profiles[0].name == profileName else {
            throw DriveError(EINVAL, "Native mounting requires one saved drive in this state directory")
        }
        started = true
        let resource = try Self.scopedResource(stateRoot: stateRoot)
        guard resource.url.startAccessingSecurityScopedResource() else {
            throw DriveError(EACCES, "Cannot grant the filesystem access to its saved state directory")
        }
        // Keep the host's scoped access alive through the asynchronous handoff.
        activeResource = resource
        timer = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 40_000_000_000) } catch { return }
            self?.markPending()
        }
        FSClient.shared.mountSingleVolume(resource: resource,
            bundleID: "dev.streamdrive.app.filesystem",
            // One profile is already identified by this resource. Forwarding
            // helper CLI switches here lets activation succeed but makes the
            // native final mount fail with EINVAL on macOS 27.2. FSKit applies
            // nodev/nosuid itself, verified in the actual mount table.
            options: []) { [self] url, error in
                Task { @MainActor in self.finish(url: url, error: error, profileName: profiles[0].finderName) }
            }
    }

    /// A bare path carries no sandbox grant. FSKit successfully transports an
    /// explicitly scoped URL; the implicit bookmark grant was usable only in
    /// the host in the live test. Do not canonicalize the resolved URL again:
    /// that loses its scope. No bookmark or access token is persisted.
    static func scopedResource(stateRoot: URL) throws -> FSPathURLResource {
        guard stateRoot.isFileURL else { throw DriveError(EINVAL, "Use the saved local state directory") }
        let canonical = stateRoot.standardizedFileURL.resolvingSymlinksInPath()
        let data = try canonical.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        var stale = false
        let scoped = try URL(resolvingBookmarkData: data,
                             options: [.withSecurityScope, .withoutUI, .withoutMounting],
                             relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale, scoped.standardizedFileURL.resolvingSymlinksInPath() == canonical else {
            throw DriveError(ESTALE, "The saved state directory changed while preparing the mount")
        }
        return FSPathURLResource(url: scoped, writable: true)
    }

    func markPending() {
        guard isWaiting, !reportedPending else { return }
        reportedPending = true
        report(.pending)
    }

    func finish(url: URL?, error: Error?, profileName: String) {
        guard isWaiting else { return }
        isWaiting = false
        activeResource?.url.stopAccessingSecurityScopedResource()
        activeResource = nil
        timer?.cancel(); timer = nil
        if let error { report(.finished(.failure(error))); return }
        guard let url, url.isFileURL,
              url.standardizedFileURL.path == "/Volumes/" + profileName else {
            report(.finished(.failure(DriveError(EIO, "macOS did not return the expected ParaAir volume location"))))
            return
        }
        report(.finished(.success(url)))
    }

    static func verifyMountedResource(_ target: URL, stateRoot: URL) throws {
        var entries: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&entries, MNT_NOWAIT)
        if let entries {
            for index in 0..<Int(count) {
                var entry = entries[index]
                let path = withUnsafePointer(to: &entry.f_mntonname) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
                }
                guard path == target.path else { continue }
                let type = withUnsafePointer(to: &entry.f_fstypename) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
                }
                let source = withUnsafePointer(to: &entry.f_mntfromname) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
                }
                if (type == "streamdrive" || type == "paraair"), let url = URL(string: source), url.isFileURL,
                   url.standardizedFileURL.resolvingSymlinksInPath() == stateRoot.standardizedFileURL.resolvingSymlinksInPath() {
                    return
                }
            }
        }
        throw DriveError(EIO, "macOS did not register this drive at the returned mount location")
    }
}
