import Foundation
import StreamDriveCore

/// Plain inputs read from MenuModel. Keeping them as values lets the home window and
/// menu bar panel be rendered and checked without the app's connection or mount services.
struct HomeInputs: Equatable {
    var driveName: String?
    var storageSummary: String?
    var mountPath: String?
    var readyConnectionName: String?
    var credentialCheckFinished = false
    var connectionIssue: String?
    var renewalError: String?
    var extensionState: FinderExtensionState = .unchecked
    var checkingExtension = false
    /// The person came back from System Settings, or chose Check Again, and the extension is still off.
    var extensionStillOff = false
    /// The extension was on before on this Mac and is off now: macOS switched it off, typically when ParaAir was replaced.
    var extensionTurnedOff = false
    /// Other copies of ParaAir on this Mac that LaunchServices knows about (OtherAppCopies.present).
    var otherCopies: [String] = []
    var mounted = false
    /// The selected folder's drive is mounting.
    var mounting = false
    /// Another folder's drive is mounting. One mount runs at a time, so the selected drive's Connect waits for it.
    var otherMountRunning = false
    var creatingDrive = false
    var error: String?
    var mountMessage: String?
    /// The drive `mountMessage` is about, recorded when the message was written; nil when it is about no single drive
    /// (System Settings didn't open). Named before the message while drives are listed.
    var mountMessageDrive: String?
    /// A waiting folder switch, or a drive in another state folder that didn't connect at login.
    var folderNotice: String?
    var sidebarMessage: String?
    var storageKind: StorageKind = .ownBucket
    var uploadActivity: UploadActivity?
    /// Drives whose index is on this Mac: when it was last backed up into the bucket.
    var indexBackup: IndexBackupLine?
    /// Another Mac recovered the drive and owns it now: that Mac's name.
    var ownedElsewhere: String?
    var cloudUsage: CloudUsage?
    /// An update found by a scheduled check while ParaAir wasn't in front ("ParaAir 0.1.0 alpha 3").
    var updateTitle: String?
    /// For ages such as how long failing uploads have waited.
    var now = Date()
    /// The drives of the other state folders ParaAir knows (kept for login or remembered). With any, the window lists
    /// every drive and leads with a summary instead of one drive's state.
    var otherDrives: [KnownDrive] = []

    /// The selected folder has a drive.
    var hasDrive: Bool { driveName != nil }
}

/// The drive of a state folder other than the selected one. The selected folder's drive is described by
/// HomeInputs' own fields.
struct KnownDrive: Equatable, Identifiable {
    enum State: Equatable { case connected, connecting, needsSignIn, off }
    /// The drive's state folder.
    var id: String
    var name: String
    /// "ParaAir Cloud · maya@example.com" or "Cloudflare R2 · studio-footage".
    var storage: String
    var state: State
    /// In the mount table, including while its storage needs sign-in.
    var mounted = false
    /// Why it needs sign-in or didn't connect, as a sentence that follows the drive's name.
    var issue: String?

    /// A mount of this drive that failed, at login or from its Connect button.
    static let didNotConnect = "Couldn’t open. Choose Connect to try again."
}

/// Where the drive's files live: a bucket the user connected, or ParaAir Cloud.
enum StorageKind: Equatable { case ownBucket, paraairCloud }

/// Progress of the `/v1/me` plan and usage summary.
enum CloudSummaryState: Equatable { case idle, loading, loaded, failed }

/// The workspace whose plan and usage the drive counts against, with its load state.
struct CloudUsage: Equatable {
    var workspace: ParaAirCloudMe.Workspace?
    var state: CloudSummaryState
    /// Some workspace of the account offers checkout (the plan sheet has something to sell).
    var planChoiceAvailable = false
    /// A payment page for this workspace is open and not yet paid.
    var pendingCheckout = false

    var billing: CloudBillingPresentation {
        CloudBillingPresentation.make(workspace, state: state, planChoiceAvailable: planChoiceAvailable, pendingCheckout: pendingCheckout)
    }
}

/// What the home window and menu bar panel show. Presentation only: every action maps
/// to an existing MenuModel operation.
struct HomePresentation: Equatable {
    enum Tone: Equatable { case good, working, attention, problem, neutral }
    static let noStorageTitle = "Connected, no storage yet"

    enum Action: Equatable {
        case addStorage, createDrive, signInAgain, openSystemSettings, connectDrive, openInFinder
        /// Opens the list of conflicts and refused changes.
        case reviewChanges
        /// Opens the ParaAir Cloud plan sheet (a workspace with no storage yet).
        case choosePlan
        /// Shows the other copies of ParaAir in Finder, so the person can keep only the installed one.
        case showOtherCopies
    }
    enum StepState: Equatable { case done, current, upcoming }

