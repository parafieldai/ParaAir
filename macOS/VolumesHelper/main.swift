import Foundation
import Security

// ParaAirVolumes: ParaAir's root helper on macOS 26, registered by the app with SMAppService and started by launchd on
// demand. It makes the drive's folder directly in /Volumes for the user who asks and nothing else; the user's own
// process then mounts the drive there. Built from this file and Sources/StreamDriveCore/VolumesFolder.swift only.

/// The signing identity this helper was signed with: its identifier (also its launchd label and Mach service name,
/// "<app>.volumes") and the requirement for clients: that app, signed by the same team. Not its command-line tool,
/// which any process of the user can run: the app asks only for a drive it is about to mount, and removes the folder
/// again if that mount fails, so nothing else can make empty folders in /Volumes that a real disk's name would then
/// avoid. (On macOS 26 the CLI asks the app to mount a drive in /Volumes; it never calls this helper.)
func signingIdentity() -> (service: String, clientRequirement: String)? {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let values = info as? [String: Any],
          let team = values[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty,
          let identifier = values[kSecCodeInfoIdentifier as String] as? String, identifier.hasSuffix(".volumes")
    else { return nil }
    let app = String(identifier.dropLast(".volumes".count))
    let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
    guard team.unicodeScalars.allSatisfy(safe.contains), app.unicodeScalars.allSatisfy(safe.contains) else { return nil }
    return (identifier, "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(app)\"")
}

final class Service: NSObject, ParaAirVolumesService {
    private let uid: uid_t, gid: gid_t
    init(uid: uid_t, gid: gid_t) { self.uid = uid; self.gid = gid }

    func prepareMountPoint(_ name: String, reply: @escaping (String?, Int32, String?) -> Void) {
        do { reply(try VolumesFolder.prepare(name: name, uid: uid, gid: gid), 0, nil) }
        catch let error as VolumesFolderError { reply(nil, error.code, error.message) }
        catch { reply(nil, EIO, String(describing: error)) }
    }

    func removeMountPoint(_ name: String, reply: @escaping (Int32, String?) -> Void) {
        do { try VolumesFolder.remove(name: name, uid: uid); reply(0, nil) }
        catch let error as VolumesFolderError { reply(error.code, error.message) }
        catch { reply(EIO, String(describing: error)) }
    }
}

final class Listener: NSObject, NSXPCListenerDelegate {
    private let requirement: String
    private let lock = NSLock()
    private var open = 0
    private var lastActivity = Date()

    init(requirement: String) { self.requirement = requirement }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Messages from a client that doesn't meet the requirement are refused and the connection invalidated.
        connection.setCodeSigningRequirement(requirement)
        let uid = connection.effectiveUserIdentifier
        guard uid != 0, let account = getpwuid(uid) else { return false }
        connection.exportedInterface = NSXPCInterface(with: ParaAirVolumesService.self)
        connection.exportedObject = Service(uid: uid, gid: account.pointee.pw_gid)
        let closed: () -> Void = { [weak self] in self?.update { $0 -= 1 } }
        connection.invalidationHandler = closed
        update { $0 += 1 }
        connection.resume()
        return true
    }

    private func update(_ change: (inout Int) -> Void) {
        lock.lock(); change(&open); lastActivity = Date(); lock.unlock()
    }

    /// Nothing to keep running for: launchd starts the helper again on the next request.
    var idle: Bool {
        lock.lock(); defer { lock.unlock() }
        return open <= 0 && Date().timeIntervalSince(lastActivity) > 30
    }
}

guard getuid() == 0, let identity = signingIdentity() else {
    FileHandle.standardError.write(Data("ParaAirVolumes runs only as ParaAir's signed launchd helper.\n".utf8))
    exit(78) // EX_CONFIG
}
let delegate = Listener(requirement: identity.clientRequirement)
let listener = NSXPCListener(machServiceName: identity.service)
listener.delegate = delegate
listener.resume()
Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in if delegate.idle { exit(0) } }
RunLoop.main.run()
