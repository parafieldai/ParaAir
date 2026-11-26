import Foundation
import Security
import ServiceManagement
import StreamDriveCore

/// ParaAir's /Volumes helper on macOS 26 (macOS/VolumesHelper). Without FSKit's own mount (macOS 27) a user's process
/// can't make a folder in /Volumes, where Finder lists drives. The helper, a small root launchd job the app registers
/// with SMAppService, makes the drive's folder there and gives it to the user; ParaAir then mounts the drive on it as
/// the user. The user approves the helper once in System Settings › General › Login Items & Extensions.
enum VolumesHelper {
    /// `notRegistered`: not asked for yet (the first mount registers it). `needsApproval`: waiting for the switch in
    /// Login Items & Extensions. `unavailable`: this build can't register it (not signed for distribution).
    enum State: Equatable { case ready, needsApproval, notRegistered, unavailable }

    /// The helper's launchd label, Mach service and signing identifier: "<app id>.volumes".
    static var serviceName: String { (Bundle.main.bundleIdentifier ?? "dev.streamdrive.app") + ".volumes" }
    private static var service: SMAppService { .daemon(plistName: serviceName + ".plist") }

    /// The helper's state, without registering it.
    static var state: State { state(service.status) }

    /// Registers the helper the first time a drive needs it; macOS then lists ParaAir for approval and says so.
    static func register() -> State {
        let service = service
        if service.status == .notRegistered || service.status == .notFound {
            do { try service.register() }
            catch { AppLog.mount.notice("volumes helper register: \(error.localizedDescription, privacy: .public)") }
        }
        var result = state(service.status)
        if result == .notRegistered { result = .unavailable }
        AppLog.mount.notice("volumes helper state=\(String(describing: result), privacy: .public)")
        return result
    }

    static func openApproval() { SMAppService.openSystemSettingsLoginItems() }

    private static func state(_ status: SMAppService.Status) -> State {
        switch status {
        case .enabled: return .ready
        case .requiresApproval: return .needsApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }

    /// Asks the helper to remove a /Volumes folder it made for a mount that then failed. Best effort: the helper
    /// refuses anything but this user's empty folder with nothing mounted on it, and macOS removes the folder itself
    /// when a drive unmounts.
    static func removeMountPoint(_ path: String) {
        guard path.hasPrefix(VolumesFolder.volumes + "/"), let team = ownTeamIdentifier() else { return }
        let name = String(path.dropFirst(VolumesFolder.volumes.count + 1))
        let connection = NSXPCConnection(machServiceName: serviceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: ParaAirVolumesService.self)
        connection.setCodeSigningRequirement("anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(serviceName)\"")
        connection.resume()
        defer { connection.invalidate() }
        let reply = try? call(connection) { proxy, done in proxy.removeMountPoint(name) { done(nil, $0, $1) } }
        AppLog.mount.notice("volumes helper removed unused folder code=\(reply?.code ?? -1)")
    }

    /// Asks the helper for /Volumes/<Finder name>, or "<name> 2" … when another volume already has the name.
    static func mountPoint(finderName: String) throws -> String {
        guard let team = ownTeamIdentifier() else {
            throw DriveError(ENOTSUP, "This build of ParaAir isn’t signed by a developer team, so it can’t use its /Volumes helper.")
        }
        let connection = NSXPCConnection(machServiceName: serviceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: ParaAirVolumesService.self)
        // Only ParaAir's own helper, from the same team, may answer.
        connection.setCodeSigningRequirement("anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(serviceName)\"")
        connection.resume()
        defer { connection.invalidate() }
        for name in VolumesFolder.candidates(for: finderName) {
            let reply = try call(connection) { proxy, done in proxy.prepareMountPoint(name) { done($0, $1, $2) } }
            if let path = reply.path { return path }
            guard reply.code == EEXIST else { throw DriveError(reply.code, reply.message ?? "ParaAir couldn’t prepare /Volumes/\(name).") }
        }
        throw DriveError(EEXIST, "Other volumes already use the name \(finderName) in /Volumes. Eject one of them, then try again.")
    }

    private static func call(_ connection: NSXPCConnection,
                             _ body: (ParaAirVolumesService, @escaping (String?, Int32, String?) -> Void) -> Void) throws
        -> (path: String?, code: Int32, message: String?) {
        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var result: (String?, Int32, String?)?
        var failure: Error?
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            lock.lock(); failure = error; lock.unlock(); done.signal()
        }
        guard let helper = proxy as? ParaAirVolumesService else {
            throw DriveError(EIO, "ParaAir’s /Volumes helper didn’t answer.")
        }
        body(helper) { path, code, message in lock.lock(); result = (path, code, message); lock.unlock(); done.signal() }
        guard done.wait(timeout: .now() + 15) == .success else {
            throw DriveError(ETIMEDOUT, "ParaAir’s /Volumes helper didn’t answer in time. Try again.")
        }
        lock.lock(); defer { lock.unlock() }
        if let result { return (result.0, result.1, result.2) }
        AppLog.mount.error("volumes helper connection failed: \(String(describing: failure), privacy: .public)")
        throw DriveError(EIO, "ParaAir couldn’t reach its /Volumes helper. Check that ParaAir is allowed in Login Items & Extensions, then try again.")
    }

    /// The team that signed this app; nil for an ad hoc development build.
    private static func ownTeamIdentifier() -> String? {
        var code: SecCode?, staticCode: SecStaticCode?, info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty
        else { return nil }
        return team
    }
}
