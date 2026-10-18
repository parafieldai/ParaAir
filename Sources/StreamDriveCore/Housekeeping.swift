import Foundation

/// Files macOS writes onto every volume it mounts, for its own use. Finder keeps view
/// settings in `.DS_Store`; extended attributes (quarantine, Finder tags, resource forks)
/// become AppleDouble companions named `._name`, because the volume has no native extended
/// attributes; fseventsd and Spotlight create `.fseventsd` and `.Spotlight-V100` at the root.
///
/// None of it belongs to the user, and two Macs writing it to one drive would conflict
/// constantly. So the engine keeps local-only files on this Mac (they live in the journal
/// and never upload), refuses the root system folders (macOS works without them; live
/// FSEvents still reach Finder), and hides copies of either that are already in storage.
/// Paths are classified by name, so nothing extra is persisted.
public enum Housekeeping {
    /// Created and deleted in a folder to make Finder re-read it. Local only, so it never
    /// reaches storage.
    public static let refreshName = ".paraair-refresh"
    static let refusedRootFolders: Set<String> = [".fseventsd", ".Spotlight-V100"]

    /// A file name kept on this Mac only, anywhere in the drive.
    public static func isLocalOnlyName(_ name: String) -> Bool {
        name == ".DS_Store" || name.hasPrefix("._") || name == refreshName
    }
    /// A canonical path whose last component is a local-only name.
    public static func isLocalOnly(_ path: String) -> Bool {
        path != "/" && isLocalOnlyName((path as NSString).lastPathComponent)
    }
    /// A refused root folder, or anything inside one.
    public static func isRefused(_ path: String) -> Bool {
        guard let first = path.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).first else { return false }
        return refusedRootFolders.contains(String(first))
    }
    /// Never sent to storage: local-only files and refused folders.
    public static func staysLocal(_ path: String) -> Bool { isLocalOnly(path) || isRefused(path) }
    /// A remote entry that listings hide.
    static func hides(_ entry: FileEntry) -> Bool { staysLocal(entry.path) }
}