    struct Status: Equatable {
        var title: String
        var detail: String
        var tone: Tone
    }
    struct Primary: Equatable {
        var action: Action
        var title: String
        var enabled = true
        var busy = false
    }
    struct Step: Equatable, Identifiable {
        var id: Int
        var title: String
        var detail: String
        var state: StepState
    }
    struct Notice: Equatable, Identifiable {
        var id: String
        var text: String
        var tone: Tone
        /// A button beside the text.
        var action: Action? = nil
        var actionTitle: String? = nil
    }
    /// One drive in the list: its Finder name, storage, state and the one action that state needs.
    struct DriveRow: Equatable, Identifiable {
        /// `selectedDriveID` for the selected folder's drive, otherwise its state folder.
        var id: String
        var name: String
        var storage: String
        var state: KnownDrive.State
        var stateTitle: String
        var tone: Tone
        var action: Action?
        var actionTitle: String?
        /// Why it needs sign-in or didn't connect, as a sentence that follows its name.
        var issue: String?
        /// Its folder becomes the selected one first: Storage Settings shows the selected folder's connections.
        var switchesFolder = false
        /// False while the action can't run yet (a mount or drive creation is running).
        var enabled = true
    }
    static let selectedDriveID = "selected"
    static let readOnlyNotice = "Read-only. You can open, download, move and delete files; new and changed files don’t upload."

    var status: Status
    var primary: Primary
    /// False when the drive list carries the actions: several drives and nothing that stops them all.
    var showsPrimary = true
    var offersCheckAgain = false
    var offersOpenInFinder = false
    var steps: [Step] = []
    var notices: [Notice] = []
    /// Every drive ParaAir knows, working drives first. Empty while the selected folder's drive is the only one.
    var drives: [DriveRow] = []
    /// Show the picture of the File System Extensions list with ParaAir's switch on, beside the status.
    var showsSwitchPicture = false

    static func make(_ input: HomeInputs) -> HomePresentation {
        input.otherDrives.isEmpty ? one(input) : several(input)
    }

