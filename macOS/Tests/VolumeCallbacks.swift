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
private func call(_ operation: (@escaping (Error?) -> Void) -> Void) throws {
    let _: Void = try response { done in operation { error in done(error.map { .failure($0) } ?? .success(())) } }
}
/// Local fixture storage whose calls can be held open, to observe callbacks while
/// an upload, fetch or rename is in flight. A gate holds the next matching call
/// (`"commit /path"`, `"readSnapshot /path"`, `"move /path"`) before it runs.
private final class GatedBackend: StorageBackend {
    final class Gate { let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0) }
    let base: LocalDirectoryBackend
    private let lock = NSLock()
    private var gates: [String: Gate] = [:]
    private var reported: VolumeCapacity?
    private var failingCapacityCalls = 0
    init(root: URL) throws { base = try LocalDirectoryBackend(root: root) }
    func gate(_ call: String) -> Gate {
        let gate = Gate()
        lock.lock(); gates[call] = gate; lock.unlock()
        return gate
    }
    /// A quota, as ParaAir Cloud reports one; nil like BYO storage.
    var reportedCapacity: VolumeCapacity? {
        get { lock.lock(); defer { lock.unlock() }; return reported }
        set { lock.lock(); reported = newValue; lock.unlock() }
    }
    private func pass(_ call: String) {
        lock.lock(); let gate = gates.removeValue(forKey: call); lock.unlock()
        if let gate { gate.entered.signal(); _ = gate.release.wait(timeout: .now() + 15) }
    }
    func stat(_ path: String) throws -> FileEntry { try base.stat(path) }
    func list(_ path: String) throws -> [FileEntry] { try base.list(path) }
    func read(_ path: String, offset: Int64, length: Int) throws -> Data { try base.read(path, offset: offset, length: length) }
    func readSnapshot(_ path: String, version: String, offset: Int64, length: Int) throws -> Data {
        pass("readSnapshot " + path)
        return try base.readSnapshot(path, version: version, offset: offset, length: length)
    }
    func commit(_ commit: FileCommit) throws -> FileEntry {
        pass("commit " + commit.path)
        return try base.commit(commit)
    }
    func commitStatus(transactionID: String, path: String, expectedVersion: String?) throws -> CommitStatus {
        try base.commitStatus(transactionID: transactionID, path: path, expectedVersion: expectedVersion)
    }
    /// The next `count` capacity calls fail, as ParaAir Cloud's do while offline.
    func failCapacity(_ count: Int) { lock.lock(); failingCapacityCalls = count; lock.unlock() }
    func capacity() throws -> VolumeCapacity? {
        lock.lock(); defer { lock.unlock() }
        guard failingCapacityCalls == 0 else { failingCapacityCalls -= 1; throw DriveError(ENETDOWN, "Offline") }
        return reported
    }
    func createDirectory(_ path: String) throws -> FileEntry { try base.createDirectory(path) }
    func move(_ source: String, to destination: String) throws { pass("move " + source); try base.move(source, to: destination) }
    func remove(_ path: String, directory: Bool) throws { try base.remove(path, directory: directory) }
}
/// Memory standing in for FSKit's read buffer.
private final class MemoryDestination: ReadDestination {
    var bytes: Data
    init(length: Int) { bytes = Data(count: length) }
    func withBytes<R>(_ body: (UnsafeMutableRawBufferPointer) throws -> R) throws -> R { try bytes.withUnsafeMutableBytes(body) }
}
/// One callback still in flight, observed from the test thread.
private final class PendingCall<T> {
    private let done = DispatchSemaphore(value: 0), lock = NSLock()
    private var value: Result<T, Error>?
    func finish(_ result: Result<T, Error>) { lock.lock(); value = result; lock.unlock(); done.signal() }
    var finished: Bool { lock.lock(); defer { lock.unlock() }; return value != nil }
    func result() throws -> T {
        guard done.wait(timeout: .now() + 15) == .success else { throw DriveError(ETIMEDOUT, "FSKit callback did not complete") }
        done.signal()
        lock.lock(); defer { lock.unlock() }
        return try value!.get()
    }
}
private func startRead(_ item: FSItem, volume: StreamDriveVolume, offset: Int64 = 0, length: Int) -> PendingCall<Data> {
    let call = PendingCall<Data>(), destination = MemoryDestination(length: length)
    volume.read(from: item, at: offset, length: length, into: destination) { count, error in
        call.finish(error.map { .failure($0) } ?? .success(destination.bytes.prefix(count)))
    }
    return call
}
private func read(_ item: FSItem, volume: StreamDriveVolume, offset: Int64 = 0, length: Int) throws -> Data {
    try startRead(item, volume: volume, offset: offset, length: length).result()
}
private func seconds(since start: DispatchTime) -> Double { Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9 }
/// Upload scheduling: open-mode tracking, and a synchronize that uploads off the
/// serial queue without reordering writes queued before it.
private func runUploadChecks(_ base: URL) throws {
    let fixture = base.appendingPathComponent("upload-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixture) }
    let remote = fixture.appendingPathComponent("remote")
    let backend = try GatedBackend(root: remote)
    try ProfileStore(root: fixture).save(DriveProfile(name: "uploads", backend: .local, localRoot: remote.path))
    try Data("existing".utf8).write(to: remote.appendingPathComponent("existing"))
    let engine = try Engine(backend: backend, stateDirectory: fixture.appendingPathComponent("state"), minFreeBytes: 0)
    let volume = StreamDriveVolume(stateRoot: fixture, mountResource: try FinderMountResource(stateRoot: fixture, requestedProfile: "uploads"),
                                   readOnly: false, engine: engine) { _ in }
    let root = DriveItem(path: "/", identifier: .rootDirectory)
    let created: FSItem = try response { done in
        volume.createItem(named: FSFileName(string: "movie"), type: .file, inDirectory: root, attributes: FSItem.SetAttributesRequest()) { item, _, error in
            if let error { done(.failure(error)) } else if let item { done(.success(item)) }
            else { done(.failure(DriveError(EIO, "Create returned no item"))) }
        }
    }
    // FSKit reports the modes kept after each close.
    try call { volume.openItem(created, modes: [.read, .write], replyHandler: $0) }
    try check(volume.isOpenForWriting("/movie"), "A file opened for writing was not tracked")
    try call { volume.openItem(created, modes: [.read], replyHandler: $0) }
    try call { volume.closeItem(created, modes: [.read, .write], replyHandler: $0) }
    try check(volume.isOpenForWriting("/movie"), "A close that keeps write access cleared it")
    try call { volume.closeItem(created, modes: [.read], replyHandler: $0) }
    try check(!volume.isOpenForWriting("/movie"), "Write access survived the last writer's close")
    try call { volume.openItem(created, modes: [.write], replyHandler: $0) }
    try call { done in
        volume.renameItem(created, inDirectory: root, named: FSFileName(string: "movie"), to: FSFileName(string: "renamed"),
                          inDirectory: root, overItem: nil) { _, error in done(error) }
    }
    try check(volume.isOpenForWriting("/renamed") && !volume.isOpenForWriting("/movie"), "Rename did not move the open-mode record")
    try call { volume.closeItem(created, modes: [], replyHandler: $0) }
    try check(!volume.isOpenForWriting("/renamed"), "A full close left an open-mode record")
    // Queue a write and a synchronize back to back, then hold the upload open.
    let upload = backend.gate("commit /renamed")
    let wrote = DispatchSemaphore(value: 0), synced = DispatchSemaphore(value: 0)
    var writeResult: (Int, Error?) = (0, nil), syncError: Error?
    volume.write(contents: Data("queued before sync".utf8), to: created, at: 0) { count, error in writeResult = (count, error); wrote.signal() }
    volume.synchronize(flags: .wait) { error in syncError = error; synced.signal() }
    try check(upload.entered.wait(timeout: .now() + 10) == .success, "synchronize did not start the upload")
    try check(wrote.wait(timeout: .now() + 1) == .success && writeResult.1 == nil && writeResult.0 == 18, "The queued write did not complete")
    let started = DispatchTime.now()
    let existing = try lookup("existing", directory: root, volume: volume)
    _ = try attributes(existing, volume: volume)
    try check(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds < 2_000_000_000,
              "lookupItem waited for an in-flight upload")
    try check(synced.wait(timeout: .now()) == .timedOut, "synchronize replied before its upload finished")
    upload.release.signal()
    try check(synced.wait(timeout: .now() + 10) == .success && syncError == nil, "synchronize failed: \(String(describing: syncError))")
    try check(try Data(contentsOf: remote.appendingPathComponent("renamed")) == Data("queued before sync".utf8),
              "A write queued before synchronize was not published")
    try check(try engine.uploads().isEmpty, "synchronize left pending uploads")
}
/// Concurrent reads: a cold fetch blocks nothing else, a rename during a read keeps
/// its bytes, and a read under an in-flight rename waits for it on the serial queue.
private func runConcurrencyChecks(_ base: URL) throws {
    let fixture = base.appendingPathComponent("reads-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixture) }
    let remote = fixture.appendingPathComponent("remote")
    let backend = try GatedBackend(root: remote)
    try ProfileStore(root: fixture).save(DriveProfile(name: "reads", backend: .local, localRoot: remote.path))
    try Data(repeating: 5, count: 8192).write(to: remote.appendingPathComponent("cold"))
    try Data(repeating: 6, count: 4096).write(to: remote.appendingPathComponent("warm"))
    try Data("original bytes".utf8).write(to: remote.appendingPathComponent("moving"))
    try FileManager.default.createDirectory(at: remote.appendingPathComponent("folder"), withIntermediateDirectories: true)
    try Data("child".utf8).write(to: remote.appendingPathComponent("folder/child"))
    let engine = try Engine(backend: backend, stateDirectory: fixture.appendingPathComponent("state"), minFreeBytes: 0)
    let volume = StreamDriveVolume(stateRoot: fixture, mountResource: try FinderMountResource(stateRoot: fixture, requestedProfile: "reads"),
                                   readOnly: false, engine: engine) { _ in }
    let root = DriveItem(path: "/", identifier: .rootDirectory)
    let cold = try lookup("cold", directory: root, volume: volume), warm = try lookup("warm", directory: root, volume: volume)
    try check(try read(warm, volume: volume, length: 4096) == Data(repeating: 6, count: 4096), "The warm read failed")

    let fetch = backend.gate("readSnapshot /cold")
    let coldRead = startRead(cold, volume: volume, offset: 4000, length: 200)
    try check(fetch.entered.wait(timeout: .now() + 10) == .success, "The cold read did not start its fetch")
    let started = DispatchTime.now()
    try check(try read(warm, volume: volume, offset: 10, length: 10) == Data(repeating: 6, count: 10), "A cached read failed during a cold fetch")
    try check(try attributes(warm, volume: volume).size == 4096 && attributes(cold, volume: volume).size == 8192,
              "Attribute requests failed during a cold fetch")
    _ = try lookup("moving", directory: root, volume: volume)
    try check(seconds(since: started) < 2, "Reads and attribute requests waited for a cold fetch")
    try check(!coldRead.finished, "The held cold read finished early")
    fetch.release.signal()
    try check(try coldRead.result() == Data(repeating: 5, count: 200), "The cold read returned wrong bytes")

    let moving = try lookup("moving", directory: root, volume: volume)
    let movingFetch = backend.gate("readSnapshot /moving")
    let movingRead = startRead(moving, volume: volume, length: 64)
    try check(movingFetch.entered.wait(timeout: .now() + 10) == .success, "The read of the renamed file did not start its fetch")
    try call { done in
        volume.renameItem(moving, inDirectory: root, named: FSFileName(string: "moving"), to: FSFileName(string: "moved"),
                          inDirectory: root, overItem: nil) { _, error in done(error) }
    }
    movingFetch.release.signal()
    try check(try movingRead.result() == Data("original bytes".utf8), "A rename during a read changed what it returned")

    // The rename is held in its pre-move upload, outside the engine's state lock.
    let folder = try lookup("folder", directory: root, volume: volume)
    let child = try lookup("child", directory: folder, volume: volume)
    let pending: FSItem = try response { done in
        volume.createItem(named: FSFileName(string: "pending"), type: .file, inDirectory: folder, attributes: FSItem.SetAttributesRequest()) { item, _, error in
            if let error { done(.failure(error)) } else if let item { done(.success(item)) }
            else { done(.failure(DriveError(EIO, "Create returned no item"))) }
        }
    }
    try call { done in volume.write(contents: Data("pending".utf8), to: pending, at: 0) { _, error in done(error) } }
    let upload = backend.gate("commit /folder/pending")
    let renamed = PendingCall<Void>()
    volume.renameItem(folder, inDirectory: root, named: FSFileName(string: "folder"), to: FSFileName(string: "renamed-folder"),
                      inDirectory: root, overItem: nil) { _, error in renamed.finish(error.map { .failure($0) } ?? .success(())) }
    try check(upload.entered.wait(timeout: .now() + 10) == .success, "The rename did not start its upload")
    let childRead = startRead(child, volume: volume, length: 5)
    Thread.sleep(forTimeInterval: 0.3)
    try check(!childRead.finished, "A read under an in-flight rename did not wait for it on the serial queue")
    upload.release.signal()
    try renamed.result()
    try check(try childRead.result() == Data("child".utf8), "The read after the rename returned wrong bytes")
    try check((child as? DriveItem)?.path == "/renamed-folder/child", "The rename left a stale child path")
}
/// A quota-style backend reports volume sizes and the profile's block size as ioSize.
private func runCapacityChecks(_ base: URL) throws {
    let fixture = base.appendingPathComponent("capacity-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixture) }
    let remote = fixture.appendingPathComponent("remote")
    let backend = try GatedBackend(root: remote)
    let total: Int64 = 1 << 40, available: Int64 = (1 << 40) - (3 << 30)
    backend.reportedCapacity = VolumeCapacity(totalBytes: total, availableBytes: available)
    try ProfileStore(root: fixture).save(DriveProfile(name: "cloud", backend: .local, localRoot: remote.path, blockSize: 4_194_304))
    let volume = StreamDriveVolume(stateRoot: fixture, mountResource: try FinderMountResource(stateRoot: fixture, requestedProfile: "cloud"),
                                   readOnly: false, openEngine: { profile, root in
        try Engine(backend: backend, stateDirectory: root.appendingPathComponent("state"), minFreeBytes: 0, blockSize: profile.blockSize)
    }) { _ in }
    try check(volume.supportedVolumeCapabilities.doesNotSupportVolumeSizes, "An inactive volume reported a capacity")
    let _: FSItem = try response { done in
        volume.activate(taskOptions: []) { item, error in
            if let error { done(.failure(error)) } else if let item { done(.success(item)) }
            else { done(.failure(DriveError(EIO, "Activation returned no root"))) }
        }
    }
    try check(!volume.supportedVolumeCapabilities.doesNotSupportVolumeSizes, "A cloud-style backend did not report volume sizes")
    let statistics = volume.volumeStatistics
    try check(statistics.totalBytes == UInt64(total) && statistics.availableBytes == UInt64(available)
              && statistics.freeBytes == UInt64(available) && statistics.usedBytes == UInt64(total - available),
              "Volume byte counts do not match the reported capacity")
    try check(statistics.totalBlocks == UInt64(total) / 4096 && statistics.availableBlocks == UInt64(available) / 4096
              && statistics.usedBlocks == UInt64(total - available) / 4096, "Volume block counts do not match the reported capacity")
    try check(statistics.blockSize == 4096 && statistics.ioSize == 4_194_304, "ioSize is not the profile block size")
    try call { volume.deactivate(options: [], replyHandler: $0) }
    try check(volume.supportedVolumeCapabilities.doesNotSupportVolumeSizes, "A deactivated volume kept reporting a capacity")
    // Mounted while capacity is unavailable (offline): retried, and reported once the backend answers.
    let offlineState = fixture.appendingPathComponent("offline-state")
    backend.failCapacity(2)
    let offline = StreamDriveVolume(stateRoot: fixture, mountResource: try FinderMountResource(stateRoot: fixture, requestedProfile: "cloud"),
                                    readOnly: false, openEngine: { profile, _ in
        try Engine(backend: backend, stateDirectory: offlineState, minFreeBytes: 0, blockSize: profile.blockSize)
    }) { _ in }
    offline.capacityRefreshNanoseconds = 100_000_000
    let _: FSItem = try response { done in
        offline.activate(taskOptions: []) { item, error in
            if let error { done(.failure(error)) } else if let item { done(.success(item)) }
            else { done(.failure(DriveError(EIO, "Activation returned no root"))) }
        }
    }
    try check(offline.supportedVolumeCapabilities.doesNotSupportVolumeSizes && offline.volumeStatistics.totalBytes == 0,
              "A volume reported sizes before any capacity was known")
    let deadline = DispatchTime.now() + 10
    while offline.supportedVolumeCapabilities.doesNotSupportVolumeSizes, DispatchTime.now() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    try check(!offline.supportedVolumeCapabilities.doesNotSupportVolumeSizes && offline.volumeStatistics.totalBytes == UInt64(total)
              && offline.volumeStatistics.availableBytes == UInt64(available), "A capacity that failed at activation was never retried")
    try call { offline.deactivate(options: [], replyHandler: $0) }
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
        try check(activatedVolume.supportedVolumeCapabilities.doesNotSupportVolumeSizes,
                  "A backend without a quota must not report volume sizes")
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
        try runUploadChecks(base)
        try runConcurrencyChecks(base)
        try runCapacityChecks(base)
        print("FSKit callback tests passed: replacement tombstones, removal tombstones, stable IDs, moved descendants, initial size, same-path rename, open-mode tracking, non-blocking synchronize, ordered sync, concurrent reads, rename during read, serial fallback, volume sizes, capacity retried after an offline activation")
    }
}
