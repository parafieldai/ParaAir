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
    var sidebarMessage: String?

    var hasDrive: Bool { driveName != nil }
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
                                             detail: "Connect a storage bucket once. ParaAir sets up the drive, its cache and Finder.",
                                             tone: .neutral),
                               primary: .init(action: .addStorage, title: "Add Storage…"))
            }
        } else if input.mounted {
            if let issue = input.connectionIssue {
                result = .init(status: .init(title: "Storage access interrupted",
                                             detail: issue + " Files that aren’t on this Mac can’t open until access returns; your changes are kept and upload afterwards.",
                                             tone: .attention),
                               primary: .init(action: .signInAgain, title: "Sign In Again…"),
                               offersOpenInFinder: true)
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
                          ? "Sign in again in Storage Settings." : "Cloudflare R2 or another S3-compatible bucket.",
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
        if let renewal = input.renewalError, input.connectionIssue == nil {
            result.notices.append(.init(id: "renewal", text: renewal, tone: .attention))
        }
        if let message = input.sidebarMessage { result.notices.append(.init(id: "sidebar", text: message, tone: .neutral)) }
        return result
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
