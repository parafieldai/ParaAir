import Foundation

/// Whether this process may create files in a drive's state folder.
///
/// On macOS 26, `mount -F` hands the file system extension a path resource whose `isWritable` is false, although the
/// security scope that comes with it does let the extension write the folder. The extension asks the file system
/// instead of trusting the flag, so the drive mounts read-write when it really can be written.
public enum StateRootAccess {
    /// Creates and removes an empty, uniquely named file in `folder`. Leaves nothing behind.
    public static func canCreateFiles(in folder: URL) -> Bool {
        let probe = folder.appendingPathComponent(".paraair-write-probe-\(UUID().uuidString)")
        let descriptor = open(probe.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return false }
        close(descriptor)
        unlink(probe.path)
        return true
    }
}
