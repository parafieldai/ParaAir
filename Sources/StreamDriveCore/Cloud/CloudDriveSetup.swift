import Foundation
import Darwin

/// Creates or attaches the one ParaAir Cloud drive of a state folder.
public enum CloudDriveSetup {
    public static let blockSize = 4_194_304
    public static let defaultFinderName = "ParaAir Cloud"
    static let pendingFile = "cloud-pending-drive.json"

    /// `<home>/Library/Application Support/ParaAir/Cloud Drives/<accountID>/`
    public static func defaultStateRoot(accountID: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        cloudDrivesFolder(home: home).appendingPathComponent(accountID, isDirectory: true)
    }
    /// `<home>/Library/Application Support/ParaAir/Cloud Drives`: the app's sign-ins and the CLI's extra drives make
    /// their state folders here.
    public static func cloudDrivesFolder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/ParaAir/Cloud Drives", isDirectory: true)
    }

    /// A new, empty state folder for one more drive of `account`, signed in in another folder: `Cloud Drives/<uuid>/`
    /// with a copy of the account's public record (CloudAccountStore.share), so the folder needs no sign-in of its own.
    /// The folder is removed again if the record can't be saved.
    public static func newStateRoot(sharing account: CloudAccount, vault: any ConnectionVault,
                                    home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL {
        let parent = cloudDrivesFolder(home: home)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let root = parent.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        guard Darwin.mkdir(root.path, 0o700) == 0 else { throw DriveError(errno, "Couldn’t make a state folder for the drive") }
        do { try CloudAccountStore(root: root).share(account, vault: vault) }
        catch { try? FileManager.default.removeItem(at: root); throw error }
        return root.standardizedFileURL
    }

    /// The drive of a state folder another app asks ParaAir to learn (a mount request for a folder it doesn't know yet),
    /// or an error saying why not. Only what the paraair CLI makes qualifies, never a folder a web page could have put
    /// on this Mac: a real folder (no link) directly inside "Cloud Drives", owned by this user, holding exactly one valid
    /// ParaAir Cloud profile, whose account record there is signed in and is the same sign-in (id, issuer and binding)
    /// as one in a folder ParaAir already knows.
    public static func adoptableProfile(_ folder: URL, knownRoots: [URL], home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> DriveProfile {
        let refused = { (reason: String) in DriveError(EACCES, "ParaAir can’t add this folder: " + reason) }
        let root = folder.standardizedFileURL, parent = cloudDrivesFolder(home: home).standardizedFileURL
        guard root.deletingLastPathComponent().standardizedFileURL.path == parent.path else { throw refused("it isn’t a ParaAir Cloud Drives folder") }
        for url in [parent, root] {
            var info = Darwin.stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
                throw refused("it isn’t a folder of this user")
            }
        }
        let profiles = try ProfileStore(root: root).list()
        guard profiles.count == 1, let profile = profiles.first, profile.backend == .paraairCloud, (try? profile.validate()) != nil,
              let accountID = profile.cloudAccountID else { throw refused("it doesn’t hold exactly one ParaAir Cloud drive") }
        guard let account = try? CloudAccountStore(root: root).load(accountID), account.state == .signedIn,
              account.issuer == profile.cloudIssuer else { throw refused("its ParaAir Cloud account isn’t signed in") }
        let known = knownRoots.map(\.standardizedFileURL).filter { $0.path != root.path }
        guard known.contains(where: { other in
            (try? CloudAccountStore(root: other).load(accountID)).map {
                $0.state == .signedIn && $0.binding == account.binding && $0.issuer == account.issuer
            } ?? false
        }) else { throw refused("its account isn’t one ParaAir is signed in to") }
        return profile
    }

    /// Verifies the drive with `GET /v1/drives/{id}` before saving the profile.
    /// `name` defaults to a slug of `finderName`; `replace` allows replacing a profile of that name.
    public static func attach(driveID: String, finderName: String, name: String? = nil, accountID: String, stateRoot: URL,
                              replace: Bool = false, dependencies: EngineOpenDependencies = .live) throws -> DriveProfile {
        guard ParaAirCloudIDs.isDriveID(driveID) else { throw DriveError(ENXIO, "Invalid ParaAir Cloud drive") }
        let name = name ?? profileName(for: finderName)
        try requireEmptyFolder(stateRoot, replacing: replace ? name : nil)
        let (account, api) = try connect(accountID: accountID, stateRoot: stateRoot, dependencies: dependencies)
        let detail = try api.drive(driveID)
        guard detail.drive.id == driveID else { throw DriveError(ENXIO, "ParaAir Cloud returned a different drive") }
        let value = profile(issuer: account.issuer, accountID: account.id, driveID: driveID, finderName: finderName,
                            stateRoot: stateRoot, freeBytes: try freeBytes(stateRoot), name: name, workspaceID: detail.drive.workspaceId)
        try ProfileStore(root: stateRoot).save(value, overwrite: replace)
        return value
    }

    /// The idempotency key is persisted before the request, so a retry after a crash
    /// or a lost reply returns the same drive instead of creating another.
    public static func create(workspaceID: String, name: String, finderName: String, profileName: String? = nil, accountID: String,
                              stateRoot: URL, dependencies: EngineOpenDependencies = .live) throws -> DriveProfile {
        let slug = profileName ?? self.profileName(for: finderName)
        try requireEmptyFolder(stateRoot, replacing: nil)
        let (account, api) = try connect(accountID: accountID, stateRoot: stateRoot, dependencies: dependencies)
        let file = stateRoot.appendingPathComponent(pendingFile)
        var pending = PendingDrive(idempotencyKey: UUID(), workspaceID: workspaceID, name: name)
        if let saved = loadPending(file), saved.workspaceID == workspaceID, saved.name == name { pending = saved }
        else { try DurableIO.write(JSONEncoder().encode(pending), to: file) }
        let drive = try api.createDrive(workspaceID: workspaceID, name: name, idempotencyKey: pending.idempotencyKey)
        let value = profile(issuer: account.issuer, accountID: account.id, driveID: drive.id, finderName: finderName,
                            stateRoot: stateRoot, freeBytes: try freeBytes(stateRoot), name: slug, workspaceID: drive.workspaceId)
        try ProfileStore(root: stateRoot).save(value)
        try? FileManager.default.removeItem(at: file)
        return value
    }

    static func profile(issuer: String, accountID: String, driveID: String, finderName: String, stateRoot: URL, freeBytes: Int64,
                        name: String? = nil, workspaceID: String? = nil) -> DriveProfile {
        let name = name ?? profileName(for: finderName)
        func clamp(_ value: Int64, _ low: Int64, _ high: Int64) -> Int64 { min(max(value, low), high) }
        let gib: Int64 = 1 << 30
        return DriveProfile(name: name, backend: .paraairCloud, mountPoint: nil,
                            cacheLimitBytes: clamp(freeBytes / 10, 2 * gib, 20 * gib), minFreeBytes: 5 * gib,
                            blockSize: blockSize, maxJournalBytes: clamp(freeBytes / 5, 4 * gib, 50 * gib),
                            displayName: finderName == name ? nil : finderName,
                            cloudIssuer: issuer, cloudAccountID: accountID, cloudDriveID: driveID,
                            cloudWorkspaceID: workspaceID.flatMap { ParaAirCloudIDs.isWorkspaceID($0) ? $0 : nil })
    }

    /// The same slug rule as the app's `DriveNaming.profileName`.
    public static func profileName(for finderName: String) -> String {
        var slug = ""
        for scalar in finderName.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) || "._-".unicodeScalars.contains(scalar) {
                slug.unicodeScalars.append(scalar)
            } else if CharacterSet.whitespaces.contains(scalar), !slug.isEmpty, !slug.hasSuffix("-") {
                slug.append("-")
            }
        }
        while let first = slug.unicodeScalars.first, !CharacterSet.alphanumerics.contains(first) { slug.removeFirst() }
        slug = String(slug.prefix(64))
        while slug.hasSuffix("-") || slug.hasSuffix(".") || slug.hasSuffix("_") { slug.removeLast() }
        return slug.isEmpty ? "ParaAir" : slug
    }

    private struct PendingDrive: Codable { var idempotencyKey: UUID; var workspaceID: String; var name: String }

    private static func loadPending(_ file: URL) -> PendingDrive? {
        var s = Darwin.stat()
        guard lstat(file.path, &s) == 0, s.st_mode & S_IFMT == S_IFREG, s.st_size <= 4096,
              let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(PendingDrive.self, from: data)
    }

    private static func requireEmptyFolder(_ stateRoot: URL, replacing name: String?) throws {
        let profiles = try ProfileStore(root: stateRoot).list()
        guard profiles.isEmpty || (name != nil && profiles.map(\.name) == [name!]) else {
            throw DriveError(EEXIST, "This Finder state folder already has a drive. Choose another state folder for another drive (paraair connect --new-state-folder).")
        }
    }

    private static func connect(accountID: String, stateRoot: URL, dependencies: EngineOpenDependencies) throws -> (CloudAccount, ParaAirCloudAPI) {
        let account = try CloudAccountStore(root: stateRoot).load(accountID)
        guard account.state == .signedIn else { throw DriveError(EACCES, "Sign in to ParaAir Cloud") }
        let session = try ParaAirCloudSession.shared(root: stateRoot, accountID: accountID, vault: dependencies.cloudVault,
                                                     configuration: dependencies.cloudConfiguration, policy: dependencies.cloudPolicy,
                                                     options: dependencies.cloudSessionOptions)
        return (account, ParaAirCloudAPI(http: try session.http(), tokens: session))
    }

    private static func freeBytes(_ stateRoot: URL) throws -> Int64 {
        try DurableIO.directory(stateRoot)
        return try DurableIO.freeBytes(stateRoot)
    }
}
