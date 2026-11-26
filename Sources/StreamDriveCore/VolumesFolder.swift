import Foundation

// Shared by the app and ParaAir's small root helper (ParaAirVolumes), which is compiled from this file and its own
// main.swift only. Keep it free of other StreamDriveCore types.

/// The root helper's XPC interface. Its only job: on macOS 26, where an app can't use FSKit's own mount
/// (`FSClient.mountSingleVolume`, macOS 27), make the drive's folder directly in /Volumes and give it to the user, who
/// then mounts there as themselves (FSKit mounts must not run as root). macFUSE's FSKit backend does the same.
@objc public protocol ParaAirVolumesService {
    /// Makes (or reuses) /Volumes/<name> for the calling user. Replies with the path, or an errno and a message.
    func prepareMountPoint(_ name: String, reply: @escaping (String?, Int32, String?) -> Void)
    /// Removes /Volumes/<name> when it is the calling user's empty folder with nothing mounted on it.
    func removeMountPoint(_ name: String, reply: @escaping (Int32, String?) -> Void)
}

public struct VolumesFolderError: Error, LocalizedError, Equatable {
    public let code: Int32
    public let message: String
    public init(_ code: Int32, _ message: String) { self.code = code; self.message = message }
    public var errorDescription: String? { message }
}

/// Folders directly in /Volumes that ParaAir mounts drives on. Every rule here runs as root in the helper, so it accepts
/// only one plain path component, never follows a symbolic link, and never touches a folder something is mounted on or
/// that belongs to someone else.
public enum VolumesFolder {
    public static let volumes = "/Volumes"

    /// One path component that isn't hidden, has no separators or control characters, and fits a file name.
    public static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 200, !name.hasPrefix("."), name != "..",
              !name.contains("/"), !name.contains(":") else { return false }
        return !name.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    /// A folder name for a drive's Finder name: separators become dashes, leading dots go, and it is shortened to fit.
    public static func folderName(for finderName: String) -> String {
        var name = String(finderName.unicodeScalars.map { scalar -> Character in
            if scalar == "/" || scalar == ":" { return "-" }
            if scalar.value < 0x20 || scalar.value == 0x7F { return " " }
            return Character(scalar)
        }).trimmingCharacters(in: .whitespaces)
        while name.hasPrefix(".") { name.removeFirst() }
        while name.utf8.count > 190 { name.removeLast() }
        return name.isEmpty ? "ParaAir" : name
    }

    /// Names to try, in order: the drive's own, then "<name> 2" … "<name> 9" when another volume already has it.
    public static func candidates(for finderName: String) -> [String] {
        let base = folderName(for: finderName)
        return [base] + (2...9).map { "\(base) \($0)" }
    }

    /// Makes `<root>/<name>` owned by `uid`:`gid` (0755), or reuses it when it already is that user's empty folder with
    /// nothing mounted on it. Anything else at that name is refused with EEXIST, so the caller can try the next name.
    @discardableResult
    public static func prepare(name: String, uid: uid_t, gid: gid_t, root: String = volumes) throws -> String {
        guard isValidName(name) else { throw VolumesFolderError(EINVAL, "“\(name)” can’t be a folder name in \(root).") }
        let path = root + "/" + name
        if mkdir(path, 0o755) == 0 {
            guard chown(path, uid, gid) == 0 else {
                let code = errno
                rmdir(path)
                throw VolumesFolderError(code, "Couldn’t give \(path) to the user (\(String(cString: strerror(code)))).")
            }
            return path
        }
        let code = errno
        guard code == EEXIST else {
            throw VolumesFolderError(code, "Couldn’t make \(path) (\(String(cString: strerror(code)))).")
        }
        try requireReusable(path, uid: uid, root: root)
        return path
    }

    /// Removes `<root>/<name>` only when it is `uid`'s empty folder with nothing mounted on it.
    public static func remove(name: String, uid: uid_t, root: String = volumes) throws {
        guard isValidName(name) else { throw VolumesFolderError(EINVAL, "“\(name)” can’t be a folder name in \(root).") }
        let path = root + "/" + name
        try requireReusable(path, uid: uid, root: root)
        guard rmdir(path) == 0 else {
            let code = errno
            throw VolumesFolderError(code, "Couldn’t remove \(path) (\(String(cString: strerror(code)))).")
        }
    }

    /// A real folder (not a link), owned by `uid`, on the same device as `root` (so nothing is mounted on it), and empty.
    private static func requireReusable(_ path: String, uid: uid_t, root: String) throws {
        var folder = stat(), parent = stat()
        guard lstat(path, &folder) == 0, lstat(root, &parent) == 0 else {
            throw VolumesFolderError(errno, "Couldn’t read \(path).")
        }
        guard folder.st_mode & S_IFMT == S_IFDIR, folder.st_uid == uid, folder.st_dev == parent.st_dev else {
            throw VolumesFolderError(EEXIST, "\(path) is already in use.")
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path), entries.isEmpty else {
            throw VolumesFolderError(EEXIST, "\(path) isn’t empty.")
        }
    }
}
