import Foundation
import FSKit
import StreamDriveCore

/// Reviewable alternative to the legacy mount helper. Not called by the app or
/// test runner. Live use requires approved FSKit Mounter provisioning and a
/// separate decision for macOS's /Volumes mount location.
@available(macOS 27.0, *)
@MainActor
func proposedNativeMount(stateRoot: URL, profileName: String) async throws -> URL {
    try DriveProfile.validateName(profileName)
    guard stateRoot.isFileURL else { throw DriveError(EINVAL, "Use the saved local state directory") }
    let profiles = try ProfileStore(root: stateRoot).list()
    guard profiles.count == 1, profiles[0].name == profileName else {
        throw DriveError(EINVAL, "Native mounting requires the saved single-profile state directory")
    }
    let resource = FSPathURLResource(url: stateRoot.standardizedFileURL.resolvingSymlinksInPath(), writable: true)
    return try await withCheckedThrowingContinuation { continuation in
        FSClient.shared.mountSingleVolume(resource: resource,
            bundleID: "dev.streamdrive.app.filesystem",
            options: ["-o", "nosuid,nodev", "-p", profileName]) { path, error in
                if let error { continuation.resume(throwing: error) }
                else if let path, path.isFileURL, path.deletingLastPathComponent().path == "/Volumes" {
                    continuation.resume(returning: path)
                } else { continuation.resume(throwing: DriveError(EIO, "macOS did not return the expected volume location")) }
            }
    }
}
