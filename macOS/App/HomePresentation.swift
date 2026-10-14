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
    var mounted = false
    var mounting = false
    var creatingDrive = false
    var error: String?
    var mountMessage: String?
    /// A waiting folder switch, or a drive in another state folder that didn't connect at login.
    var folderNotice: String?
    var sidebarMessage: String?
    var storageKind: StorageKind = .ownBucket
    var uploadActivity: UploadActivity?
    var cloudUsage: CloudUsage?

    var hasDrive: Bool { driveName != nil }
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
    enum Action: Equatable {
        case addStorage, createDrive, signInAgain, openSystemSettings, connectDrive, openInFinder
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
    }

    var status: Status
    var primary: Primary
    var offersCheckAgain = false
    var offersOpenInFinder = false
    var steps: [Step] = []
    var notices: [Notice] = []

    static func make(_ input: HomeInputs) -> HomePresentation {
        let drive = input.driveName ?? "your drive"
        let storageOK = input.hasDrive && input.credentialCheckFinished && input.connectionIssue == nil
        var result: HomePresentation

        if !input.hasDrive {
            if input.creatingDrive {
                result = .init(status: .init(title: "Creating your drive…",
                                             detail: "ParaAir is preparing the drive on this Mac.", tone: .working),
                               primary: .init(action: .createDrive, title: "Creating…", enabled: false, busy: true))
            } else if let connection = input.readyConnectionName {
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
            } else if input.storageKind == .paraairCloud, input.cloudUsage?.workspace?.status == "read_only" {
                // The service refuses uploads, commits and new folders (403 read_only); reads, deletes, moves and
                // restores from the trash keep working (contract README "Billing"; subscription policy 16.1).
                result = .init(status: .init(title: "Connected, read-only",
                                             detail: "You can open, download, move and delete files. New and changed files don’t upload.",
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
        } else if input.checkingExtension {
            result = .init(status: .init(title: "Checking System Settings…",
                                         detail: "Looking for ParaAir’s file system extension.", tone: .working),
                           primary: .init(action: .openSystemSettings, title: "Open System Settings", enabled: false, busy: true))
        } else if input.extensionState != .enabled {
            result = .init(status: extensionStatus(input.extensionState),
                           primary: .init(action: .openSystemSettings, title: "Open System Settings"),
                           offersCheckAgain: true)
        } else {
            result = .init(status: .init(title: "Not connected",
                                         detail: "Your storage is ready. Connect the drive to use it in Finder.", tone: .neutral),
                           primary: .init(action: .connectDrive, title: "Connect Drive"))
        }

        if !input.mounted {
            let storageDone = storageOK || (!input.hasDrive && input.readyConnectionName != nil)
            let enabled = input.extensionState == .enabled
            result.steps = [
                .init(id: 1, title: "Add your storage",
                      detail: input.hasDrive && input.credentialCheckFinished && input.connectionIssue != nil
                          ? "Sign in again in Storage Settings." : "ParaAir Cloud, Cloudflare R2 or another S3-compatible bucket.",
                      state: storageDone ? .done : (input.hasDrive && !input.credentialCheckFinished ? .upcoming : .current)),
                .init(id: 2, title: "Create your drive", detail: "Name it however you like.",
                      state: input.hasDrive ? .done : (storageDone ? .current : .upcoming)),
                .init(id: 3, title: "Turn on ParaAir in System Settings",
                      detail: "General → Login Items & Extensions → File System Extensions.",
                      state: enabled ? .done : (storageOK ? .current : .upcoming)),
                .init(id: 4, title: "Open it in Finder", detail: "It appears under Locations, like any drive.",
                      state: input.mounted ? .done : (storageOK && enabled ? .current : .upcoming)),
            ]
        }

        if let error = input.error { result.notices.append(.init(id: "error", text: error, tone: .problem)) }
        if let message = input.mountMessage { result.notices.append(.init(id: "mount", text: message, tone: .attention)) }
        if let notice = input.folderNotice { result.notices.append(.init(id: "folder", text: notice, tone: .attention)) }
        if let renewal = input.renewalError, input.connectionIssue == nil {
            result.notices.append(.init(id: "renewal", text: renewal, tone: .attention))
        }
        if let billing = input.cloudUsage?.billing.notice, input.storageKind == .paraairCloud { result.notices.append(billing) }
        if let message = input.sidebarMessage { result.notices.append(.init(id: "sidebar", text: message, tone: .neutral)) }
        if let activity = input.uploadActivity {
            result.notices += uploadNotices(activity, cloud: input.storageKind == .paraairCloud, accessIssue: input.connectionIssue != nil)
        }
        return result
    }

    /// Problems first. Quota and sign-in wording is specific to ParaAir Cloud. Files waiting
    /// for a sign-in count as waiting when the status above already asks for one, and for
    /// your own bucket, whose access the storage status explains.
    private static func uploadNotices(_ activity: UploadActivity, cloud: Bool, accessIssue: Bool) -> [Notice] {
        var notices: [Notice] = []
        let signIn = cloud && !accessIssue
        if signIn, activity.blockedAuth > 0 {
            notices.append(.init(id: "upload-sign-in", text: UploadNotices.signIn(activity.blockedAuth), tone: .attention))
        }
        if cloud, activity.blockedQuota > 0 {
            notices.append(.init(id: "upload-quota", text: UploadNotices.quota(activity.blockedQuota), tone: .attention))
        }
        if activity.conflicts > 0 {
            notices.append(.init(id: "upload-conflicts", text: UploadNotices.conflicts(activity.conflicts), tone: .attention))
        }
        let waiting = activity.waiting + activity.failedOther + (cloud ? 0 : activity.blockedQuota) + (signIn ? 0 : activity.blockedAuth)
        if waiting > 0 { notices.append(.init(id: "upload-waiting", text: UploadNotices.waiting(waiting), tone: .neutral)) }
        return notices
    }

    private static func extensionStatus(_ state: FinderExtensionState) -> Status {
        switch state {
        case .disabled:
            return .init(title: "Turn on ParaAir in System Settings",
                         detail: "macOS asks once. Under File System Extensions, switch on ParaAir, then come back here.",
                         tone: .attention)
        case .notDiscovered:
            return .init(title: "macOS hasn’t listed ParaAir yet",
                         detail: "Open File System Extensions in System Settings. If ParaAir is missing, reinstall the app and check again.",
                         tone: .attention)
        case .ambiguous:
            return .init(title: "Another copy of ParaAir is installed",
                         detail: "Keep only one copy of ParaAir on this Mac, then check again.", tone: .attention)
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
    static func notUploaded(_ count: Int) -> String {
        count == 1 ? "1 file on this Mac hasn’t uploaded yet." : "\(count) files on this Mac haven’t uploaded yet."
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

    static let unavailable = "Plan and usage are unavailable right now."
    static let checking = "Checking plan and usage…"

    static func make(_ workspace: ParaAirCloudMe.Workspace?, state: CloudSummaryState) -> CloudUsagePresentation {
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
