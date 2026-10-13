import SwiftUI
import AppKit
import ServiceManagement
import os
import StreamDriveCore

/// The one seam to ServiceManagement. The app uses `SystemLoginItemService`; the
/// snapshot harness injects a fixed status and never registers anything.
@MainActor
protocol LoginItemService {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

@MainActor
struct SystemLoginItemService: LoginItemService {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// "Open ParaAir at login", read live from the service. A change made here counts as
/// the person's choice, so the launch default never runs again.
@MainActor
final class LoginItemModel: ObservableObject {
    @Published private(set) var status: LoginItemStatus
    /// The last change made here didn't take.
    @Published private(set) var changeFailed = false
    private let service: LoginItemService
    private let rememberChoice: () -> Void
    static let log = Logger(subsystem: "dev.streamdrive.app", category: "install")

    init(service: LoginItemService,
         rememberChoice: @escaping () -> Void = { UserDefaults.standard.set(true, forKey: LoginItemDefault.appliedKey) }) {
        self.service = service
        self.rememberChoice = rememberChoice
        status = service.status
    }

    var isOn: Bool { status == .enabled }
    var needsApproval: Bool { status == .requiresApproval }

    func refresh() {
        let current = service.status
        if current != status { status = current }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isOn else { return }
        rememberChoice()
        do {
            if enabled { try service.register() } else { try service.unregister() }
            changeFailed = false
        } catch {
            changeFailed = true
            let code = (error as NSError).code
            Self.log.error("login item \(enabled ? "register" : "unregister", privacy: .public) failed code=\(code)")
        }
        refresh()
        Self.log.notice("login item set by person enabled=\(enabled) status=\(self.status.rawValue, privacy: .public)")
    }

    func openSystemSettings() { service.openSystemSettings() }

    /// Registers ParaAir once, the first time it runs from an Applications folder.
    /// Never called by the snapshot harness or tests.
    static func applyLaunchDefault(location: InstallLocation, service: LoginItemService,
                                   preferences: UserDefaults = .standard) {
        let applied = preferences.bool(forKey: LoginItemDefault.appliedKey)
        let status = service.status
        let decision = LoginItemDefault.decide(location: location, alreadyApplied: applied, status: status)
        log.notice("login item default decision=\(String(describing: decision), privacy: .public) location=\(location.rawValue, privacy: .public) applied=\(applied) status=\(status.rawValue, privacy: .public)")
        switch decision {
        case .skip: return
        case .recordOnly: break
        case .register:
            do {
                try service.register()
                log.notice("login item default registered status=\(service.status.rawValue, privacy: .public)")
            } catch {
                log.error("login item default register failed code=\((error as NSError).code)")
            }
        }
        // Recorded after one attempt, so a person who turns it off later is never overridden.
        preferences.set(true, forKey: LoginItemDefault.appliedKey)
    }
}

/// The toggle beside "Connect the drive when ParaAir opens": a form row in the home
/// window, a checkbox in the menu bar panel.
struct LoginItemToggle: View {
    enum Style { case form, panel }

    @ObservedObject var model: LoginItemModel
    var style: Style = .form

    static let title = "Open ParaAir at login"
    static let approvalNote = "Allowed in System Settings only."
    static let failureNote = "Couldn’t change this here."
    static let settingsButton = "Open Login Items…"

    private var note: String? {
        model.needsApproval ? Self.approvalNote : model.changeFailed ? Self.failureNote : nil
    }

    private var isOn: Binding<Bool> {
        Binding(get: { model.isOn }, set: { model.setEnabled($0) })
    }

    var body: some View {
        switch style {
        case .form:
            Toggle(Self.title, isOn: isOn)
                .glideControlTint()
                .disabled(model.needsApproval)
                .modifier(LiveLoginItemStatus(model: model))
            if let note {
                LabeledContent {
                    Button(Self.settingsButton, action: model.openSystemSettings)
                } label: {
                    Text(note).foregroundStyle(Glide.quiet)
                }
            }
        case .panel:
            VStack(alignment: .leading, spacing: 6) {
                Toggle(Self.title, isOn: isOn)
                    .toggleStyle(.checkbox)
                    .glideControlTint()
                    .disabled(model.needsApproval)
                if let note {
                    // Stacked: the panel is too narrow for the note and the button on one line.
                    VStack(alignment: .leading, spacing: 6) {
                        Text(note).font(.callout).foregroundStyle(Glide.quiet)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(Self.settingsButton, action: model.openSystemSettings)
                            .controlSize(.small)
                    }
                    .padding(.leading, 20)
                }
            }
            .modifier(LiveLoginItemStatus(model: model))
        }
    }
}

/// Re-reads the status whenever the view appears or ParaAir becomes active, which is
/// when a change made in System Settings shows up.
private struct LiveLoginItemStatus: ViewModifier {
    let model: LoginItemModel

    func body(content: Content) -> some View {
        content
            .onAppear { model.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                model.refresh()
            }
    }
}