    /// The selected folder's drive is the only one, or there is none yet.
    private static func one(_ input: HomeInputs) -> HomePresentation {
        let drive = input.driveName ?? "your drive"
        // Known to be off: FSKit answered and ParaAir isn't on. Turning it on comes first in setup, because nothing
        // else depends on it and it is the one step that happens outside ParaAir.
        let extensionOff = input.extensionState != .enabled && input.extensionState != .unchecked
        var result: HomePresentation

        if !input.mounted && !input.mounting && input.creatingDrive {
            result = .init(status: .init(title: "Creating your drive…",
                                         detail: "ParaAir is preparing the drive on this Mac.", tone: .working),
                           primary: .init(action: .createDrive, title: "Creating…", enabled: false, busy: true))
        } else if !input.mounted && !input.mounting && input.extensionState == .unchecked {
            // Not known yet: the switch comes first, so nothing else is offered until the check answers. The button
            // stays usable, in case macOS is slow to answer.
            result = .init(status: .init(title: "Checking System Settings…",
                                         detail: "Looking for ParaAir’s file system extension.", tone: .working),
                           primary: .init(action: .openSystemSettings, title: "Open System Settings", busy: input.checkingExtension))
        } else if !input.mounted && !input.mounting && extensionOff {
            result = .init(status: extensionStatus(input.extensionState, stillOff: input.extensionStillOff,
                                                   turnedOff: input.extensionTurnedOff),
                           primary: .init(action: .openSystemSettings, title: "Open System Settings"),
                           offersCheckAgain: true)
            result.showsSwitchPicture = input.extensionState == .disabled
        } else if !input.hasDrive {
            if let connection = input.readyConnectionName {
                result = .init(status: .init(title: "Storage added",
                                             detail: "\(connection) is ready. Create a drive to see it in Finder.", tone: .neutral),
                               primary: .init(action: .createDrive, title: "Create Drive…"))
            } else {
                result = .init(status: .init(title: "Not set up yet",
                                             detail: "Sign in to ParaAir Cloud or connect your own storage bucket. ParaAir sets up the drive, its cache and Finder.",
                                             tone: .neutral),
                               primary: .init(action: .addStorage, title: "Set Up Storage…"))
            }
        } else if input.mounted {
            if let issue = input.connectionIssue {
                result = .init(status: .init(title: "Storage access interrupted",
                                             detail: issue + " Files that aren’t on this Mac can’t open until access returns; your changes are kept and upload afterwards.",
                                             tone: .attention),
                               primary: .init(action: .signInAgain, title: "Sign In Again…"),
                               offersOpenInFinder: true)
            } else if input.storageKind == .paraairCloud, let cloud = input.cloudUsage, cloud.state == .loaded,
                      CloudBillingPresentation.isUnpaid(cloud.workspace) {
                // A self-serve workspace before its free trial: files open, nothing uploads until a plan grants storage.
                let control = cloud.billing.controls.first { $0.action == .choosePlan }
                result = .init(status: .init(title: Self.noStorageTitle,
                                             // Only the owner can start a plan; anyone else is sent to them.
                                             detail: control == nil ? "Ask the workspace owner to choose a ParaAir Cloud plan to add files to this drive."
                                                 : cloud.workspace?.billing?.trialDays.map {
                                                     "Start your \($0)-day free trial to add files to this drive. Nothing is charged before it ends."
                                                 } ?? "Choose a ParaAir Cloud plan to add files to this drive.",
                                             tone: .attention),
                               primary: control.map { .init(action: .choosePlan, title: $0.title) } ?? .init(action: .openInFinder, title: "Open in Finder"),
                               offersOpenInFinder: control != nil)
            } else if input.storageKind == .paraairCloud, input.cloudUsage?.workspace?.status == "read_only" {
                // The service refuses uploads, commits and new folders (403 read_only); reads, deletes, moves and
                // restores from the trash keep working (contract README "Billing"; subscription policy 16.1).
                result = .init(status: .init(title: "Connected, read-only",
                                             detail: "You can open, download, move and delete files. New and changed files don’t upload.",
                                             tone: .attention),
                               primary: .init(action: .openInFinder, title: "Open in Finder"))
            } else if let owner = input.ownedElsewhere {
                result = .init(status: .init(title: "Read-only on this Mac",
                                             detail: "\(owner) took over this drive. You can open its files here; changes are made on \(owner).",
                                             tone: .attention),
                               primary: .init(action: .openInFinder, title: "Open in Finder"))
            } else {
                result = .init(status: .init(title: "Connected",
                                             detail: "Files download in pieces as apps read them.", tone: .good),
                               primary: .init(action: .openInFinder, title: "Open in Finder"))
            }
        } else if input.mounting {
            result = .init(status: .init(title: "Connecting…", detail: "macOS is opening \(drive).", tone: .working),
                           primary: .init(action: .connectDrive, title: "Connecting…", enabled: false, busy: true))
        } else if !input.credentialCheckFinished {
            result = .init(status: .init(title: "Checking storage access…",
                                         detail: "ParaAir is confirming your saved sign-in.", tone: .working),
                           primary: .init(action: .connectDrive, title: "Connect Drive", enabled: false, busy: true))
        } else if let issue = input.connectionIssue {
            result = .init(status: .init(title: "Storage access needed", detail: issue, tone: .problem),
                           primary: .init(action: .signInAgain, title: "Sign In Again…"))
        } else if input.checkingExtension && input.extensionState != .enabled {
            result = .init(status: .init(title: "Checking System Settings…",
                                         detail: "Looking for ParaAir’s file system extension.", tone: .working),
                           primary: .init(action: .openSystemSettings, title: "Open System Settings", enabled: false, busy: true))
        } else if input.extensionState != .enabled {
            result = .init(status: extensionStatus(input.extensionState, stillOff: false, turnedOff: false),
                           primary: .init(action: .openSystemSettings, title: "Open System Settings"),
                           offersCheckAgain: true)
        } else {
            result = .init(status: .init(title: "Not connected",
                                         detail: "Your storage is ready. Connect the drive to use it in Finder.", tone: .neutral),
                           primary: .init(action: .connectDrive, title: "Connect Drive"))
        }

        // The checklist is for a Mac with no drive yet; once there is one, the status says what it needs.
        if !input.hasDrive {
            let storageDone = input.readyConnectionName != nil
            let enabled = input.extensionState == .enabled
            // One action per step, in the order setup happens: the switch in System Settings, storage, the drive, Finder.
            result.steps = [
                .init(id: 1, title: "Turn on ParaAir in System Settings",
                      detail: "General → Login Items & Extensions → By Category → File System Extensions.",
                      state: enabled ? .done : .current),
                .init(id: 2, title: "Add your storage", detail: "ParaAir Cloud, Cloudflare R2 or another S3-compatible bucket.",
                      state: storageDone ? .done : (enabled ? .current : .upcoming)),
                .init(id: 3, title: "Create your drive", detail: "Name it however you like.",
                      state: enabled && storageDone ? .current : .upcoming),
                .init(id: 4, title: "Open it in Finder", detail: "It appears under Locations, like any drive.", state: .upcoming),
            ]
        }

        if let error = input.error { result.notices.append(.init(id: "error", text: error, tone: .problem)) }
        if let copies = otherCopiesNotice(input.otherCopies) { result.notices.append(copies) }
        // The no-storage status already says what the billing notice would; the notice stays in Storage Settings.
        result.notices += selectedDriveNotices(input, named: nil, mountDrive: nil, billing: result.status.title != Self.noStorageTitle,
                                               listed: false)
        return result
    }

