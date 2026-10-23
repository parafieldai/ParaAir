import SwiftUI
import AppKit

/// Callbacks into MenuModel. The views below hold no app state of their own, so the
/// same code renders in the app and in the offscreen snapshot harness.
struct HomeActions {
    var perform: (HomePresentation.Action) -> Void = { _ in }
    var checkAgain: () -> Void = {}
    var showHome: () -> Void = {}
    var openStorageSettings: () -> Void = {}
    var editAppearance: () -> Void = {}
    var openExtensionSettings: () -> Void = {}
    var chooseStateFolder: () -> Void = {}
    var addToSidebar: () -> Void = {}
    /// One entry per drive that keeps its metadata URI in Keychain (CLI-created profiles).
    var credentialTargets: [CredentialTarget] = []
    var refresh: () -> Void = {}
    var quit: () -> Void = {}
    /// ParaAir Cloud plan actions; they run in Storage Settings, where the plan sheet and errors show.
    var billing: (CloudBillingPresentation.Action) -> Void = { _ in }
    /// Sparkle's "Check for Updates…"; nil where the updater isn't available.
    var checkForUpdates: (() -> Void)?
}

struct CredentialTarget: Identifiable {
    let id: String
    let action: () -> Void
}

/// Values the views display beside the presentation.
struct HomeDetails {
    var driveIcon: NSImage?
    var storageSummary: String?
    var mountPath: String?
    var stateFolder: String
    var canEditAppearance = true
    var canChangeStateFolder = true
    var version = AppVersionText.current.line
}

// MARK: - Home window

struct DriveHomeContent: View {
    let input: HomeInputs
    let details: HomeDetails
    @Binding var connectAutomatically: Bool
    let actions: HomeActions
    var loginItem: LoginItemModel?
    /// Sparkle's automatic check setting; nil hides the toggle.
    var checkUpdatesAutomatically: Binding<Bool>?
    /// The snapshot harness opens Advanced to render its controls.
    var startsWithAdvancedOpen = false
    @State private var showsAdvanced = false

    private var presentation: HomePresentation { .make(input) }

