import Foundation
import FSKit
import StreamDriveCore
import Darwin
import OSLog

final class DriveItem: FSItem {
    var path: String
    var deleted = false
    let identifier: FSItem.Identifier
    init(path: String, identifier: FSItem.Identifier) {
        self.path = path; self.identifier = identifier
        super.init()
    }
}

/// Where read bytes go: FSKit's buffer, or memory in the callback harness.
protocol ReadDestination: AnyObject {
    func withBytes<R>(_ body: (UnsafeMutableRawBufferPointer) throws -> R) throws -> R
}
extension FSMutableFileDataBuffer: ReadDestination {
    func withBytes<R>(_ body: (UnsafeMutableRawBufferPointer) throws -> R) throws -> R { try withUnsafeMutableBytes(body) }
}

/// The serial queue keeps FSItem identity, directory cookies and path changes in
/// step with journal operations. The storage engine fetches bounded ranges only.
/// Uploads run on `uploadQueue`, never on the serial queue. Reads and attribute
/// requests run concurrently on `reads`, and fall back to the serial queue when a
/// rename or removal touches their path.
final class StreamDriveVolume: FSVolume, FSVolume.Operations, FSVolume.ReadWriteOperations,
                               FSVolume.OpenCloseOperations {
    typealias EngineOpener = (DriveProfile, URL) throws -> Engine
    private let queue = DispatchQueue(label: "dev.streamdrive.filesystem.io", qos: .userInitiated)
    private let uploadQueue = DispatchQueue(label: "dev.streamdrive.filesystem.upload", qos: .utility)
    /// Index backups (a metadata dump and its upload) run here, never delaying uploads.
    private let indexQueue = DispatchQueue(label: "dev.streamdrive.filesystem.index", qos: .utility)
    private let reads: OperationQueue = {
        let reads = OperationQueue()
        reads.name = "dev.streamdrive.filesystem.read"
        reads.maxConcurrentOperationCount = 8
        reads.qualityOfService = .userInitiated
        return reads
    }()
    /// Guards the mutable state below and `DriveItem.path`/`.deleted`, which the
    /// uploader and concurrent reads use off the serial queue. No engine call runs
    /// while it is held.
    private let stateLock = NSRecursiveLock()
    private let stateRoot: URL
    private let setActive: (Bool) -> Void
    private let openEngine: EngineOpener
    private var profileName: String?
    private var readOnly: Bool
    private var engine: Engine?
    private var uploader: DispatchSourceTimer?
    /// Renames and removals between their storage call and their node bookkeeping.
    private var inFlightChanges: [UUID: (from: String, to: String?)] = [:]
    /// Bumped only in the node bookkeeping of rename and remove. A concurrent read
    /// is accepted only if it did not change while the read ran.
    private var namespaceGeneration: UInt64 = 0
    /// Quota-style capacity, for backends that report one (ParaAir Cloud).
    private var reportsCapacity = false
    /// The capacity call failed at activation (offline): retried until the backend answers.
    private var capacityUnknown = false
    private var capacity: VolumeCapacity?
    private var ioSize: Int
    /// Uptime of the last capacity refresh; uploadQueue only.
    private var capacityRefreshedAt: UInt64 = 0
    /// How often capacity is refreshed or retried; tests shorten it.
    var capacityRefreshNanoseconds: UInt64 = 60_000_000_000
    /// Uptime of the last index backup check; uploadQueue only.
    private var indexCheckedAt: UInt64 = 0
    /// How often the engine is asked whether an index backup is due, and its policy;
    /// the callback harness shortens both.
    var indexCheckNanoseconds: UInt64 = 30_000_000_000
    var indexBackupPolicy = IndexBackupPolicy.standard
    /// Uptime of the last ownership recheck; uploadQueue only.
    private var ownerCheckedAt: UInt64 = 0
    /// How often an idle drive rechecks whether another Mac took it over.
    var ownerCheckNanoseconds: UInt64 = 300_000_000_000
    private var nodes: [String: DriveItem] = [:]
    private var nextID: UInt64 = 3
    private var generation: UInt64 = 1
    private struct Listing { var generation: UInt64; var entries: [(String, FileEntry)] }
    private var listings: [String: Listing] = [:]
    /// Modes each open path keeps, so the uploader can leave files being written alone.
    private var openModes: [String: FSVolume.OpenModes] = [:]
    // Read and written only on uploadQueue.
    private struct UploadCounts: Equatable { var published = 0, remaining = 0, blocked = 0, conflicts = 0 }
    private var uploadPaths = Set<String>()
    private var uploadCounts: UploadCounts?
    private static let uploadLog = Logger(subsystem: "dev.streamdrive.app.filesystem", category: "upload")
    private static let indexLog = Logger(subsystem: "dev.streamdrive.app.filesystem", category: "index")
    var isOpenCloseInhibited = false

    init(stateRoot: URL, mountResource: FinderMountResource, readOnly: Bool, engine: Engine? = nil,
         openEngine: @escaping EngineOpener = { try Engine.open(profile: $0, stateRoot: $1) }, setActive: @escaping (Bool) -> Void) {
        self.engine = engine
        self.setActive = setActive; self.openEngine = openEngine
        self.stateRoot = stateRoot; self.profileName = mountResource.profile.name; self.readOnly = readOnly
        ioSize = mountResource.profile.blockSize
        super.init(volumeID: FSVolume.Identifier(uuid: mountResource.identifier), volumeName: FSFileName(string: mountResource.profile.finderName))
        nodes["/"] = DriveItem(path: "/", identifier: .rootDirectory)
    }

    var maximumLinkCount: Int { 1 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }
    var maximumXattrSize: Int { 0 }
    var maximumFileSizeInBits: Int { 64 }
    var enableOpenUnlinkEmulation: Bool { true }

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let c = FSVolume.SupportedCapabilities()
        c.caseFormat = .sensitive
        c.supports64BitObjectIDs = true
        c.supports2TBFiles = true
        c.supportsHiddenFiles = true
        c.supportsSparseFiles = true
        // The backend exposes modification time, but no root creation time.
        c.doesNotSupportRootTimes = true
        c.doesNotSupportSettingFilePermissions = true
        c.doesNotSupportImmutableFiles = true
        // An S3 bucket has no trustworthy fixed capacity; only a quota-style backend reports one.
        c.doesNotSupportVolumeSizes = !locked { reportsCapacity }
        // The local journal is durable; it isn't a remote filesystem journal.
        c.supportsJournal = false
        return c
    }
    var volumeStatistics: FSStatFSResult {
        let s = FSStatFSResult(fileSystemTypeName: "streamdrive")
        let (capacity, ioSize) = locked { (capacity, ioSize) }
        s.blockSize = 4096; s.ioSize = ioSize
        // Without a reported capacity, do not invent one.
        guard let capacity else { return s }
        let total = UInt64(max(0, capacity.totalBytes)), available = UInt64(max(0, min(capacity.availableBytes, capacity.totalBytes)))
        s.totalBytes = total; s.availableBytes = available; s.freeBytes = available; s.usedBytes = total - available
        s.totalBlocks = total / 4096; s.availableBlocks = available / 4096; s.freeBlocks = available / 4096
        s.usedBlocks = s.totalBlocks - s.freeBlocks
        return s
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        stateLock.lock(); defer { stateLock.unlock() }
        return try body()
    }
    private func storage() throws -> Engine {
        guard let engine = locked({ engine }) else { throw POSIXError(.ENOTCONN) }
        return engine
    }
    private func path(_ item: FSItem) throws -> String {
        guard let node = item as? DriveItem else { throw POSIXError(.EINVAL) }
        return try locked {
            guard !node.deleted else { throw POSIXError(.ESTALE) }
            return node.path
        }
    }
    /// True while some open of `path` keeps write access. Safe from any queue.
    func isOpenForWriting(_ path: String) -> Bool {
        locked { openModes[path]?.contains(.write) ?? false }
    }
    /// Moves or drops open-mode records for a renamed or removed subtree.
    private func moveOpenModes(from source: String, to destination: String?) {
        let affected = openModes.filter { $0.key == source || $0.key.hasPrefix(source + "/") }
        for key in affected.keys { openModes.removeValue(forKey: key) }
        guard let destination else { return }
        for (old, modes) in affected { openModes[destination + old.dropFirst(source.count)] = modes }
    }
    /// Registers a rename or removal before its storage call; the node bookkeeping ends it.
    private func beginChange(from source: String, to destination: String?) -> UUID {
        let id = UUID()
        locked { inFlightChanges[id] = (source, destination) }
        return id
    }
    private func abandonChange(_ id: UUID) { locked { inFlightChanges[id] = nil } }
    /// Whether two paths are equal or one contains the other.
    private func related(_ a: String, _ b: String) -> Bool {
        a == b || a == "/" || b == "/" || b.hasPrefix(a + "/") || a.hasPrefix(b + "/")
    }
    /// For a concurrent read: the item's path, the namespace generation and the
    /// engine, or nil when an in-flight rename or removal touches the path.
    private func concurrentSnapshot(_ item: FSItem) throws -> (path: String, generation: UInt64, engine: Engine)? {
        guard let node = item as? DriveItem else { throw POSIXError(.EINVAL) }
        return try locked {
            guard !node.deleted else { throw POSIXError(.ESTALE) }
            guard let engine else { throw POSIXError(.ENOTCONN) }
            let path = node.path
            if inFlightChanges.values.contains(where: { related($0.from, path) || $0.to.map { related($0, path) } == true }) { return nil }
            return (path, namespaceGeneration, engine)
        }
    }
    /// Runs `body` on `reads` from a namespace snapshot. A result stands only if no
    /// rename or removal finished meanwhile; an ENOENT during an in-flight change is
    /// retried. After three tries, or when a change touches the path, `serial`
    /// answers on the serial queue instead.
    private func concurrently<T>(_ item: FSItem, _ body: @escaping (String, Engine) throws -> T,
                                 reply: @escaping (Result<T, Error>) -> Void, serial: @escaping () -> Void) {
        reads.addOperation { [self] in
            for _ in 0..<3 {
                let snapshot: (path: String, generation: UInt64, engine: Engine)
                do {
                    guard let value = try concurrentSnapshot(item) else { break }
                    snapshot = value
                } catch { reply(.failure(error)); return }
                let result = Result { try body(snapshot.path, snapshot.engine) }
                let (unchanged, changing) = locked { (namespaceGeneration == snapshot.generation, !inFlightChanges.isEmpty) }
                guard unchanged else { continue }
                if case .failure(let error) = result, (error as? DriveError)?.code == ENOENT, changing { continue }
                reply(result); return
            }
            queue.async(execute: serial)
        }
    }
    private func child(_ name: FSFileName, in directory: FSItem) throws -> String {
        guard let name = name.string, !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\0"), name.utf8.count <= 255 else {
            throw POSIXError(.EINVAL)
        }
        let parent = try path(directory)
        return try canonicalPath((parent == "/" ? "" : parent) + "/" + name)
    }
    private func node(_ path: String) -> DriveItem {
        locked {
            if let item = nodes[path] { return item }
            let item = DriveItem(path: path, identifier: FSItem.Identifier(rawValue: nextID)!)
            nextID += 1; nodes[path] = item
            return item
        }
    }
    private func writable() throws { if locked({ readOnly }) { throw POSIXError(.EROFS) } }
    private func changed() { locked { generation &+= 1; listings.removeAll() } }
    private func attributes(_ entry: FileEntry, wanted: FSItem.GetAttributesRequest? = nil, engine: Engine? = nil) throws -> FSItem.Attributes {
        let result = FSItem.Attributes()
        result.type = entry.kind == .directory ? .directory : .file
        result.mode = entry.mode; result.uid = getuid(); result.gid = getgid()
        result.linkCount = 1
        // BSD flags aren't supported by this adapter; an unset property means
        // "missing", whereas zero explicitly reports no flags to FSKit.
        result.flags = 0
        result.size = UInt64(max(0, entry.size))
        if wanted == nil || wanted!.isAttributeWanted(.allocSize) {
            result.allocSize = UInt64(max(0, try (engine ?? storage()).allocatedLocalBytes(entry.path)))
        }
        result.fileID = node(entry.path).identifier
        let parent = entry.path == "/" ? "/" : (entry.path as NSString).deletingLastPathComponent
        result.parentID = entry.path == "/" ? .parentOfRoot : node(parent.isEmpty ? "/" : parent).identifier
        let seconds = entry.modifiedNanoseconds / 1_000_000_000
        let nanos = entry.modifiedNanoseconds % 1_000_000_000
        result.modifyTime = timespec(tv_sec: Int(seconds), tv_nsec: Int(max(0, nanos)))
        result.changeTime = result.modifyTime
        // The backend's recorded atime is preserved on this noatime mount.
        // Legacy cache/native responses may lack it; only those use mtime as
        // an explicit compatibility fallback for FSKit's mandatory attribute.
        let accessed = entry.accessedNanoseconds ?? entry.modifiedNanoseconds
        var accessSeconds = accessed / 1_000_000_000
        var accessNanos = accessed % 1_000_000_000
        if accessNanos < 0 { accessSeconds -= 1; accessNanos += 1_000_000_000 }
        result.accessTime = timespec(tv_sec: Int(accessSeconds), tv_nsec: Int(accessNanos))
        return result
    }

    func activate(options: FSTaskOptions, replyHandler: @escaping (FSItem?, Error?) -> Void) {
        activate(taskOptions: options.taskOptions, replyHandler: replyHandler)
    }

    // Keep the exact activation path testable without inventing FSTaskOptions,
    // whose initializer is unavailable outside FSKit.
    func activate(taskOptions: [String], replyHandler: @escaping (FSItem?, Error?) -> Void) {
        queue.async { [self] in
            do {
                let mount = try FinderMountResource(stateRoot: self.stateRoot, requestedProfile: selectedProfile(taskOptions) ?? self.locked({ self.profileName }))
                guard mount.identifier == self.volumeID.uuid else {
                    throw DriveError(EINVAL, "The Finder profile changed after loading. Unload this resource and mount the intended profile again.")
                }
                let selected = mount.profile.name
                let previous = self.locked { () -> DispatchSourceTimer? in
                    defer { self.uploader = nil; self.profileName = selected }
                    return self.uploader
                }
                previous?.cancel()
                let opened = try self.openEngine(mount.profile, self.stateRoot)
                _ = try opened.stat("/")
                let capacity: VolumeCapacity?, capacityUnknown: Bool
                do { capacity = try opened.capacity(); capacityUnknown = false } catch { capacity = nil; capacityUnknown = true }
                let readOnly = self.locked { () -> Bool in
                    self.engine = opened
                    self.reportsCapacity = capacity != nil; self.capacity = capacity; self.capacityUnknown = capacityUnknown
                    self.ioSize = mount.profile.blockSize
                    if self.nodes["/"] == nil {
                        self.nextID = 3
                        self.nodes["/"] = DriveItem(path: "/", identifier: .rootDirectory)
                    }
                    self.readOnly = self.readOnly || taskOptions.contains("--rdonly")
                    return self.readOnly
                }
                self.name = FSFileName(string: mount.profile.finderName)
                self.uploadQueue.async { self.capacityRefreshedAt = DispatchTime.now().uptimeNanoseconds }
                let timer = DispatchSource.makeTimerSource(queue: self.uploadQueue)
                timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(250))
                timer.setEventHandler { [weak self, opened] in
                    // The captured engine outlives any in-flight publication. Only
                    // closed files idle for 2 s (open ones after 30 s) upload, unless
                    // the journal is half full.
                    if !readOnly {
                        let records = try? opened.flushUploads(policy: .background) { self?.isOpenForWriting($0) ?? false }
                        self?.logUploads(records)
                    }
                    self?.refreshCapacityIfDue(opened)
                    if !readOnly { self?.backupIndexIfDue(opened) }
                    self?.recheckOwnerIfDue(opened)
                }
                self.locked { self.uploader = timer }
                timer.resume()
                self.setActive(true)
                replyHandler(self.locked { self.nodes["/"] }, nil)
            } catch { replyHandler(nil, filesystemError(error)) }
        }
    }
    func deactivate(options: FSDeactivateOptions, replyHandler: @escaping (Error?) -> Void) {
        queue.async {
            let timer = self.locked { () -> DispatchSourceTimer? in
                defer {
                    self.uploader = nil; self.engine = nil
                    self.listings.removeAll(); self.nodes.removeAll(); self.openModes.removeAll()
                    self.reportsCapacity = false; self.capacity = nil; self.capacityUnknown = false
                }
                return self.uploader
            }
            timer?.cancel()
            self.setActive(false)
            replyHandler(nil)
        }
    }
    /// Runs on uploadQueue: refreshes a reported capacity every 60 s, and retries one that failed at
    /// activation until the backend answers. A backend that answers nil reports no capacity.
    private func refreshCapacityIfDue(_ opened: Engine) {
        let uptime = DispatchTime.now().uptimeNanoseconds
        guard locked({ reportsCapacity || capacityUnknown }), uptime &- capacityRefreshedAt >= capacityRefreshNanoseconds else { return }
        capacityRefreshedAt = uptime
        let value: VolumeCapacity?
        do { value = try opened.capacity() } catch { return }
        locked {
            capacityUnknown = false
            if let value { capacity = value; reportsCapacity = true }
        }
    }
    /// Runs on uploadQueue: every 30 s asks the engine whether the drive's index needs backing
    /// up into its storage, and does it on indexQueue. Only drives whose index lives on this
    /// Mac ever back up; the engine stops asking storage for the others.
    private func backupIndexIfDue(_ opened: Engine) {
        let uptime = DispatchTime.now().uptimeNanoseconds
        guard uptime &- indexCheckedAt >= indexCheckNanoseconds else { return }
        indexCheckedAt = uptime
        let policy = indexBackupPolicy
        indexQueue.async {
            do { if try opened.backupIndexIfDue(policy: policy) { Self.indexLog.notice("Index backed up") } }
            catch { Self.indexLog.error("Index backup failed errno=\((error as? DriveError)?.code ?? EIO)") }
        }
    }
    /// Runs on uploadQueue: every 5 minutes reads the drive's owner record, so a takeover by
    /// another Mac shows in ParaAir (read-only on this Mac) before anyone tries to save.
    private func recheckOwnerIfDue(_ opened: Engine) {
        let uptime = DispatchTime.now().uptimeNanoseconds
        guard uptime &- ownerCheckedAt >= ownerCheckNanoseconds else { return }
        ownerCheckedAt = uptime
        indexQueue.async { _ = try? opened.ownedElsewhere(refresh: true) }
    }
    /// Runs on uploadQueue. Logs only when a count changes, without paths.
    private func logUploads(_ records: [UploadRecord]?) {
        guard let records else { return }
        let paths = Set(records.map(\.path))
        let counts = UploadCounts(published: uploadPaths.subtracting(paths).count, remaining: records.count,
                                  blocked: records.filter { $0.state != "conflict" && $0.lastErrno != nil }.count,
                                  conflicts: records.filter { $0.state == "conflict" }.count)
        uploadPaths = paths
        guard counts != uploadCounts else { return }
        uploadCounts = counts
        Self.uploadLog.notice("Uploads published=\(counts.published) remaining=\(counts.remaining) blocked=\(counts.blocked) conflicts=\(counts.conflicts)")
    }
    func mount(options: FSTaskOptions, replyHandler: @escaping (Error?) -> Void) { replyHandler(nil) }
    func unmount(replyHandler: @escaping () -> Void) { replyHandler() }
    func synchronize(flags: FSSyncFlags, replyHandler: @escaping (Error?) -> Void) {
        // A barrier on the serial queue, so writes queued before this sync are
        // journaled first. The upload runs on uploadQueue: lookups, reads and other
        // writes keep flowing while it is in flight.
        queue.async {
            let opened: Engine
            do {
                if self.locked({ self.readOnly }) { replyHandler(nil); return }
                opened = try self.storage()
            } catch { replyHandler(filesystemError(error)); return }
            if flags == .noWait {
                // Starts the regular pass early; files still being written keep waiting.
                self.uploadQueue.async {
                    let records = try? opened.flushUploads(policy: .background) { self.isOpenForWriting($0) }
                    self.logUploads(records)
                }
                replyHandler(nil)
                return
            }
            self.uploadQueue.async {
                do {
                    let pending = try opened.flushUploads(policy: .immediate)
                    self.logUploads(pending)
                    guard pending.isEmpty else { throw DriveError(EIO, "Pending uploads remain; inspect paraair uploads") }
                    replyHandler(nil)
                } catch { replyHandler(filesystemError(error)) }
            }
        }
    }
    func reclaimItem(_ item: FSItem, replyHandler: @escaping (Error?) -> Void) {
        // Keep only lightweight identity until unmount; a later lookup must return
        // the same identifier as enumeration. No file contents live in FSItem.
        replyHandler(nil)
    }
    func lookupItem(named name: FSFileName, inDirectory directory: FSItem,
                    replyHandler: @escaping (FSItem?, FSFileName?, Error?) -> Void) {
        queue.async {
            do {
                let path: String
                if name.string == "." { path = try self.path(directory) }
                else if name.string == ".." {
                    let current = try self.path(directory)
                    path = current == "/" ? "/" : (current as NSString).deletingLastPathComponent
                } else { path = try self.child(name, in: directory) }
                let entry = try self.storage().stat(path)
                replyHandler(self.node(path), FSFileName(string: entry.name), nil)
            } catch { replyHandler(nil, nil, filesystemError(error)) }
        }
    }
    func createItem(named name: FSFileName, type: FSItem.ItemType, inDirectory directory: FSItem,
                    attributes: FSItem.SetAttributesRequest,
                    replyHandler: @escaping (FSItem?, FSFileName?, Error?) -> Void) {
        queue.async {
            do {
                try self.writable()
                guard type == .file || type == .directory else { throw POSIXError(.ENOTSUP) }
                if type == .file, attributes.isValid(.size), attributes.size > UInt64(Int64.max) {
                    throw POSIXError(.EFBIG)
                }
                let path = try self.child(name, in: directory)
                let entry = try self.storage().create(path, directory: type == .directory)
                if type == .file, attributes.isValid(.size) {
                    try self.storage().truncate(path, size: Int64(attributes.size))
                    attributes.consumedAttributes.insert(.size)
                }
                self.changed()
                replyHandler(self.node(path), FSFileName(string: entry.name), nil)
            } catch { replyHandler(nil, nil, filesystemError(error)) }
        }
    }
    func createSymbolicLink(named name: FSFileName, inDirectory directory: FSItem,
                            attributes: FSItem.SetAttributesRequest, linkContents: FSFileName,
                            replyHandler: @escaping (FSItem?, FSFileName?, Error?) -> Void) {
        replyHandler(nil, nil, POSIXError(.ENOTSUP))
    }
    func createLink(to item: FSItem, named name: FSFileName, inDirectory directory: FSItem,
                    replyHandler: @escaping (FSFileName?, Error?) -> Void) {
        replyHandler(nil, POSIXError(.ENOTSUP))
    }
    func readSymbolicLink(_ item: FSItem, replyHandler: @escaping (FSFileName?, Error?) -> Void) {
        replyHandler(nil, POSIXError(.ENOTSUP))
    }
    func renameItem(_ item: FSItem, inDirectory sourceDirectory: FSItem, named sourceName: FSFileName,
                    to destinationName: FSFileName, inDirectory destinationDirectory: FSItem,
                    overItem: FSItem?, replyHandler: @escaping (FSFileName?, Error?) -> Void) {
        queue.async {
            do {
                try self.writable()
                let source = try self.path(item), destination = try self.child(destinationName, in: destinationDirectory)
                let change = self.beginChange(from: source, to: destination)
                do { try self.storage().move(source, to: destination) } catch { self.abandonChange(change); throw error }
                if source == destination { self.abandonChange(change); replyHandler(destinationName, nil); return }
                self.locked {
                    // References to the overwritten destination must never access the
                    // replacement. FSKit can still hold them until reclaimItem.
                    (overItem as? DriveItem)?.deleted = true
                    let replaced = self.nodes.filter { $0.key == destination || $0.key.hasPrefix(destination + "/") }
                    for (key, stale) in replaced {
                        stale.deleted = true
                        self.nodes.removeValue(forKey: key)
                    }
                    // The backend rename is atomic. Move live descendants' identities too.
                    let moved = self.nodes.filter { $0.key == source || $0.key.hasPrefix(source + "/") }
                    for key in moved.keys { self.nodes.removeValue(forKey: key) }
                    for (old, node) in moved {
                        let new = destination + old.dropFirst(source.count)
                        node.path = new; self.nodes[new] = node
                    }
                    self.moveOpenModes(from: destination, to: nil)
                    self.moveOpenModes(from: source, to: destination)
                    self.changed()
                    self.namespaceGeneration &+= 1; self.inFlightChanges[change] = nil
                }
                replyHandler(destinationName, nil)
            } catch { replyHandler(nil, filesystemError(error)) }
        }
    }
    func removeItem(_ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem,
                    replyHandler: @escaping (Error?) -> Void) {
        queue.async {
            do {
                try self.writable()
                let path = try self.path(item), entry = try self.storage().stat(path)
                let change = self.beginChange(from: path, to: nil)
                do { try self.storage().remove(path, directory: entry.kind == .directory) } catch { self.abandonChange(change); throw error }
                self.locked {
                    (item as? DriveItem)?.deleted = true
                    let removed = self.nodes.filter { $0.key == path || $0.key.hasPrefix(path + "/") }
                    for (key, stale) in removed { stale.deleted = true; self.nodes.removeValue(forKey: key) }
                    self.moveOpenModes(from: path, to: nil)
                    self.changed()
                    self.namespaceGeneration &+= 1; self.inFlightChanges[change] = nil
                }
                replyHandler(nil)
            } catch { replyHandler(filesystemError(error)) }
        }
    }
    func getAttributes(_ desired: FSItem.GetAttributesRequest, of item: FSItem,
                       replyHandler: @escaping (FSItem.Attributes?, Error?) -> Void) {
        concurrently(item, { path, engine in try self.attributes(engine.stat(path), wanted: desired, engine: engine) }, reply: { result in
            switch result {
            case .success(let attributes): replyHandler(attributes, nil)
            case .failure(let error): replyHandler(nil, filesystemError(error))
            }
        }, serial: {
            do { replyHandler(try self.attributes(self.storage().stat(self.path(item)), wanted: desired), nil) }
            catch { replyHandler(nil, filesystemError(error)) }
        })
    }
    func setAttributes(_ newAttributes: FSItem.SetAttributesRequest, on item: FSItem,
                       replyHandler: @escaping (FSItem.Attributes?, Error?) -> Void) {
        queue.async {
            do {
                try self.writable()
                let path = try self.path(item)
                if newAttributes.isValid(.size), try self.storage().stat(path).kind == .file {
                    guard newAttributes.size <= UInt64(Int64.max) else { throw POSIXError(.EFBIG) }
                    try self.storage().truncate(path, size: Int64(newAttributes.size))
                    newAttributes.consumedAttributes.insert(.size)
                    self.changed()
                }
                // Unsupported metadata remains unconsumed, as required by FSKit.
                replyHandler(try self.attributes(self.storage().stat(path)), nil)
            } catch { replyHandler(nil, filesystemError(error)) }
        }
    }
    func enumerateDirectory(_ directory: FSItem, startingAt cookie: FSDirectoryCookie,
                            verifier: FSDirectoryVerifier, attributes requested: FSItem.GetAttributesRequest?,
                            packer: FSDirectoryEntryPacker,
                            replyHandler: @escaping (FSDirectoryVerifier, Error?) -> Void) {
        queue.async {
            do {
                let path = try self.path(directory)
                let snapshotKey = path + (requested == nil ? "#names" : "#attributes")
                if cookie.rawValue == 0 {
                    var entries = try self.storage().list(path).map { ($0.name, $0) }
                    if requested == nil {
                        let parent = path == "/" ? "/" : (path as NSString).deletingLastPathComponent
                        entries.insert(("..", try self.storage().stat(parent)), at: 0)
                        entries.insert((".", try self.storage().stat(path)), at: 0)
                    }
                    self.locked {
                        self.generation &+= 1
                        // Bound abandoned enumeration snapshots without loading file bytes.
                        if self.listings.count >= 128 { self.listings.removeAll() }
                        self.listings[snapshotKey] = Listing(generation: self.generation, entries: entries)
                    }
                }
                guard let listing = self.locked({ self.listings[snapshotKey] }),
                      cookie.rawValue <= UInt64(listing.entries.count),
                      cookie.rawValue == 0 || verifier.rawValue == listing.generation else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(FSError.Code.invalidDirectoryCookie.rawValue))
                }
                for index in Int(cookie.rawValue)..<listing.entries.count {
                    let (name, entry) = listing.entries[index]
                    let packed = packer.packEntry(name: FSFileName(string: name),
                        itemType: entry.kind == .directory ? .directory : .file,
                        itemID: self.node(entry.path).identifier,
                        nextCookie: FSDirectoryCookie(rawValue: UInt64(index + 1)),
                        attributes: requested == nil ? nil : try self.attributes(entry, wanted: requested))
                    if !packed { break }
                }
                replyHandler(FSDirectoryVerifier(rawValue: listing.generation), nil)
            } catch { replyHandler(verifier, filesystemError(error)) }
        }
    }
    func openItem(_ item: FSItem, modes: FSVolume.OpenModes, replyHandler: @escaping (Error?) -> Void) {
        queue.async {
            do {
                let path = try self.path(item)
                _ = try self.storage().stat(path)
                self.locked { self.openModes[path, default: []].formUnion(modes) }
                replyHandler(nil)
            } catch { replyHandler(filesystemError(error)) }
        }
    }
    func closeItem(_ item: FSItem, modes: FSVolume.OpenModes, replyHandler: @escaping (Error?) -> Void) {
        // FSKit passes the modes still open after this close. Every write already has
        // a durable journal record; the uploader publishes the file once it is closed
        // and idle. fsync/synchronize are the explicit remote durability boundary.
        queue.async {
            if let path = try? self.path(item) { self.locked { self.openModes[path] = modes.isEmpty ? nil : modes } }
            replyHandler(nil)
        }
    }
    func read(from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer,
              replyHandler: @escaping (Int, Error?) -> Void) {
        read(from: item, at: offset, length: length, into: buffer as ReadDestination, replyHandler: replyHandler)
    }
    func read(from item: FSItem, at offset: off_t, length: Int, into destination: ReadDestination,
              replyHandler: @escaping (Int, Error?) -> Void) {
        guard offset >= 0, length >= 0, offset <= Int64.max - Int64(length) else { replyHandler(0, POSIXError(.EINVAL)); return }
        // A partial copy is reported with its byte count, as a short read.
        var copied = 0
        concurrently(item, { path, engine in try self.copy(path, engine: engine, offset: offset, length: length, into: destination, copied: &copied) },
                     reply: { result in
            switch result {
            case .success(let count): replyHandler(count, nil)
            case .failure(let error): replyHandler(copied, filesystemError(error))
            }
        }, serial: {
            var completed = 0
            do {
                let path = try self.path(item)
                replyHandler(try self.copy(path, engine: self.storage(), offset: offset, length: length, into: destination, copied: &completed), nil)
            } catch { replyHandler(completed, filesystemError(error)) }
        })
    }
    /// Copies up to `length` bytes in 8 MiB engine reads; `copied` tracks progress for errors.
    private func copy(_ path: String, engine: Engine, offset: Int64, length: Int, into destination: ReadDestination, copied: inout Int) throws -> Int {
        copied = 0
        var completed = 0
        defer { copied = completed }
        try destination.withBytes { output in
            guard length <= output.count else { throw POSIXError(.EINVAL) }
            while completed < length {
                let requested = min(length - completed, 8 * 1024 * 1024)
                let data = try engine.read(path, offset: offset + Int64(completed), length: requested)
                guard data.count <= requested else { throw POSIXError(.EIO) }
                let target = UnsafeMutableRawBufferPointer(rebasing: output[completed..<(completed + data.count)])
                _ = data.copyBytes(to: target.bindMemory(to: UInt8.self))
                completed += data.count
                if data.count < requested { break }
            }
        }
        return completed
    }
    func write(contents: Data, to item: FSItem, at offset: off_t,
               replyHandler: @escaping (Int, Error?) -> Void) {
        queue.async {
            var completed = 0
            defer { if completed > 0 { self.changed() } }
            do {
                try self.writable()
                guard offset >= 0, offset <= Int64.max - Int64(contents.count) else { throw POSIXError(.EINVAL) }
                let path = try self.path(item)
                while completed < contents.count {
                    let length = min(contents.count - completed, 8 * 1024 * 1024)
                    let data = contents.subdata(in: completed..<(completed + length))
                    let wrote = try self.storage().write(path, offset: offset + Int64(completed), data: data)
                    guard wrote > 0, wrote <= length else { throw POSIXError(.EIO) }
                    completed += wrote
                }
                replyHandler(completed, nil)
            } catch { replyHandler(completed, filesystemError(error)) }
        }
    }
}
