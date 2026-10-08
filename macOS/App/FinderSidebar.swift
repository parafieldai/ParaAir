import AppKit
import CFinderSidebar
import CoreServices
import CryptoKit
import Darwin
import StreamDriveCore

/// Best-effort Favorites integration using Apple's public legacy API. The API
/// is deprecated with "No longer supported" in SDK 27, and Finder controls the
/// visibility of its sidebar. A failed registration always has a manual route:
/// open the mounted volume and drag its icon into Favorites.
/// https://developer.apple.com/documentation/coreservices/klssharedfilelistfavoriteitems
/// https://support.apple.com/guide/mac-help/customize-the-finder-sidebar-on-mac-mchl83c9e8b8/mac
@MainActor
final class FinderSidebar {
    enum RegistrationResult: Equatable {
        case added
        case alreadyPresent
        case automaticPreviouslyAttempted
        case notMounted
        case manualRequired(String)
    }

    private let stateRoot: URL
    private let defaults: UserDefaults

    init(stateRoot: URL, defaults: UserDefaults = .standard) {
        self.stateRoot = stateRoot.standardizedFileURL.resolvingSymlinksInPath()
        self.defaults = defaults
    }

    /// Successful automatic registration runs once per profile in this root. This
    /// marker belongs to the app, not Finder. Never reinsert a removed favorite
    /// during polling or later launches; an explicit Add action can try again.
    func registerMountedVolume(_ profile: DriveProfile,
                               automatically: Bool = true) -> RegistrationResult {
        guard let target = mountedURL(profile) else { return .notMounted }
        let key = registrationKey(profile)
        if automatically && defaults.bool(forKey: key) { return .automaticPreviouslyAttempted }
        let result = insertFavorite(target, profile: profile, refreshAppearance: !automatically)
        if result == .added || result == .alreadyPresent { defaults.set(true, forKey: key) }
        // The app lifecycle limits automatic attempts after transient failure;
        // a failure is not persisted as success and can be explicitly retried.
        return result
    }

    /// Opens only a verified mounted volume, never its empty host mount folder.
    @discardableResult
    func openMountedVolume(_ profile: DriveProfile) -> Bool {
        guard let target = mountedURL(profile) else { return false }
        return NSWorkspace.shared.open(target)
    }

    private func registrationKey(_ profile: DriveProfile) -> String {
        let identity = stateRoot.path + "\u{0}" + profile.name
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return "ParaAir.FinderSidebar.firstRegistration.v1." + digest
    }

    private func mountedURL(_ profile: DriveProfile) -> URL? {
        guard let path = profile.mountPoint, path.hasPrefix("/"), path != "/" else { return nil }
        let target = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        var entries: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&entries, MNT_NOWAIT)
        guard count > 0, let entries else { return nil }
        for index in 0..<Int(count) {
            var entry = entries[index]
            let type = withUnsafePointer(to: &entry.f_fstypename) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
            }
            guard type == "paraair" || type == "streamdrive" else { continue }
            let mount = withUnsafePointer(to: &entry.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if URL(fileURLWithPath: mount, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath() == target {
                return target
            }
        }
        return nil
    }

    private func insertFavorite(_ target: URL, profile: DriveProfile, refreshAppearance: Bool) -> RegistrationResult {
        // Some FSKit mounts are readable but cannot round-trip a Foundation
        // bookmark. Inserting them anyway leaves a broken Finder favorite.
        // Check first; never persist bookmark data or record failure as success.
        guard Self.hasResolvableBookmark(target) else {
            return .manualRequired("ParaAir is mounted at " + target.path + ". Finder couldn’t create a usable saved shortcut for this volume. Use Open in Finder to access it.")
        }
        guard let list = LSSharedFileListCreate(nil, kLSSharedFileListFavoriteItems.takeUnretainedValue(), nil)?.takeRetainedValue(),
              let snapshot = LSSharedFileListCopySnapshot(list, nil)?.takeRetainedValue() else {
            return .manualRequired(Self.manualInstructions)
        }
        let flags = UInt32(kLSSharedFileListNoUserInteraction | kLSSharedFileListDoNotMountVolumes)
        guard let items = snapshot as? [LSSharedFileListItem], items.count <= 4096 else {
            return .manualRequired(Self.manualInstructions)
        }
        for item in items {
            guard let resolved = LSSharedFileListItemCopyResolvedURL(item, flags, nil)?.takeRetainedValue() else { continue }
            let url = resolved as URL
            // The header specifies that sandboxed callers may receive a
            // security-scoped extension; balance it even though this host app
            // is currently unsandboxed. Resolution never mounts or prompts.
            defer { url.stopAccessingSecurityScopedResource() }
            if url.isFileURL && url.standardizedFileURL == target {
                if !refreshAppearance { return .alreadyPresent }
                break
            }
        }
        let iconData = try? DriveAppearance(stateRoot: stateRoot).iconData(profile)
        var itemID: UInt32 = 0
        guard ParaAirInsertFinderFavorite(list, target as CFURL, profile.finderName as CFString, iconData as CFData?, &itemID) else {
            return .manualRequired(Self.manualInstructions)
        }
        // Confirm the public list changed; a nonnil insert result alone does
        // not guarantee Finder accepted or displayed the favorite.
        guard let updated = LSSharedFileListCopySnapshot(list, nil)?.takeRetainedValue(),
              let updatedItems = updated as? [LSSharedFileListItem], updatedItems.count <= 4096 else {
            return .manualRequired(Self.manualInstructions)
        }
        for item in updatedItems {
            guard let resolved = LSSharedFileListItemCopyResolvedURL(item, flags, nil)?.takeRetainedValue() else { continue }
            let url = resolved as URL
            defer { url.stopAccessingSecurityScopedResource() }
            if url.isFileURL && url.standardizedFileURL == target { return .added }
        }
        return .manualRequired(Self.manualInstructions)
    }

    static func hasResolvableBookmark(_ target: URL) -> Bool {
        do {
            let data = try target.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            var stale = false
            let resolved = try URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                                   relativeTo: nil, bookmarkDataIsStale: &stale)
            defer { resolved.stopAccessingSecurityScopedResource() }
            return !stale && resolved.standardizedFileURL == target.standardizedFileURL
        } catch { return false }
    }

    private static let manualInstructions = "Finder could not register the favorite automatically. Open the mounted drive, then drag its icon into Finder’s Favorites. If Favorites or Locations are hidden, check Finder → Settings → Sidebar."
}