    /// Two or more drives, in this folder and others: a summary leads, each drive gets a row with its one action, and
    /// every problem names its drive. Only what stops every drive (the switch, a first check, a drive being created
    /// while none is mounted) still leads with a single action.
    private static func several(_ input: HomeInputs) -> HomePresentation {
        let rows = driveRows(input)
        let anyMounted = input.mounted || input.otherDrives.contains { $0.mounted }
        let extensionOff = input.extensionState != .enabled && input.extensionState != .unchecked
        var result: HomePresentation
        if !anyMounted && input.creatingDrive {
            result = .init(status: .init(title: "Creating your drive…",
                                         detail: "ParaAir is preparing the drive on this Mac.", tone: .working),
                           primary: .init(action: .createDrive, title: "Creating…", enabled: false, busy: true))
        } else if !anyMounted && input.extensionState == .unchecked {
            result = .init(status: .init(title: "Checking System Settings…",
                                         detail: "Looking for ParaAir’s file system extension.", tone: .working),
                           primary: .init(action: .openSystemSettings, title: "Open System Settings", busy: input.checkingExtension))
        } else if !anyMounted && extensionOff {
            result = .init(status: extensionStatus(input.extensionState, stillOff: input.extensionStillOff,
                                                   turnedOff: input.extensionTurnedOff),
                           primary: .init(action: .openSystemSettings, title: "Open System Settings"),
                           offersCheckAgain: true)
            result.showsSwitchPicture = input.extensionState == .disabled
        } else {
            // The rows carry every action, so no primary button is drawn; this value only fills the field.
            result = .init(status: summary(rows), primary: .init(action: .openInFinder, title: "Open in Finder"), showsPrimary: false)
        }
        result.drives = rows

        if let error = input.error { result.notices.append(.init(id: "error", text: error, tone: .problem)) }
        if let copies = otherCopiesNotice(input.otherCopies) { result.notices.append(copies) }
        if !input.hasDrive, let connection = input.readyConnectionName {
            result.notices.append(.init(id: "ready-connection", text: "\(connection) is ready. Create a drive to see it in Finder.",
                                        tone: .neutral, action: .createDrive, actionTitle: "Create Drive…"))
        }
        for row in rows {
            if let issue = row.issue {
                result.notices.append(.init(id: "drive-" + row.id, text: "\(row.name): \(issue)", tone: .attention))
            }
        }
        result.notices += selectedDriveNotices(input, named: input.driveName, mountDrive: input.mountMessageDrive, billing: true, listed: true)
        return result
    }

    /// The selected folder's drive first, then the others in the order ParaAir learned them; working drives move ahead
    /// of the rest, so a drive that can't connect never hides one that works.
    private static func driveRows(_ input: HomeInputs) -> [DriveRow] {
        var drives: [KnownDrive] = []
        if let name = input.driveName {
            let state: KnownDrive.State
            if input.mounted { state = input.connectionIssue == nil ? .connected : .needsSignIn }
            else if input.mounting || !input.credentialCheckFinished { state = .connecting }
            else { state = input.connectionIssue == nil ? .off : .needsSignIn }
            drives.append(KnownDrive(id: selectedDriveID, name: name, storage: input.storageSummary ?? "Saved storage connection",
                                     state: state, mounted: input.mounted, issue: input.connectionIssue))
        }
        drives += input.otherDrives
        func rank(_ state: KnownDrive.State) -> Int {
            switch state { case .connected: 0; case .connecting: 1; case .needsSignIn: 2; case .off: 3 }
        }
        return drives.enumerated()
            .sorted { (rank($0.element.state), $0.offset) < (rank($1.element.state), $1.offset) }
            .map { item in
                var row = row(item.element)
                // The selected drive's Connect starts a mount, which waits for one already running; another folder's
                // Connect only queues its drive. Switching folders waits for any mount or drive creation.
                if row.id == selectedDriveID, row.action == .connectDrive { row.enabled = !input.otherMountRunning }
                if row.switchesFolder { row.enabled = !(input.mounting || input.otherMountRunning || input.creatingDrive) }
                return row
            }
    }

    private static func row(_ drive: KnownDrive) -> DriveRow {
        func make(_ title: String, _ tone: Tone, _ action: Action?, _ actionTitle: String?) -> DriveRow {
            DriveRow(id: drive.id, name: drive.name, storage: drive.storage, state: drive.state, stateTitle: title, tone: tone,
                     action: action, actionTitle: actionTitle, issue: drive.issue,
                     switchesFolder: action == .signInAgain && drive.id != selectedDriveID)
        }
        switch drive.state {
        case .connected: return make("Connected", .good, .openInFinder, "Open in Finder")
        case .connecting: return make("Connecting…", .working, nil, nil)
        case .needsSignIn: return make("Needs sign-in", .attention, .signInAgain, "Sign In Again…")
        case .off: return make("Off", drive.issue == nil ? .neutral : .attention, .connectDrive, "Connect")
        }
    }

