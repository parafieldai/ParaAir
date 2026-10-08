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
                         actions: model.homeActions(openWindow: openWindow))
        .task { await model.refreshExtensionStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.resumeAfterSettings()
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
            mounted: profile.map(isMounted) ?? false,
            mounting: mounting,
            creatingDrive: creatingDrive,
            error: error,
            mountMessage: mountMessage,
            sidebarMessage: sidebarMessage)
    }

    func homeDetails() -> HomeDetails {
        let profile = profiles.first
        return HomeDetails(driveIcon: profile.map { DriveAppearance(stateRoot: stateRoot).image($0) },
                           storageSummary: profile.map(connectionSummary),
                           mountPath: profile?.mountPoint,
                           stateFolder: stateRoot.path,
                           canEditAppearance: !mounting && !creatingDrive,
                           canChangeStateFolder: !mounting && !creatingDrive)
    }

    func homeActions(openWindow: OpenWindowAction) -> HomeActions {
        let profile = profiles.first
        func show(_ id: String) { openWindow(id: id); NSApp.activate(ignoringOtherApps: true) }
        return HomeActions(
            perform: { [weak self] action in
                guard let self else { return }
                switch action {
                case .addStorage: show("storage-settings")
                case .createDrive: self.createDriveFromReadyConnection()
                case .signInAgain:
                    self.pendingReconnectID = profile?.connectionID
                    show("storage-settings")
                case .openSystemSettings: self.openExtensionSettings()
                case .connectDrive: if let profile { self.continueSetup(profile) }
                case .openInFinder: if let profile { self.reveal(profile) }
                }
            },
            checkAgain: { [weak self] in if let profile { self?.continueSetup(profile) } },
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
            quit: { [weak self] in self?.quit() })
    }
}
