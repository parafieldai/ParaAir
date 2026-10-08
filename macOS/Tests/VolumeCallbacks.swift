import Foundation
import FSKit
import StreamDriveCore
import Darwin

private func response<T>(_ operation: (@escaping (Result<T, Error>) -> Void) -> Void) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<T, Error>?
    operation { result = $0; semaphore.signal() }
    guard semaphore.wait(timeout: .now() + 15) == .success, let result else {
        throw DriveError(ETIMEDOUT, "FSKit callback did not complete")
    }
    return try result.get()
}
private func lookup(_ name: String, directory: FSItem, volume: StreamDriveVolume) throws -> FSItem {
    try response { done in
        volume.lookupItem(named: FSFileName(string: name), inDirectory: directory) { item, _, error in
            if let error { done(.failure(error)) }
            else if let item { done(.success(item)) }
            else { done(.failure(DriveError(EIO, "Lookup returned no item"))) }
        }
    }
}
private func attributes(_ item: FSItem, volume: StreamDriveVolume,
                        wanted: FSItem.Attribute = [.size, .fileID, .parentID]) throws -> FSItem.Attributes {
    let request = FSItem.GetAttributesRequest()
    request.wantedAttributes = wanted
    return try response { done in
        volume.getAttributes(request, of: item) { attributes, error in
            if let error { done(.failure(error)) }
            else if let attributes { done(.success(attributes)) }
            else { done(.failure(DriveError(EIO, "No attributes returned"))) }
        }
    }
}
private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw DriveError(EIO, message) }
}
private func expectStale(_ item: FSItem, volume: StreamDriveVolume) throws {
    do {
        _ = try attributes(item, volume: volume)
        throw DriveError(EIO, "A deleted item unexpectedly resolved the replacement")
    } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ESTALE) {}
}
private func probeIdentifier(_ root: URL) throws -> UUID {
    let filesystem = StreamDriveFileSystem()
    let resource = FSPathURLResource(url: root, writable: true)
    return try response { done in
        filesystem.probeResource(resource: resource) { result, error in
            if let error { done(.failure(error)) }
            else if let identifier = result?.containerID?.uuid { done(.success(identifier)) }
            else { done(.failure(DriveError(EIO, "Probe returned no container identifier"))) }
        }
    }
}