    /// "2 drives connected · R2 Test needs sign-in". "Storage access needed" only when every drive needs sign-in.
    static func summary(_ rows: [DriveRow]) -> Status {
        let connected = rows.filter { $0.state == .connected }.count
        let connecting = rows.filter { $0.state == .connecting }
        let signIn = rows.filter { $0.state == .needsSignIn }
        let failed = rows.filter { $0.state == .off && $0.issue != nil }
        if !rows.isEmpty, signIn.count == rows.count {
            return .init(title: "Storage access needed",
                         detail: rows.count == 1 ? "Sign in again in Storage Settings to connect \(rows[0].name)."
                             : "None of your drives can reach its storage. Sign in again for each one below.",
                         tone: .problem)
        }
        func part(_ drives: [DriveRow], one: String, many: String) -> String? {
            drives.isEmpty ? nil : drives.count == 1 ? "\(drives[0].name) \(one)" : "\(drives.count) drives \(many)"
        }
        let lead = connected > 0 ? (connected == 1 ? "1 drive connected" : "\(connected) drives connected")
            : connecting.isEmpty ? "Not connected" : nil
        let title = [lead, part(connecting, one: "is connecting", many: "connecting"),
                     part(signIn, one: "needs sign-in", many: "need sign-in"),
                     part(failed, one: "didn’t connect", many: "didn’t connect")].compactMap { $0 }.joined(separator: " · ")
        let tone: Tone = !signIn.isEmpty || !failed.isEmpty ? .attention : !connecting.isEmpty ? .working : connected > 0 ? .good : .neutral
        let detail = connected > 0 ? "Files download in pieces as apps read them."
            : !connecting.isEmpty ? "macOS is opening your drives." : "Connect a drive to use it in Finder."
        return .init(title: title, detail: detail, tone: tone)
    }

    /// Notices about the selected folder's drive. `named` puts the drive's name before each one when other drives are
    /// listed beside it, so a problem never reads as if it were every drive's.
    /// `listed`: other drives are listed beside it, so limits the status would otherwise explain become notices.
    private static func selectedDriveNotices(_ input: HomeInputs, named drive: String?, mountDrive: String?, billing showsBilling: Bool,
                                             listed: Bool) -> [Notice] {
        func withName(_ notice: Notice, as name: String?) -> Notice {
            guard let name else { return notice }
            var notice = notice
            notice.text = "\(name): \(notice.text)"
            return notice
        }
        func named(_ notice: Notice) -> Notice { withName(notice, as: drive) }
        var notices: [Notice] = []
        if let message = input.mountMessage {
            // Named after the drive it was written about, which may be another folder's, even with no drive selected.
            notices.append(withName(.init(id: "mount", text: message, tone: .attention), as: mountDrive))
        }
        if let notice = input.folderNotice { notices.append(.init(id: "folder", text: notice, tone: .attention)) }
        if let renewal = input.renewalError, input.connectionIssue == nil {
            notices.append(named(.init(id: "renewal", text: renewal, tone: .attention)))
        }
        let billingNotice = input.storageKind == .paraairCloud ? input.cloudUsage?.billing.notice : nil
        if let billing = billingNotice, showsBilling { notices.append(named(billing)) }
        // A service without billing can still make a workspace read-only; alone, the status says so (`one()`), listed
        // beside other drives the row only says Connected.
        if listed, billingNotice == nil, input.storageKind == .paraairCloud, input.mounted,
           input.cloudUsage?.workspace?.status == "read_only" {
            notices.append(named(.init(id: "read-only", text: Self.readOnlyNotice, tone: .attention)))
        }
        if let message = input.sidebarMessage { notices.append(.init(id: "sidebar", text: message, tone: .neutral)) }
        if let owner = input.ownedElsewhere, listed || !input.mounted {
            notices.append(named(.init(id: "owned-elsewhere", text: "\(owner) took over this drive. It opens read-only on this Mac.",
                                       tone: .attention)))
        }
        if let activity = input.uploadActivity {
            notices += uploadNotices(activity, cloud: input.storageKind == .paraairCloud, accessIssue: input.connectionIssue != nil,
                                     owner: input.ownedElsewhere, now: input.now).map { named($0) }
        }
        if let problem = input.indexBackup?.problem {
            notices.append(named(.init(id: "index-backup", text: problem, tone: .attention)))
        }
        return notices
    }

