import Foundation
import DiskArbitration
import StreamDriveCore
import Darwin

/// Native FSKit mounts belong to macOS's mount service. Disk Arbitration can
/// unmount them for the user where a direct unmount(2)/umount call is denied.
enum VolumeUnmount {
    static func unmount(_ path: String, timeout: TimeInterval = 30) throws {
        guard let session = DASessionCreate(nil),
              let disk = DADiskCreateFromVolumePath(nil, session, URL(fileURLWithPath: path) as CFURL) else {
            throw DriveError(ENODEV, "macOS did not recognize this mounted volume")
        }
        let completion = Completion(session: session)
        DASessionSetDispatchQueue(session, DispatchQueue(label: "dev.paraair.unmount"))
        // The callback owns this reference. It also keeps the session alive if
        // the bounded wait expires, so a late reply cannot use freed memory.
        let context = Unmanaged.passRetained(completion).toOpaque()
        DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionDefault), { _, dissenter, context in
            guard let context else { return }
            let completion = Unmanaged<Completion>.fromOpaque(context).takeRetainedValue()
            completion.finish(dissenter.map { DADissenterGetStatus($0) })
        }, context)
        guard completion.done.wait(timeout: .now() + timeout) == .success else {
            throw DriveError(ETIMEDOUT, "macOS is still unmounting the drive. Check status before retrying; pending writes are retained.")
        }
        if let status = completion.status {
            if status == kDAReturnBusy {
                throw DriveError(EBUSY, "Close files using this drive and retry unmounting; pending writes are retained.")
            }
            throw DriveError(EIO, "macOS rejected unmounting (Disk Arbitration status \(status)); pending writes are retained.")
        }
    }

    private final class Completion {
        let session: DASession
        let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var failure: DAReturn?
        var status: DAReturn? { lock.lock(); defer { lock.unlock() }; return failure }
        init(session: DASession) { self.session = session }
        func finish(_ status: DAReturn?) {
            lock.lock(); failure = status; lock.unlock()
            done.signal()
        }
    }
}