@main
struct VolumeCallbackTests {
    static func main() {
        do { try run() }
        catch { fputs("FSKit callback test failed: \(error)\n", stderr); exit(1) }
    }
    private static func run() throws {
        guard CommandLine.arguments.count == 2 else { throw DriveError(EINVAL, "Pass an in-workspace scratch directory") }
        let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let fixture = base.appendingPathComponent("fskit-callback-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let backendRoot = fixture.appendingPathComponent("remote")
        let backend = try LocalDirectoryBackend(root: backendRoot)
        // Exercise the optimized Core validator as part of the release-linked
        // callback harness, before any filesystem or profile decoding occurs.
        try DriveProfile.validateName("test")
        try DriveProfile.validateName("A0._-" + String(repeating: "x", count: 59))
        for invalid in ["../escape", "éclair", ".hidden", "", String(repeating: "a", count: 65)] {
            do {
                try DriveProfile.validateName(invalid)
                throw DriveError(EIO, "Profile validation accepted an invalid fixture name")
            } catch let error as DriveError where error.code == EINVAL {}
        }
        let profile = DriveProfile(name: "test", backend: .local, localRoot: backendRoot.path)
        try profile.validate()
        try ProfileStore(root: fixture).save(profile)
        _ = try ProfileStore(root: fixture).list()
        let probedID = try probeIdentifier(fixture)
        try check(try probeIdentifier(fixture) == probedID, "Independent filesystem probes changed the container identifier")
        var namedProfile = profile
        namedProfile.displayName = "Studio — Video Projects"
        try ProfileStore(root: fixture).save(namedProfile, overwrite: true)
        try check(try probeIdentifier(fixture) == probedID, "Changing the Finder name changed the container identity")
        try Data("source".utf8).write(to: backendRoot.appendingPathComponent("source"))
        let sourceTimes = [timeval(tv_sec: 200000000, tv_usec: 123456), timeval(tv_sec: 400000000, tv_usec: 654321)]
        try check(sourceTimes.withUnsafeBufferPointer {
            Darwin.utimes(backendRoot.appendingPathComponent("source").path, $0.baseAddress)
        } == 0, "Cannot prepare distinct access/modification times")
        try Data("old destination".utf8).write(to: backendRoot.appendingPathComponent("destination"))
        try FileManager.default.createDirectory(at: backendRoot.appendingPathComponent("directory"), withIntermediateDirectories: false)
        try Data("child".utf8).write(to: backendRoot.appendingPathComponent("directory/child"))
        let engine = try Engine(backend: backend, stateDirectory: fixture.appendingPathComponent("state"), minFreeBytes: 0)
        let mount = try FinderMountResource(stateRoot: fixture, requestedProfile: "test")
        let volume = StreamDriveVolume(stateRoot: fixture, mountResource: mount, readOnly: false, engine: engine) { _ in }
        try check(volume.volumeID.uuid == probedID, "Unary container and volume identifiers differ")
        try check(volume.name.string == namedProfile.finderName, "The volume ignored the configured Finder name")
        let activatedVolume = StreamDriveVolume(stateRoot: fixture, mountResource: mount, readOnly: true) { _ in }
        let _: FSItem = try response { done in
            activatedVolume.activate(taskOptions: []) { item, error in
                if let error { done(.failure(error)) }
                else if let item { done(.success(item)) }
                else { done(.failure(DriveError(EIO, "Activation returned no root"))) }
            }
        }
        try check(activatedVolume.name.string == namedProfile.finderName,
                  "Activation replaced the custom Finder name with the internal profile name")
        let _: Void = try response { done in
            activatedVolume.deactivate(options: []) { error in
                done(error.map { .failure($0) } ?? .success(()))
            }
        }
        let root = DriveItem(path: "/", identifier: .rootDirectory)
        // FSVolumeConnector requests this standard mask for Finder/bookmarks.
        // A mount can serve POSIX reads while incomplete attributes break the
        // higher-level volume interface. Check the real callback contract.
        let standardFields: [FSItem.Attribute] = [.type, .mode, .linkCount, .flags, .size,
                                                  .fileID, .accessTime, .modifyTime, .changeTime]
        let standardMask = standardFields.reduce(FSItem.Attribute()) { $0.union($1) }
        for item in [root, try lookup("source", directory: root, volume: volume)] {
            let standard = try attributes(item, volume: volume, wanted: standardMask)
            for field in standardFields {
                try check(standard.isValid(field), "FSKit standard attribute missing: \(field.rawValue)")
            }
            try check(standard.flags == 0, "Unsupported BSD file flags must be clear")
        }
        let sourceMetadata = try attributes(try lookup("source", directory: root, volume: volume),
                                            volume: volume, wanted: standardMask)
        try check(sourceMetadata.accessTime.tv_sec == 200000000 && sourceMetadata.accessTime.tv_nsec == 123456000,
                  "FSKit replaced the recorded access time with modification time")
        let rootAttributes = try attributes(root, volume: volume)
        try check(rootAttributes.fileID == .rootDirectory, "Root directory identifier is invalid")
        try check(rootAttributes.parentID == .parentOfRoot, "Root must identify FSKit's parent-of-root sentinel")
        try check(volume.supportedVolumeCapabilities.doesNotSupportRootTimes,
                  "A backend without root creation timestamps must advertise that limitation")
        let initial = FSItem.SetAttributesRequest()
        initial.size = 128
        let created: FSItem = try response { done in
            volume.createItem(named: FSFileName(string: "sparse"), type: .file, inDirectory: root, attributes: initial) { item, _, error in
                if let error { done(.failure(error)) }
                else if let item { done(.success(item)) }
                else { done(.failure(DriveError(EIO, "Create returned no item"))) }
            }
        }
        try check(try attributes(created, volume: volume).size == 128, "Create ignored initial file size")
        try check(initial.wasAttributeConsumed(.size), "Create did not acknowledge initial size")
        let source = try lookup("source", directory: root, volume: volume)
        let overwritten = try lookup("destination", directory: root, volume: volume)
        let identity = try attributes(source, volume: volume).fileID
        let _: Void = try response { done in
            volume.renameItem(source, inDirectory: root, named: FSFileName(string: "source"),
                to: FSFileName(string: "source"), inDirectory: root, overItem: source) { _, error in
                done(error.map { .failure($0) } ?? .success(()))
            }
        }
        try check(try attributes(source, volume: volume).fileID == identity, "Same-path rename changed file identity")
        try check(!(source as! DriveItem).deleted, "Same-path rename tombstoned the source")
        let _: Void = try response { done in
            volume.renameItem(source, inDirectory: root, named: FSFileName(string: "source"),
                to: FSFileName(string: "destination"), inDirectory: root, overItem: overwritten) { _, error in
                done(error.map { .failure($0) } ?? .success(()))
            }
        }
        try expectStale(overwritten, volume: volume)
        let replacement = try lookup("destination", directory: root, volume: volume)
        try check(replacement === source, "Rename changed active source object identity")
        try check(try attributes(replacement, volume: volume).fileID == identity, "Rename changed active file ID")
        let _: Void = try response { done in
            volume.removeItem(replacement, named: FSFileName(string: "destination"), fromDirectory: root) { error in
                done(error.map { .failure($0) } ?? .success(()))
            }
        }
        try expectStale(replacement, volume: volume)
        let directory = try lookup("directory", directory: root, volume: volume)
        let child = try lookup("child", directory: directory, volume: volume)
        let _: Void = try response { done in
            volume.renameItem(directory, inDirectory: root, named: FSFileName(string: "directory"),
                to: FSFileName(string: "moved"), inDirectory: root, overItem: nil) { _, error in
                done(error.map { .failure($0) } ?? .success(()))
            }
        }
        try check((child as? DriveItem)?.path == "/moved/child", "Directory rename left a stale child path")
        try check(try attributes(child, volume: volume).size == 5, "Moved child no longer resolves its contents")
        print("FSKit callback tests passed: replacement tombstones, removal tombstones, stable IDs, moved descendants, initial size, same-path rename")
    }
}