    /// Another registered copy can make macOS use its extension instead of this one's.
    private static func otherCopiesNotice(_ copies: [String]) -> Notice? {
        guard let first = copies.first else { return nil }
        let folder = ((first as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
        let text = copies.count == 1
            ? "Another copy of ParaAir is in \(folder). Keep only the one in Applications so macOS turns on the right one."
            : "\(copies.count) other copies of ParaAir are on this Mac. Keep only the one in Applications so macOS turns on the right one."
        return .init(id: "other-copies", text: text, tone: .attention, action: .showOtherCopies, actionTitle: "Show in Finder")
    }

    /// Problems first. Quota and sign-in wording is specific to ParaAir Cloud. Files waiting
    /// for a sign-in count as waiting when the status above already asks for one, and for
    /// your own bucket, whose access the storage status explains.
    private static func uploadNotices(_ activity: UploadActivity, cloud: Bool, accessIssue: Bool, owner: String?, now: Date) -> [Notice] {
        var notices: [Notice] = []
        // Conflicts and refused changes never upload by themselves; the review sheet resolves them.
        let review: (action: Action?, title: String?) = activity.decisions.isEmpty ? (nil, nil) : (.reviewChanges, "Review…")
        if activity.blockedElsewhere > 0 {
            let text = cloud ? UploadNotices.readOnlyPlan(activity.blockedElsewhere) : UploadNotices.elsewhere(activity.blockedElsewhere, owner: owner)
            notices.append(.init(id: "upload-elsewhere", text: text, tone: .attention, action: review.action, actionTitle: review.title))
        }
        if activity.blockedAccess > 0 {
            notices.append(.init(id: "upload-access", text: UploadNotices.forbidden(activity.blockedAccess), tone: .attention,
                                 action: review.action, actionTitle: review.title))
        }
        // Refused access is already the status when storage access is interrupted; those files just wait.
        let failingShown = activity.failure.map { !(accessIssue && ($0.errno == EACCES || $0.errno == EPERM)) } ?? false
        if failingShown, let failure = activity.failure, activity.failing > 0 {
            notices.append(.init(id: "upload-failing", text: UploadNotices.failing(failure, cloud: cloud, now: now), tone: .attention))
        }
        let signIn = cloud && !accessIssue
        if signIn, activity.blockedAuth > 0 {
            notices.append(.init(id: "upload-sign-in", text: UploadNotices.signIn(activity.blockedAuth), tone: .attention))
        }
        if cloud, activity.blockedQuota > 0 {
            notices.append(.init(id: "upload-quota", text: UploadNotices.quota(activity.blockedQuota), tone: .attention))
        }
        if activity.conflicts > 0 {
            notices.append(.init(id: "upload-conflicts", text: UploadNotices.conflicts(activity.conflicts), tone: .attention,
                                 action: review.action, actionTitle: review.title))
        }
        let waiting = activity.waiting + activity.failedOther + (cloud ? 0 : activity.blockedQuota) + (signIn ? 0 : activity.blockedAuth)
            + (failingShown ? 0 : activity.failing)
        if waiting > 0 { notices.append(.init(id: "upload-waiting", text: UploadNotices.waiting(waiting), tone: .neutral)) }
        return notices
    }

    /// `stillOff`: the person went to System Settings from here and came back with the switch off. The usual cause on
    /// macOS 27.2 is the switch under ParaAir Extensions (FSKit Modules), which flips back (ExtensionSetupGuidance).
    private static func extensionStatus(_ state: FinderExtensionState, stillOff: Bool, turnedOff: Bool) -> Status {
        switch state {
        case .disabled where turnedOff && !stillOff:
            return .init(title: "ParaAir’s switch is off again",
                         detail: "macOS can switch it off when ParaAir is replaced. Switch on \(ExtensionSetupGuidance.switchName) "
                             + "in the File System Extensions list, as pictured. Your drive connects by itself once it’s on.",
                         tone: .attention)
        case .disabled where stillOff:
            return .init(title: "That switch didn’t save",
                         detail: "Use the File System Extensions list under By Category, as pictured. The switch under "
                             + "ParaAir Extensions turns itself off. Still off there too? Quit and reopen ParaAir, then try again.",
                         tone: .attention)
        case .disabled:
            return .init(title: "Turn on ParaAir in System Settings",
                         detail: "Switch on \(ExtensionSetupGuidance.switchName) in the File System Extensions list, as pictured. "
                             + ExtensionSetupGuidance.sheetWarning,
                         tone: .attention)
        case .notDiscovered:
            return .init(title: "macOS hasn’t listed ParaAir yet",
                         detail: "Quit and reopen ParaAir. If it’s still missing from File System Extensions, "
                             + "reinstall ParaAir from its disk image.",
                         tone: .attention)
        case .ambiguous:
            return .init(title: "Another copy of ParaAir is installed",
                         detail: "macOS sees more than one ParaAir. Keep only the one in Applications, then check again.", tone: .attention)
        case .failed:
            return .init(title: "System Settings didn’t answer",
                         detail: "macOS didn’t report the extension’s status. Check again in a moment.", tone: .attention)
        case .unchecked, .enabled:
            return .init(title: "Check System Settings",
                         detail: "Confirm ParaAir’s file system extension is switched on.", tone: .neutral)
        }
    }
}

/// Copy for files that haven't reached storage yet, shared by the home window, the
/// menu bar panel, notifications and the sign-out confirmation.
enum UploadNotices {
    static func files(_ count: Int) -> String { count == 1 ? "1 file" : "\(count) files" }
    static func waiting(_ count: Int) -> String {
        count == 1 ? "1 file is waiting to upload." : "\(count) files are waiting to upload."
    }
    static func quota(_ count: Int) -> String {
        "Your ParaAir Cloud storage is full. \(files(count)) will upload when space is available."
    }
    static func signIn(_ count: Int) -> String { "Sign in to ParaAir Cloud to upload \(files(count))." }
    static func conflicts(_ count: Int) -> String {
        count == 1 ? "1 file changed on another device. Your copy is kept on this Mac."
            : "\(count) files changed on another device. Your copies are kept on this Mac."
    }
    static func elsewhere(_ count: Int, owner: String?) -> String {
        let changes = count == 1 ? "1 change" : "\(count) changes"
        return "\(changes) made here won’t upload because \(owner ?? "another Mac") took over the drive. "
            + (count == 1 ? "It stays on this Mac." : "They stay on this Mac.")
    }
    static func readOnlyPlan(_ count: Int) -> String {
        let changes = count == 1 ? "1 change" : "\(count) changes"
        return "\(changes) made here won’t upload while your ParaAir Cloud plan is read-only. "
            + (count == 1 ? "It stays on this Mac." : "They stay on this Mac.")
    }
    static func forbidden(_ count: Int) -> String {
        let changes = count == 1 ? "1 change" : "\(count) changes"
        return "\(changes) made here won’t upload: your access to \(count == 1 ? "that folder" : "those folders") doesn’t allow \(count == 1 ? "it" : "them"). "
            + "Save \(count == 1 ? "it" : "them") as new files, export or discard."
    }
    /// Uploads that keep failing. `now` adds how long the oldest change has waited.
    static func failing(_ failure: UploadFailureSummary, cloud: Bool, now: Date?) -> String {
        let text = "Couldn’t upload \(files(failure.count)): \(UploadFailureReason.text(failure.errno, cloud: cloud))."
        if let now {
            let oldest = Date(timeIntervalSince1970: TimeInterval(failure.oldestChangeNanoseconds) / 1_000_000_000)
            let formatter = DateComponentsFormatter()
            formatter.unitsStyle = .full; formatter.maximumUnitCount = 1
            formatter.allowedUnits = [.day, .hour, .minute]
            if let age = formatter.string(from: max(60, now.timeIntervalSince(oldest))) {
                return text + (failure.count == 1 ? " It has waited \(age)" : " The oldest has waited \(age)") + "; ParaAir keeps trying."
            }
        }
        return text + " ParaAir keeps trying; your changes stay on this Mac."
    }
    static func notUploaded(_ count: Int) -> String {
        count == 1 ? "1 file on this Mac hasn’t uploaded yet." : "\(count) files on this Mac haven’t uploaded yet."
    }
}

/// The Advanced row for a drive whose index lives on this Mac, and a notice when its
/// backup into the bucket keeps failing.
struct IndexBackupLine: Equatable {
    var value: String
    var problem: String?

    static func make(_ status: IndexBackupStatus, now: Date) -> IndexBackupLine {
        let last = status.lastBackupNanoseconds.map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000_000_000) }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        var value = last.map { "Backed up " + formatter.localizedString(for: min($0, now), relativeTo: now) } ?? "Not backed up yet"
        // Only a working backup promises the next one; a failing one has its notice.
        if status.pendingSinceNanoseconds != nil, last != nil, status.lastError == nil { value += "; newer changes back up within an hour" }
        // Another Mac owning the drive (EROFS) has its own status; no second notice for it.
        let problem = status.lastError == nil || status.lastErrno == EROFS ? nil :
            "ParaAir couldn’t back up this drive’s index to your bucket (\(reason(status))). It will try again. "
                + (last == nil ? "Until then, this drive can’t be opened on another Mac." : "Until then, the backup there is out of date.")
        return IndexBackupLine(value: value, problem: problem)
    }

