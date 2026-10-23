import AppKit
import Darwin
import StreamDriveCore

/// The review sheet's actions: each asks first, then runs the engine's decision off the
/// main actor with this process's own Engine, and refreshes the upload activity.
@MainActor
extension MenuModel {
    func reviewActions() -> ReviewActions {
        ReviewActions(saveCopy: { [weak self] in self?.saveCopy($0) },
                      export: { [weak self] in self?.exportCopy($0) },
                      discard: { [weak self] in self?.discardCopy($0) },
                      done: { [weak self] in self?.reviewOpen = false })
    }

    private func saveCopy(_ decision: PendingDecision) {
        guard let profile = profiles.first, resolvingPath == nil else { return }
        let root = stateRoot
        resolvingPath = decision.path
        Task {
            // Listing the folder may reach storage, so the suggestion is made off the main actor.
            let suggested = await Task.detached(priority: .userInitiated) {
                try? Engine.open(profile: profile, stateRoot: root).suggestedCopyName(for: decision.path)
            }.value
            resolvingPath = nil
            // Offline, the folder can't be listed: suggest the dated name anyway; a taken name is refused later.
            let fallback = Engine.copyName(decision.name, date: Date()) { _ in false }
            guard root == stateRoot, let name = ReviewPrompts.askCopyName(decision, suggested: suggested ?? fallback) else { return }
            resolve(decision, profile: profile, root: root) { try $0.keepMine(decision.path, as: name) }
        }
    }

    private func exportCopy(_ decision: PendingDecision) {
        guard let profile = profiles.first, resolvingPath == nil else { return }
        let panel = NSSavePanel()
        panel.title = "Export Your Copy"
        panel.message = "ParaAir saves your copy of “\(decision.name)” here and removes it from the drive’s waiting changes."
        panel.nameFieldStringValue = decision.name
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // The panel already confirmed replacing an existing file.
        resolve(decision, profile: profile, root: stateRoot) { try $0.exportChange(decision.path, to: url, replacing: true) }
    }

    private func discardCopy(_ decision: PendingDecision) {
        guard let profile = profiles.first, resolvingPath == nil else { return }
        guard ReviewPrompts.discardAlert(decision).runModal() == .alertFirstButtonReturn else { return }
        resolve(decision, profile: profile, root: stateRoot) { try $0.keepTheirs(decision.path) }
    }

    private func resolve(_ decision: PendingDecision, profile: DriveProfile, root: URL, _ work: @escaping @Sendable (Engine) throws -> Void) {
        resolvingPath = decision.path
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { try work(try Engine.open(profile: profile, stateRoot: root)) }
            }.value
            resolvingPath = nil
            if case .failure(let error) = outcome, root == stateRoot {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "ParaAir couldn’t finish “\(decision.name)”"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
            _ = await activity.refreshNow()
        }
    }
}
