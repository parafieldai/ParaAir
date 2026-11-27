import SwiftUI
import AppKit
import StreamDriveCore

/// The everyday flow exposes the next action; configuration stays in settings.
/// Layout lives in HomeViews.swift; this adapter only reads MenuModel and routes actions.
@MainActor
struct DriveHomeView: View {
    @ObservedObject var model: MenuModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        DriveHomeContent(input: model.homeInputs(), details: model.homeDetails(),
                         connectAutomatically: $model.mountOnLaunch,
                         actions: model.homeActions(openWindow: openWindow), loginItem: model.loginItem,
                         checkUpdatesAutomatically: model.updater.isAvailable
                            ? Binding(get: { model.updater.automaticallyChecks }, set: { model.updater.automaticallyChecks = $0 }) : nil)
        .task { await model.refreshExtensionStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.resumeAfterSettings()
        }
        .sheet(isPresented: $model.reviewOpen) {
            ChangesReviewView(decisions: model.uploadActivity?.decisions ?? [],
                              ownerName: model.driveNotices?.ownedElsewhere.map { $0.ownerName ?? "another Mac" },
                              busyPath: model.resolvingPath, actions: model.reviewActions())
        }
        .sheet(isPresented: $model.appearanceOpen) {
            if let profile = model.profiles.first {
                DriveAppearanceView(profile: profile, stateRoot: model.stateRoot) { updated in
                    model.reload()
                    if model.isMounted(updated) { model.addToSidebar(updated, automatically: false) }
                }
            }
        }
    }
}

extension MenuModel {
    func homeInputs() -> HomeInputs {
        let profile = profiles.first
        let others = otherKnownDrives()
        // `mounting` is the one mount running at a time, in this folder or another; only the selected drive's counts here.
        let mountingSelected = mounting && (mountingFolder ?? stateRoot.path) == stateRoot.path
        return HomeInputs(
            driveName: profile?.finderName,
            storageSummary: profile.map(connectionSummary),
            mountPath: profile?.mountPoint,
            readyConnectionName: profile == nil ? readyConnection?.name : nil,
            credentialCheckFinished: credentialCheckFinished,
            connectionIssue: profile.flatMap(connectionIssue),
            renewalError: renewalError,
            extensionState: extensionState,
            checkingExtension: checkingExtension,
            extensionStillOff: extensionStillOff,
            extensionTurnedOff: extensionTurnedOff,
            otherCopies: otherAppCopies,
            mounted: profile.map(isMounted) ?? false,
            mounting: mountingSelected,
            otherMountRunning: mounting && !mountingSelected,
            creatingDrive: creatingDrive,
            error: error,
            mountMessage: mountMessage,
            mountFailed: mountFailed,
            needsVolumesApproval: profile.map(needsVolumesApproval) ?? false,
            mountMessageDrive: mountMessageFolder.flatMap { folder in
                folder == stateRoot.path ? profile?.finderName : otherFolderDrive(folder)?.profile.finderName
            },
            // Listed drives show their own problems; the old folder notice is left for a folder no longer listed.
            folderNotice: adoptionNotice ?? (others.isEmpty ? otherDriveNotice : nil),
            sidebarMessage: sidebarMessage,
            storageKind: profile?.backend == .paraairCloud ? .paraairCloud : .ownBucket,
            uploadActivity: profile == nil ? nil : uploadActivity,
            indexBackup: profile == nil ? nil : driveNotices?.indexBackup.map { IndexBackupLine.make($0, now: Date()) },
            ownedElsewhere: profile == nil ? nil : driveNotices?.ownedElsewhere.map { $0.ownerName ?? "another Mac" },
            cloudUsage: profile?.backend == .paraairCloud && cloudAccount.signedInAccount != nil ? cloudAccount.usage : nil,
            updateTitle: updater.pendingUpdateTitle,
            cloudUpdateRequired: cloudUpdateRequired,
            otherDrives: others)
    }