    var body: some View {
        let presentation = self.presentation
        VStack(spacing: 0) {
            DriveHeader(name: input.driveName ?? "ParaAir", icon: details.driveIcon,
                        status: presentation.status, iconSize: 56, titleFont: .glideDisplay(.largeTitle))
                .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 6)
            Form {
                Section {
                    Text(presentation.status.detail)
                        .foregroundStyle(Glide.quiet)
                        .fixedSize(horizontal: false, vertical: true)
                    ActionRow(presentation: presentation, actions: actions, large: true)
                }
                if let update = input.updateTitle, let install = actions.checkForUpdates {
                    Section { UpdateReadyRow(title: update, install: install) }
                }
                if !presentation.notices.isEmpty {
                    Section {
                        ForEach(presentation.notices) { NoticeRow(notice: $0, perform: actions.perform) }
                    }
                }
                if !presentation.steps.isEmpty {
                    Section {
                        ForEach(presentation.steps) { StepRow(step: $0) }
                    } header: {
                        Text("Setup").font(.glideHeading).foregroundStyle(Glide.ink)
                    }
                }
                if input.hasDrive {
                    Section {
                        LabeledContent("Storage", value: details.storageSummary ?? "Saved storage connection")
                        if let cloud = input.cloudUsage {
                            PlanRows(usage: CloudUsagePresentation.make(cloud.workspace, state: cloud.state))
                            CloudBillingRows(billing: cloud.billing)
                        }
                        LabeledContent("In Finder") {
                            Text(input.mounted ? (details.mountPath ?? "Mounted") : "Not connected")
                                .font(input.mounted ? .body.monospaced() : .body)
                                .textSelection(.enabled)
                        }
                        HStack {
                            if let controls = input.cloudUsage?.billing.controls, !controls.isEmpty {
                                CloudBillingButtons(controls: controls, allowsProminence: false, perform: actions.billing)
                            }
                            Button("Drive Appearance…", action: actions.editAppearance)
                                .disabled(!details.canEditAppearance)
                            Button("Storage Settings…", action: actions.openStorageSettings)
                        }
                    } header: {
                        Text("Drive").font(.glideHeading).foregroundStyle(Glide.ink)
                    }
                }
                Section {
                    Toggle("Connect the drive when ParaAir opens", isOn: $connectAutomatically)
                        .glideControlTint()
                    if let loginItem { LoginItemToggle(model: loginItem) }
                    DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                        AdvancedControls(input: input, details: details, actions: actions,
                                         checkUpdatesAutomatically: checkUpdatesAutomatically)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .glideSurface()
        .frame(minWidth: 560, minHeight: 520)
        .onAppear { if startsWithAdvancedOpen { showsAdvanced = true } }
    }
}

// MARK: - Menu bar panel

struct MenuBarPanel: View {
    let input: HomeInputs
    let details: HomeDetails
    @Binding var connectAutomatically: Bool
    let actions: HomeActions
    var loginItem: LoginItemModel?

    var body: some View {
        let presentation = HomePresentation.make(input)
        VStack(alignment: .leading, spacing: 12) {
            DriveHeader(name: input.driveName ?? "ParaAir", icon: details.driveIcon,
                        status: presentation.status, iconSize: 34, titleFont: .glideDisplay(.title2, weight: .semibold))
            if let update = input.updateTitle, let install = actions.checkForUpdates {
                UpdateReadyRow(title: update, install: install, compact: true)
            }
            if let notice = presentation.notices.first(where: { $0.tone == .problem || $0.tone == .attention }) {
                NoticeRow(notice: notice, perform: actions.perform).lineLimit(4)
            }
            ActionRow(presentation: presentation, actions: actions, large: false)
            Divider()
            HStack(spacing: 8) {
                Button("Show ParaAir", action: actions.showHome)
                Button("Storage Settings…", action: actions.openStorageSettings)
            }
            Toggle("Connect the drive when ParaAir opens", isOn: $connectAutomatically)
                .toggleStyle(.checkbox)
                .glideControlTint()
            if let loginItem { LoginItemToggle(model: loginItem, style: .panel) }
            Divider()
            HStack {
                Menu("More") {
                    AdvancedMenuItems(input: input, details: details, actions: actions)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
                Button("Quit ParaAir", action: actions.quit)
            }
        }
        .padding(16)
        .frame(width: 320)
        .glideSurface()
    }
}

// MARK: - Shared pieces

private struct DriveHeader: View {
    let name: String
    let icon: NSImage?
    let status: HomePresentation.Status
    let iconSize: CGFloat
    let titleFont: Font

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable().scaledToFit()
                } else {
                    // The bare mark, as in the website's masthead: no tile behind it.
                    GlideMark(badge: false).padding(iconSize * 0.12)
                }
            }
            .frame(width: iconSize, height: iconSize)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(titleFont).foregroundStyle(Glide.ink).lineLimit(1).truncationMode(.middle)
                StatusLabel(status: status)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

struct StatusLabel: View {
    let status: HomePresentation.Status

    var body: some View {
        Label {
            Text(status.title)
        } icon: {
            Image(systemName: Self.symbol(status.tone)).foregroundStyle(Self.color(status.tone))
        }
        .font(.callout)
        .foregroundStyle(Glide.quiet)
    }

    static func symbol(_ tone: HomePresentation.Tone) -> String {
        switch tone {
        case .good: return "checkmark.circle.fill"
        case .working: return "clock.fill"
        case .attention: return "exclamationmark.triangle.fill"
        case .problem: return "xmark.octagon.fill"
        case .neutral: return "circle.dashed"
        }
    }

    static func color(_ tone: HomePresentation.Tone) -> Color {
        switch tone {
        case .good: return Glide.good
        case .working: return .secondary
        case .attention: return Glide.attention
        case .problem: return Glide.problem
        case .neutral: return .secondary
        }
    }
}

private struct ActionRow: View {
    let presentation: HomePresentation
    let actions: HomeActions
    let large: Bool

    var body: some View {
        HStack(spacing: 10) {
            Button {
                actions.perform(presentation.primary.action)
            } label: {
                Text(presentation.primary.title)
            }
            .buttonStyle(.glideProminent)
            .controlSize(large ? .large : .regular)
            .keyboardShortcut(.defaultAction)
            .disabled(!presentation.primary.enabled)
            if presentation.primary.busy {
                ProgressView().controlSize(.small).accessibilityLabel(presentation.status.title)
            }
            if presentation.offersCheckAgain {
                Button("Check Again", action: actions.checkAgain)
                    .controlSize(large ? .large : .regular)
            }
            if presentation.offersOpenInFinder {
                Button("Open in Finder") { actions.perform(.openInFinder) }
                    .controlSize(large ? .large : .regular)
            }
        }
    }
}

/// A gentle update reminder: the update a scheduled check found, and the button that brings
/// Sparkle's install window to the front.
struct UpdateReadyRow: View {
    let title: String
    let install: () -> Void
    var compact = false

    var body: some View {
        let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 10))
        layout {
            Label {
                Text("\(title) is ready to install.").fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Glide.good)
            }
            .font(.callout)
            if !compact { Spacer(minLength: 0) }
            Button("Install Update…", action: install)
                .controlSize(compact ? .small : .regular)
        }
        .accessibilityElement(children: .contain)
    }
}