    /// The cause in plain words: the engine's message names the native operation.
    private static func reason(_ status: IndexBackupStatus) -> String {
        switch status.lastErrno {
        case EFBIG: return "the index is larger than a Cloudflare sign-in connection can store; connect with an R2 API token instead"
        case ENETDOWN, ENETUNREACH, EHOSTUNREACH, ETIMEDOUT, ECONNRESET, ECONNREFUSED, ENOTCONN: return "no connection to your storage"
        case EACCES, EPERM: return "your storage refused access"
        default:
            let message = status.lastError ?? "unknown error"
            guard message.hasPrefix("JuiceFS "), let colon = message.range(of: ": ") else { return message }
            return String(message[colon.upperBound...]).lowercased()
        }
    }
}

/// Plan and usage lines for ParaAir Cloud. Every value comes from `/v1/me`; when the
/// summary is missing or failed, no figure is shown at all rather than a zero.
struct CloudUsagePresentation: Equatable {
    var planLine: String
    var usedLine: String?
    var fraction: Double?
    var retainedLine: String?
    var transferLine: String?
    var notice: String?
    /// The bare figures for the home window's Plan and Used rows.
    var planSize: String?
    var usedSize: String?
    /// A workspace with no storage until its free trial or a plan starts: `planLine` says so instead of figures.
    var unpaid = false

    static let unavailable = "Plan and usage are unavailable right now."
    static let checking = "Checking plan and usage…"
    static let noStorage = "No storage yet"