    func homeDetails() -> HomeDetails {
        let profile = profiles.first
        // A drive's own artwork when someone chose one; otherwise the header shows the bare mark,
        // not the default Finder icon, whose charcoal tile reads as a dark box on the panel.
        return HomeDetails(driveIcon: profile.flatMap { profile in
                               (try? DriveAppearance(stateRoot: stateRoot).customPNG(profile)).flatMap { $0 }.flatMap(NSImage.init(data:))
                           },
                           storageSummary: profile.map(connectionSummary),
                           mountPath: profile?.mountPoint,
                           stateFolder: stateRoot.path,
                           canEditAppearance: !mounting && !creatingDrive,
                           canChangeStateFolder: !mounting && !creatingDrive)
    }

    func homeActions(openWindow: OpenWindowAction) -> HomeActions {
        let profile = profiles.first
        func show(_ id: String) { openWindow(id: id); NSApp.activate(ignoringOtherApps: true) }
        let perform: (HomePresentation.Action) -> Void = { [weak self] action in
            guard let self else { return }
            switch action {
            case .addStorage: show("storage-settings")
            case .createDrive: self.createDriveFromReadyConnection()
            case .signInAgain:
                // Read now: a drive row may have just made another folder the selected one.
                let profile = self.profiles.first
                // ParaAir Cloud signs in from its own section; only saved connections reopen a form.
                if profile?.backend != .paraairCloud { self.pendingReconnectID = profile?.connectionID }
                show("storage-settings")
            case .openSystemSettings: self.openExtensionSettings()
            case .openLoginItems: self.openVolumesApproval()
            case .connectDrive: if let profile { self.continueSetup(profile) }
            case .openInFinder: if let profile { self.reveal(profile) }
            case .reviewChanges:
                show("connections")
                self.reviewOpen = true
            case .choosePlan:
                show("storage-settings")
                self.cloudAccount.perform(.choosePlan)
            case .showOtherCopies: self.showOtherCopies()
            // Only another folder's drive can be removed (the drive closure below handles it).
            case .removeFromList: break
            case .updateApp: self.updateApp()
            }
        }
        return HomeActions(
            perform: perform,
            // Another folder's drive: Open in Finder and Connect act on it where it is; Sign In Again… makes its folder
            // the selected one first, then takes the selected drive's sign-in route.
            drive: { [weak self] id, action in
                guard let self else { return }
                if id != HomePresentation.selectedDriveID {
                    guard let other = self.otherFolderDrive(id) else { return }
                    switch action {
                    case .openInFinder: self.reveal(other.profile); return
                    case .connectDrive: self.connectOther(other.profile, root: other.root); return
                    case .removeFromList: self.forgetKnownFolder(other.root); return
                    case .signInAgain: guard self.selectKnownFolder(other.root) else { return }
                    default: return
                    }
                }
                perform(action)
            },
            // Check Again asks FSKit again; with a drive it also resumes mounting once every gate is open.
            checkAgain: { [weak self] in
                guard let self else { return }
                if let profile { self.continueSetup(profile) }
                if self.extensionState != .enabled { Task { await self.checkExtensionAgain() } }
            },
            showHome: { show("connections") },
            openStorageSettings: { show("storage-settings") },
            editAppearance: { [weak self] in
                show("connections")
                self?.appearanceOpen = true
            },
            openExtensionSettings: { [weak self] in self?.openExtensionSettings() },
            chooseStateFolder: { [weak self] in self?.selectRoot() },
            addToSidebar: { [weak self] in if let profile { self?.addToSidebar(profile, automatically: false) } },
            credentialTargets: profiles.filter { $0.credentialID != nil }.map { target in
                CredentialTarget(id: target.name) { [weak self] in self?.setCredential(target) }
            },
            refresh: { [weak self] in
                self?.reload()
                Task { await self?.refreshExtensionStatus() }
            },
            quit: { [weak self] in self?.quit() },
            billing: { [weak self] action in
                show("storage-settings")
                self?.cloudAccount.perform(action)
            },
            checkForUpdates: updater.isAvailable ? { [weak self] in self?.updater.checkForUpdates() } : nil,
            support: .live(stateRoot: stateRoot, showAbout: { show("about") }))
    }
}
