import Foundation
import FSKit
import StreamDriveCore
import Darwin

final class DriveItem: FSItem {
    var path: String
    var deleted = false
    let identifier: FSItem.Identifier
    init(path: String, identifier: FSItem.Identifier) {
        self.path = path; self.identifier = identifier
        super.init()
    }
}

/// The serial queue keeps FSItem identity, directory cookies and path changes in
/// step with journal operations. The storage engine fetches bounded ranges only.
final class StreamDriveVolume: FSVolume, FSVolume.Operations, FSVolume.ReadWriteOperations,
                               FSVolume.OpenCloseOperations {
    private let queue = DispatchQueue(label: "dev.streamdrive.filesystem.io", qos: .userInitiated)
    private let uploadQueue = DispatchQueue(label: "dev.streamdrive.filesystem.upload", qos: .utility)
    private let stateRoot: URL
    private let setActive: (Bool) -> Void
    private var profileName: String?
    private var readOnly: Bool
    private var engine: Engine?
    private var uploader: DispatchSourceTimer?
    private var nodes: [String: DriveItem] = [:]
    private var nextID: UInt64 = 3
    private var generation: UInt64 = 1
    private struct Listing { var generation: UInt64; var entries: [(String, FileEntry)] }
    private var listings: [String: Listing] = [:]
    var isOpenCloseInhibited = false

    init(stateRoot: URL, mountResource: FinderMountResource, readOnly: Bool, engine: Engine? = nil, setActive: @escaping (Bool) -> Void) {
        self.engine = engine
        self.setActive = setActive
        self.stateRoot = stateRoot; self.profileName = mountResource.profile.name; self.readOnly = readOnly
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
        c.doesNotSupportVolumeSizes = true
        // The local journal is durable; it isn't a remote filesystem journal.
        c.supportsJournal = false
        return c
    }
    var volumeStatistics: FSStatFSResult {
        let s = FSStatFSResult(fileSystemTypeName: "streamdrive")
        s.blockSize = 4096; s.ioSize = 1024 * 1024
        // An S3 bucket has no trustworthy fixed capacity. Do not invent one.
        return s
    }

    private func storage() throws -> Engine {
        guard let engine else { throw POSIXError(.ENOTCONN) }
        return engine
    }
    private func path(_ item: FSItem) throws -> String {
        guard let node = item as? DriveItem else { throw POSIXError(.EINVAL) }
        guard !node.deleted else { throw POSIXError(.ESTALE) }
        return node.path
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
        if let item = nodes[path] { return item }
        let item = DriveItem(path: path, identifier: FSItem.Identifier(rawValue: nextID)!)
        nextID += 1; nodes[path] = item
        return item
    }
    private func writable() throws { if readOnly { throw POSIXError(.EROFS) } }
    private func changed() { generation &+= 1; listings.removeAll() }
    private func attributes(_ entry: FileEntry, wanted: FSItem.GetAttributesRequest? = nil) throws -> FSItem.Attributes {
        let result = FSItem.Attributes()
        result.type = entry.kind == .directory ? .directory : .file
        result.mode = entry.mode; result.uid = getuid(); result.gid = getgid()
        result.linkCount = 1
        // BSD flags aren't supported by this adapter; an unset property means
        // "missing", whereas zero explicitly reports no flags to FSKit.
        result.flags = 0
        result.size = UInt64(max(0, entry.size))
        if wanted == nil || wanted!.isAttributeWanted(.allocSize) {
            result.allocSize = UInt64(max(0, try storage().allocatedLocalBytes(entry.path)))
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
                let mount = try FinderMountResource(stateRoot: self.stateRoot, requestedProfile: selectedProfile(taskOptions) ?? self.profileName)
                guard mount.identifier == self.volumeID.uuid else {
                    throw DriveError(EINVAL, "The Finder profile changed after loading. Unload this resource and mount the intended profile again.")
                }
                let selected = mount.profile.name
                self.uploader?.cancel(); self.uploader = nil
                self.profileName = selected
                let opened = try Engine.open(profile: mount.profile, stateRoot: self.stateRoot)
                _ = try opened.stat("/")
                self.engine = opened
                if self.nodes["/"] == nil {
                    self.nextID = 3
                    self.nodes["/"] = DriveItem(path: "/", identifier: .rootDirectory)
                }
                self.name = FSFileName(string: mount.profile.finderName)
                self.readOnly = self.readOnly || taskOptions.contains("--rdonly")
                if !self.readOnly {
                    let timer = DispatchSource.makeTimerSource(queue: self.uploadQueue)
                    timer.schedule(deadline: .now() + 2, repeating: 2)
                    timer.setEventHandler { [opened] in
                        // The captured engine outlives any in-flight publication; the
                        // upload queue never reads mutable volume state.
                        _ = try? opened.flushUploads()
                    }
                    self.uploader = timer; timer.resume()
                }
                self.setActive(true)
                replyHandler(self.nodes["/"], nil)
            } catch { replyHandler(nil, filesystemError(error)) }
        }
    }
    func deactivate(options: FSDeactivateOptions, replyHandler: @escaping (Error?) -> Void) {
        queue.async {
            self.uploader?.cancel(); self.uploader = nil
            self.engine = nil; self.listings.removeAll(); self.nodes.removeAll()
            self.setActive(false)
            replyHandler(nil)
        }
    }
    func mount(options: FSTaskOptions, replyHandler: @escaping (Error?) -> Void) { replyHandler(nil) }
    func unmount(replyHandler: @escaping () -> Void) { replyHandler() }
    func synchronize(flags: FSSyncFlags, replyHandler: @escaping (Error?) -> Void) {
        queue.async {
            do {
                if self.readOnly { replyHandler(nil); return }
                let opened = try self.storage()
                if flags == .noWait {
                    self.uploadQueue.async { [opened] in _ = try? opened.flushUploads() }
                    replyHandler(nil)
                    return
                }
                let pending = try opened.flushUploads()
                guard pending.isEmpty else { throw DriveError(EIO, "Pending uploads remain; inspect paraair uploads") }
                replyHandler(nil)
            } catch { replyHandler(filesystemError(error)) }
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
                try self.storage().move(source, to: destination)
                if source == destination { replyHandler(destinationName, nil); return }
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
                self.changed()
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
                try self.storage().remove(path, directory: entry.kind == .directory)
                (item as? DriveItem)?.deleted = true
                let removed = self.nodes.filter { $0.key == path || $0.key.hasPrefix(path + "/") }
                for (key, stale) in removed { stale.deleted = true; self.nodes.removeValue(forKey: key) }
                self.changed()
                replyHandler(nil)
            } catch { replyHandler(filesystemError(error)) }
        }
    }
    func getAttributes(_ desired: FSItem.GetAttributesRequest, of item: FSItem,
                       replyHandler: @escaping (FSItem.Attributes?, Error?) -> Void) {
        queue.async {
            do { replyHandler(try self.attributes(self.storage().stat(self.path(item)), wanted: desired), nil) }
            catch { replyHandler(nil, filesystemError(error)) }
        }
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
                    self.generation &+= 1
                    // Bound abandoned enumeration snapshots without loading file bytes.
                    if self.listings.count >= 128 { self.listings.removeAll() }
                    self.listings[snapshotKey] = Listing(generation: self.generation, entries: entries)
                }
                guard let listing = self.listings[snapshotKey],
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
            do { _ = try self.storage().stat(self.path(item)); replyHandler(nil) }
            catch { replyHandler(filesystemError(error)) }
        }
    }
    func closeItem(_ item: FSItem, modes: FSVolume.OpenModes, replyHandler: @escaping (Error?) -> Void) {
        // Every write already has a durable journal record. Uploading is asynchronous;
        // fsync/synchronize are the explicit remote durability boundary.
        replyHandler(nil)
    }
    func read(from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer,
              replyHandler: @escaping (Int, Error?) -> Void) {
        queue.async {
            var completed = 0
            do {
                guard offset >= 0, length >= 0, offset <= Int64.max - Int64(length) else { throw POSIXError(.EINVAL) }
                let path = try self.path(item)
                try buffer.withUnsafeMutableBytes { output in
                    guard length <= output.count else { throw POSIXError(.EINVAL) }
                    while completed < length {
                        let requested = min(length - completed, 8 * 1024 * 1024)
                        let data = try self.storage().read(path, offset: offset + Int64(completed), length: requested)
                        guard data.count <= requested else { throw POSIXError(.EIO) }
                        let destination = UnsafeMutableRawBufferPointer(rebasing: output[completed..<(completed + data.count)])
                        _ = data.copyBytes(to: destination.bindMemory(to: UInt8.self))
                        completed += data.count
                        if data.count < requested { break }
                    }
                }
                replyHandler(completed, nil)
            } catch { replyHandler(completed, filesystemError(error)) }
        }
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
