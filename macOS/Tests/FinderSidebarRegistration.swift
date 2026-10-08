import Foundation
import CoreServices
import StreamDriveCore

/// Opt-in integration regression: inserts only the already mounted ParaAir
/// volume supplied by the operator. It never mounts or accesses credentials.
@main
struct FinderSidebarRegistrationTest {
    @MainActor
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            fatalError("Pass the ParaAir state root and an existing mounted volume")
        }
        let suite = "dev.paraair.tests.sidebar." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let sidebar = FinderSidebar(stateRoot: URL(fileURLWithPath: CommandLine.arguments[1]), defaults: defaults)
        let profile = DriveProfile(name: "ParaAir", backend: .local, mountPoint: CommandLine.arguments[2])
        func favoriteIDs() -> Set<UInt32> {
            guard let list = LSSharedFileListCreate(nil, kLSSharedFileListFavoriteItems.takeUnretainedValue(), nil)?.takeRetainedValue(),
                  let snapshot = LSSharedFileListCopySnapshot(list, nil)?.takeRetainedValue(),
                  let items = snapshot as? [LSSharedFileListItem] else { fatalError("Cannot inspect Finder favorites") }
            return Set(items.map { LSSharedFileListItemGetID($0) })
        }
        let target = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let bookmarkResolves = FinderSidebar.hasResolvableBookmark(target)
        let initialIDs = favoriteIDs()
        let first = sidebar.registerMountedVolume(profile)
        if case .manualRequired = first {
            guard sidebar.registerMountedVolume(profile) == first else {
                fatalError("Declined insertion was incorrectly remembered as success")
            }
            if !bookmarkResolves {
                guard favoriteIDs() == initialIDs else { fatalError("An unresolvable mount changed Finder favorites") }
            }
            print("Finder sidebar regression passed: declined insertion returned safely; retry retained; failed bookmark did not change favorites")
            return
        }
        guard first == .added || first == .alreadyPresent else {
            fatalError("Mounted volume registration failed: \(first)")
        }
        guard sidebar.registerMountedVolume(profile) == .automaticPreviouslyAttempted else {
            fatalError("Automatic registration did not remember success")
        }
        guard sidebar.registerMountedVolume(profile, automatically: false) == .alreadyPresent else {
            fatalError("Explicit registration duplicated the favorite")
        }
        print("Finder sidebar regression passed: \(first), persisted success, no duplicate")
    }
}