    static func make(_ workspace: ParaAirCloudMe.Workspace?, state: CloudSummaryState) -> CloudUsagePresentation {
        if state == .loaded, CloudBillingPresentation.isUnpaid(workspace) {
            return .init(planLine: noStorage, planSize: noStorage, unpaid: true)
        }
        guard state != .failed, let plan = workspace?.plan, let usage = workspace?.usage, plan.storageLimitBytes > 0 else {
            return .init(planLine: state == .idle || state == .loading ? checking : unavailable)
        }
        let limit = format(plan.storageLimitBytes), used = format(usage.storedBytes)
        let days = plan.retentionDays == 1 ? "1 day" : "\(plan.retentionDays) days"
        var result = CloudUsagePresentation(
            planLine: limit + " plan", usedLine: used + " used",
            fraction: min(1, max(0, Double(usage.storedBytes) / Double(plan.storageLimitBytes))),
            retainedLine: "Kept for recovery: \(usage.retainedBytes > 0 ? format(usage.retainedBytes) : "none") (deleted files stay \(days))",
            transferLine: "Transfer this month: \(format(usage.transferBytes)) of \(format(plan.transferAllowanceBytes))",
            planSize: limit, usedSize: used)
        if usage.throttled {
            var day = Date.FormatStyle.dateTime.month(.wide).day()
            day.timeZone = TimeZone(identifier: "UTC") ?? .current
            result.notice = "This month’s transfer allowance is used up, so downloads are slower until \(usage.periodEnd.formatted(day))."
        }
        return result
    }

    static func format(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .decimal
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: max(0, bytes))
    }
}

/// Stored profile names are identifiers (letters, digits, dots, underscores, hyphens;
/// starting with a letter or digit; at most 64 bytes). People type Finder names, so the
/// app derives the identifier and keeps their text as the drive's display name.
enum DriveNaming {
    static func profileName(for finderName: String) -> String {
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
}

/// The version ParaAir shows in Advanced and the About window. A release tag such as
/// v0.1.0-alpha.2 (ParaAirReleaseTag, set by scripts/build-app.sh) reads "0.1.0 alpha 2";
/// a tag that doesn't match the bundle's version is ignored rather than shown wrongly.
struct AppVersionText: Equatable {
    var title: String
    var build: String?

    /// "0.1.0 alpha 2 (148)".
    var line: String { build.map { "\(title) (\($0))" } ?? title }

    static func make(marketing: String?, build: String?, releaseTag: String?) -> AppVersionText {
        let version = marketing ?? "Development build"
        var title = version
        // v<marketing>-<alpha|beta|rc>.<n>; anything else leaves the plain version.
        if let tag = releaseTag, tag.hasPrefix("v") {
            let parts = tag.dropFirst().split(separator: "-", maxSplits: 1)
            let stage = parts.count == 2 ? parts[1].split(separator: ".") : []
            if parts.first.map(String.init) == marketing, stage.count == 2, ["alpha", "beta", "rc"].contains(stage[0]),
               !stage[1].isEmpty, stage[1].allSatisfy(\.isASCII), stage[1].allSatisfy(\.isNumber) {
                title = "\(version) \(stage[0] == "rc" ? "release candidate" : String(stage[0])) \(stage[1])"
            }
        }
        return AppVersionText(title: title, build: build)
    }

    static var current: AppVersionText {
        let info = Bundle.main.infoDictionary ?? [:]
        return make(marketing: info["CFBundleShortVersionString"] as? String, build: info["CFBundleVersion"] as? String,
                    releaseTag: info["ParaAirReleaseTag"] as? String)
    }
}

/// Installing an update replaces the app bundle, and the file system extension serving each
/// mounted drive runs from that bundle. So every ParaAir drive is ejected before the update
/// installs. A drive that won't eject (a file is open on it) keeps the update waiting.
/// Ejecting never discards anything: files waiting to upload stay on this Mac and upload
/// after the update, when the drive reconnects.
enum UpdateGate {
    enum Outcome: Equatable {
        case install
        case blocked(drives: [String])
    }

    /// `ejected` holds each mounted drive's name and whether it ejected.
    static func outcome(_ ejected: [(name: String, ejected: Bool)]) -> Outcome {
        let busy = ejected.filter { !$0.ejected }.map(\.name)
        return busy.isEmpty ? .install : .blocked(drives: busy)
    }

    static func blockedTitle(_ drives: [String]) -> String {
        drives.count == 1 ? "“\(drives[0])” is in use" : "\(drives.count) drives are in use"
    }

    static func blockedMessage(_ drives: [String]) -> String {
        let which = drives.count == 1 ? "it" : drives.map { "“\($0)”" }.joined(separator: ", ")
        return "ParaAir ejects its drives before updating, and \(which) has files open. Close them, then choose Try Again. "
            + "Nothing has changed, and files waiting to upload stay on this Mac."
    }
}
