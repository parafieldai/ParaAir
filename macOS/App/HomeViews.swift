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
}

// MARK: - Home window

struct DriveHomeContent: View {
    let input: HomeInputs
    let details: HomeDetails
    @Binding var connectAutomatically: Bool
    let actions: HomeActions
    @State private var showsAdvanced = false

    private var presentation: HomePresentation { .make(input) }

    var body: some View {
        let presentation = self.presentation
        VStack(spacing: 0) {
            DriveHeader(name: input.driveName ?? "ParaAir", icon: details.driveIcon,
                        status: presentation.status, iconSize: 56, titleFont: .title2.bold())
                .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 6)
            Form {
                Section {
                    Text(presentation.status.detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ActionRow(presentation: presentation, actions: actions, large: true)
                }
                if !presentation.notices.isEmpty {
                    Section {
                        ForEach(presentation.notices) { NoticeRow(notice: $0) }
                    }
                }
                if !presentation.steps.isEmpty {
                    Section("Setup") {
                        ForEach(presentation.steps) { StepRow(step: $0) }
                    }
                }
                if input.hasDrive {
                    Section("Drive") {
                        LabeledContent("Storage", value: details.storageSummary ?? "Saved storage connection")
                        LabeledContent("In Finder") {
                            Text(input.mounted ? (details.mountPath ?? "Mounted") : "Not connected")
                                .font(input.mounted ? .body.monospaced() : .body)
                                .textSelection(.enabled)
                        }
                        HStack {
                            Button("Drive Appearance…", action: actions.editAppearance)
                                .disabled(!details.canEditAppearance)
                            Button("Storage Settings…", action: actions.openStorageSettings)
                        }
                    }
                }
                Section {
                    Toggle("Connect the drive when ParaAir opens", isOn: $connectAutomatically)
                    DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                        AdvancedControls(input: input, details: details, actions: actions)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 560, minHeight: 520)
    }
}

// MARK: - Menu bar panel

struct MenuBarPanel: View {
    let input: HomeInputs
    let details: HomeDetails
    @Binding var connectAutomatically: Bool
    let actions: HomeActions

    var body: some View {
        let presentation = HomePresentation.make(input)
        VStack(alignment: .leading, spacing: 12) {
            DriveHeader(name: input.driveName ?? "ParaAir", icon: details.driveIcon,
                        status: presentation.status, iconSize: 34, titleFont: .headline)
            if let notice = presentation.notices.first(where: { $0.tone == .problem || $0.tone == .attention }) {
                NoticeRow(notice: notice).lineLimit(4)
            }
            ActionRow(presentation: presentation, actions: actions, large: false)
            Divider()
            HStack(spacing: 8) {
                Button("Show ParaAir", action: actions.showHome)
                Button("Storage Settings…", action: actions.openStorageSettings)
            }
            Toggle("Connect the drive when ParaAir opens", isOn: $connectAutomatically)
                .toggleStyle(.checkbox)
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
                    GlideMark()
                }
            }
            .frame(width: iconSize, height: iconSize)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(titleFont).lineLimit(1).truncationMode(.middle)
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
        .foregroundStyle(.secondary)
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
        case .good: return .green
        case .working: return .secondary
        case .attention: return .orange
        case .problem: return .red
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
            .buttonStyle(.borderedProminent)
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

private struct NoticeRow: View {
    let notice: HomePresentation.Notice

    var body: some View {
        Label {
            Text(notice.text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } icon: {
            Image(systemName: notice.tone == .neutral ? "info.circle" : StatusLabel.symbol(notice.tone))
                .foregroundStyle(StatusLabel.color(notice.tone))
        }
        .font(.callout)
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
                Text(step.detail).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            switch step.state {
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .current: Image(systemName: "arrow.right.circle.fill").foregroundStyle(.tint)
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
