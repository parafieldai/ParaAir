import Foundation
import FSKit
import StreamDriveCore
import CryptoKit
import OSLog

/// Probe has no mount options, so a mounted resource must identify one profile.
/// Both probe and load can run in independent extension processes.
struct FinderMountResource {
    let profile: DriveProfile
    let identifier: UUID

    init(stateRoot: URL, requestedProfile: String? = nil) throws {
        let root = stateRoot.standardizedFileURL.resolvingSymlinksInPath()
        let profiles = try ProfileStore(root: root).list()
        guard profiles.count == 1, let profile = profiles.first else {
            throw DriveError(EINVAL, "Finder mounting requires exactly one profile in its state directory. Use a separate --state-dir for each Finder volume.")
        }
        guard requestedProfile == nil || requestedProfile == profile.name else {
            throw DriveError(EINVAL, "The requested profile does not match this Finder state directory. Select its single profile or use that profile's separate --state-dir.")
        }
        self.profile = profile
        // The name and canonical local resource path are nonsecret. Never hash or
        // log a credential-bearing metadata URI. Use a version-8 derived UUID.
        let input = "dev.streamdrive.fskit.v1\0" + root.path + "\0" + profile.name
        var bytes = Array(SHA256.hash(data: Data(input.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        identifier = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                                 bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

func filesystemError(_ error: Error) -> Error {
    if let error = error as? DriveError {
        return NSError(domain: NSPOSIXErrorDomain, code: Int(error.code),
                       userInfo: [NSLocalizedDescriptionKey: error.message])
    }
    return error
}

func selectedProfile(_ options: FSTaskOptions) -> String? {
    selectedProfile(options.taskOptions)
}

func selectedProfile(_ args: [String]) -> String? {
    for (index, value) in args.enumerated() {
        if value == "-p", index + 1 < args.count { return args[index + 1] }
        if value.hasPrefix("-p=") { return String(value.dropFirst(3)) }
    }
    return nil
}

final class StreamDriveFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {
    private var scopedURL: URL?
    private var scopeStarted = false
    private var volume: StreamDriveVolume?

    func probeResource(resource: FSResource, replyHandler: @escaping (FSProbeResult?, Error?) -> Void) {
        guard let resource = resource as? FSPathURLResource, resource.url.isFileURL else {
            replyHandler(.notRecognized, nil)
            return
        }
        // Recognize only a configured state directory. Probing never opens a
        // backend or fetches remote file contents.
        let scoped = resource.url.startAccessingSecurityScopedResource()
        defer { if scoped { resource.url.stopAccessingSecurityScopedResource() } }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resource.url.appendingPathComponent("profiles").path,
                                             isDirectory: &directory), directory.boolValue else {
            replyHandler(.notRecognized, nil); return
        }
        do {
            let mount = try FinderMountResource(stateRoot: resource.url)
            replyHandler(.usable(name: mount.profile.finderName, containerID: FSContainerIdentifier(uuid: mount.identifier)), nil)
        } catch { replyHandler(nil, filesystemError(error)) }
    }

    func loadResource(resource: FSResource, options: FSTaskOptions,
                      replyHandler: @escaping (FSVolume?, Error?) -> Void) {
        guard let resource = resource as? FSPathURLResource, resource.url.isFileURL else {
            replyHandler(nil, POSIXError(.EINVAL)); return
        }
        guard volume == nil else { replyHandler(nil, POSIXError(.EBUSY)); return }
        let url = resource.url
        scopeStarted = url.startAccessingSecurityScopedResource()
        Logger(subsystem: "dev.streamdrive.app.filesystem", category: "mount")
            .notice("Resource security scope started: \(self.scopeStarted, privacy: .public)")
        scopedURL = url
        do {
            let mount = try FinderMountResource(stateRoot: url, requestedProfile: selectedProfile(options))
            let readonly = !resource.isWritable || options.taskOptions.contains("--rdonly")
            let loaded = StreamDriveVolume(stateRoot: url, mountResource: mount, readOnly: readonly) { [weak self] active in
                self?.containerStatus = active ? .active : .ready
            }
            volume = loaded
            containerStatus = .ready
            replyHandler(loaded, nil)
        } catch {
            if scopeStarted { url.stopAccessingSecurityScopedResource() }
            scopedURL = nil; scopeStarted = false
            replyHandler(nil, filesystemError(error))
        }
    }

    func unloadResource(resource: FSResource, options: FSTaskOptions,
                        replyHandler: @escaping (Error?) -> Void) {
        // deactivate/synchronize have already persisted pending writes.
        volume = nil
        if scopeStarted { scopedURL?.stopAccessingSecurityScopedResource() }
        scopedURL = nil; scopeStarted = false
        containerStatus = .notReady(status: POSIXError(.ENOTCONN))
        replyHandler(nil)
    }
}