struct NoticeRow: View {
    let notice: HomePresentation.Notice
    /// Runs the notice's action; without it the button is hidden.
    var perform: ((HomePresentation.Action) -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label {
                Text(notice.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: notice.tone == .neutral ? "info.circle" : StatusLabel.symbol(notice.tone))
                    .foregroundStyle(StatusLabel.color(notice.tone))
            }
            if let action = notice.action, let title = notice.actionTitle, let perform {
                Spacer(minLength: 0)
                Button(title) { perform(action) }.controlSize(.small)
            }
        }
        .font(.callout)
    }
}

/// The plan size leads; the used figure and its bar support it. Rows appear only when
/// `/v1/me` supplied the values, so a failed summary never shows as zero.
private struct PlanRows: View {
    let usage: CloudUsagePresentation

    var body: some View {
        if let plan = usage.planSize {
            LabeledContent("Plan") {
                Text(plan).font(.glideDisplay(.title2, weight: .semibold)).monospacedDigit().foregroundStyle(Glide.ink)
            }
        }
        if let used = usage.usedSize {
            LabeledContent("Used") {
                HStack(spacing: 10) {
                    if let fraction = usage.fraction {
                        ProgressView(value: fraction)
                            .tint(fraction >= 1 ? Glide.attention : Glide.controlTint)
                            .frame(width: 120)
                            .accessibilityHidden(true)
                    }
                    Text(used).monospacedDigit().frame(minWidth: 64, alignment: .trailing)
                }
            }
        }
    }
}

private struct StepRow: View {
    let step: HomePresentation.Step

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .fontWeight(step.state == .current ? .semibold : .regular)
                    .foregroundStyle(step.state == .upcoming ? .secondary : .primary)
                Text(step.detail).font(.caption).foregroundStyle(Glide.quiet)
            }
        } icon: {
            switch step.state {
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Glide.good)
            case .current: Image(systemName: "arrow.right.circle.fill").foregroundStyle(Glide.ink)
            case .upcoming: Image(systemName: "circle").foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(step.state == .done ? "Done" : step.state == .current ? "Next step" : "Not yet")
    }
}

private struct AdvancedControls: View {
    let input: HomeInputs
    let details: HomeDetails
    let actions: HomeActions
    var checkUpdatesAutomatically: Binding<Bool>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("File System Extension Settings…", action: actions.openExtensionSettings)
                if input.mounted { Button("Add to Finder Sidebar", action: actions.addToSidebar) }
            }
            HStack {
                Button("Choose State Folder…", action: actions.chooseStateFolder)
                    .disabled(!details.canChangeStateFolder)
                ForEach(actions.credentialTargets) { target in
                    Button(actions.credentialTargets.count > 1 ? "Metadata Credential for \(target.id)…" : "Metadata Credential…",
                           action: target.action)
                }
            }
            LabeledContent("State folder") {
                Text(details.stateFolder).font(.caption.monospaced()).textSelection(.enabled)
                    .lineLimit(2).truncationMode(.middle)
            }
            if let backup = input.indexBackup {
                LabeledContent("Index backup") { Text(backup.value).textSelection(.enabled) }
            }
            LabeledContent("Version") {
                HStack(spacing: 10) {
                    Text(details.version).monospacedDigit().textSelection(.enabled)
                    if let check = actions.checkForUpdates { Button("Check for Updates…", action: check) }
                }
            }
            if let checkUpdatesAutomatically {
                Toggle("Check for updates automatically", isOn: checkUpdatesAutomatically)
                    .toggleStyle(.checkbox)
                    .glideControlTint()
            }
        }
        .padding(.top, 6)
    }
}

private struct AdvancedMenuItems: View {
    let input: HomeInputs
    let details: HomeDetails
    let actions: HomeActions

    var body: some View {
        Button("Refresh Status", action: actions.refresh)
        if let check = actions.checkForUpdates { Button("Check for Updates…", action: check) }
        Button("File System Extension Settings…", action: actions.openExtensionSettings)
        if input.mounted { Button("Add to Finder Sidebar", action: actions.addToSidebar) }
        if input.hasDrive {
            Button("Drive Appearance…", action: actions.editAppearance).disabled(!details.canEditAppearance)
        }
        Divider()
        Button("Choose State Folder…", action: actions.chooseStateFolder).disabled(!details.canChangeStateFolder)
        ForEach(actions.credentialTargets) { target in
            Button(actions.credentialTargets.count > 1 ? "Metadata Credential for \(target.id)…" : "Metadata Credential…",
                   action: target.action)
        }
    }
}
