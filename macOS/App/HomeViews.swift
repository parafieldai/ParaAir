import SwiftUI
import AppKit
import StreamDriveCore

/// Callbacks into MenuModel. The views below hold no app state of their own, so the
/// same code renders in the app and in the offscreen snapshot harness.
struct HomeActions {
    var perform: (HomePresentation.Action) -> Void = { _ in }
    /// A drive row's action, by the row's id (HomePresentation.selectedDriveID or the drive's state folder).
    var drive: (String, HomePresentation.Action) -> Void = { _, _ in }
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
        let listsDrives = !presentation.drives.isEmpty
        AirPage {
            // With several drives the header is ParaAir's, and its status sums them up; one drive's name or icon
            // would read as if its state were every drive's.
            VStack(alignment: .leading, spacing: 0) {
                DriveHeader(name: listsDrives ? "ParaAir" : input.driveName ?? "ParaAir", icon: listsDrives ? nil : details.driveIcon,
                            status: presentation.status, size: .window)
                VStack(alignment: .leading, spacing: 0) {
                    Text(presentation.status.detail)
                        .foregroundStyle(Air.quiet)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 380, alignment: .leading)
                        .padding(.top, Air.Space.md)
                        .id(presentation.status.detail)
                        .airTransition(.words)
                    if presentation.showsSwitchPicture, let picture = HomeImages.extensionSwitch {
                        Image(nsImage: picture)
                            .resizable().aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 435)
                            .clipShape(RoundedRectangle(cornerRadius: Air.Radius.inset, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: Air.Radius.inset, style: .continuous).strokeBorder(Air.cardEdge))
                            .padding(.top, Air.Space.lg)
                            .accessibilityLabel("System Settings, File System Extensions: \(ExtensionSetupGuidance.switchName), switched on")
                    }
                    if presentation.showsPrimary {
                        ActionRow(presentation: presentation, actions: actions, large: true).padding(.top, 20)
                    }
                }
                .padding(.leading, DriveHeader.Size.window.textInset)
            }
            .padding(.top, 6)

            if let update = input.updateTitle, let install = actions.checkForUpdates {
                AirSection { UpdateReadyRow(title: update, install: install) }
            }
            if listsDrives {
                AirSection {
                    ForEach(presentation.drives) { row in
                        DriveListRow(row: row, perform: actions.drive)
                    }
                } header: {
                    Text("Drives")
                }
            }
            if !presentation.notices.isEmpty {
                AirSection {
                    ForEach(presentation.notices) { NoticeRow(notice: $0, perform: actions.perform) }
                }
            }
            if !presentation.steps.isEmpty {
                AirSection {
                    ForEach(presentation.steps) { StepRow(step: $0) }
                } header: {
                    Text("Setup")
                }
            }
            if input.hasDrive {
                AirSection {
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
                    AirFlow {
                        // Not again here when the drive status already leads with choosing a plan.
                        if let controls = input.cloudUsage?.billing.controls.filter({ $0.action != .choosePlan || presentation.primary.action != .choosePlan }),
                           !controls.isEmpty {
                            CloudBillingButtons(controls: controls, allowsProminence: false, perform: actions.billing)
                        }
                        Button("Drive Appearance…", action: actions.editAppearance)
                            .disabled(!details.canEditAppearance)
                        Button("Storage Settings…", action: actions.openStorageSettings)
                    }
                } header: {
                    // Beside other drives, these details are the selected folder's drive: say which one.
                    Text(listsDrives ? input.driveName ?? "Drive" : "Drive")
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            AirSection {
                Toggle(Self.connectAutomaticallyTitle(listsDrives: listsDrives), isOn: $connectAutomatically)
                if let loginItem { LoginItemToggle(model: loginItem) }
                DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                    AdvancedControls(input: input, details: details, actions: actions,
                                     checkUpdatesAutomatically: checkUpdatesAutomatically)
                }
            }
        }
        // Rows, notices and sections that come and go settle into place; the state's words blur across.
        .airAnimation(AirMotion.settle, value: Self.motionKey(presentation))
        .airSurface()
        .frame(minWidth: 560, minHeight: 520)
        .onAppear { if startsWithAdvancedOpen { showsAdvanced = true } }
    }

    /// What changes the layout: the status and the lists' members.
    static func motionKey(_ presentation: HomePresentation) -> [String] {
        [presentation.status.title, presentation.status.detail, presentation.primary.title]
            + presentation.drives.map { "\($0.id):\($0.stateTitle)" } + presentation.notices.map(\.id)
            + presentation.steps.map { "\($0.id):\($0.state)" }
    }

    /// The setting connects the selected folder's drive and the drives kept for login alike.
    static func connectAutomaticallyTitle(listsDrives: Bool) -> String {
        listsDrives ? "Connect drives when ParaAir opens" : "Connect the drive when ParaAir opens"
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
        let listsDrives = !presentation.drives.isEmpty
        VStack(alignment: .leading, spacing: 14) {
            DriveHeader(name: listsDrives ? "ParaAir" : input.driveName ?? "ParaAir", icon: listsDrives ? nil : details.driveIcon,
                        status: presentation.status, size: .panel)
            if let update = input.updateTitle, let install = actions.checkForUpdates {
                UpdateReadyRow(title: update, install: install, compact: true)
            }
            if let notice = presentation.notices.first(where: { $0.tone == .problem || $0.tone == .attention }) {
                NoticeRow(notice: notice, perform: actions.perform).lineLimit(4)
            }
            if presentation.showsPrimary { ActionRow(presentation: presentation, actions: actions, large: false) }
            if listsDrives {
                // The list's closing hairline is the panel's rule here.
                AirRows {
                    ForEach(presentation.drives) { row in
                        DriveListRow(row: row, compact: true, perform: actions.drive)
                    }
                }
            } else {
                AirHairline()
            }
            HStack(spacing: Air.Space.sm) {
                Button("Show ParaAir", action: actions.showHome)
                Button("Storage Settings…", action: actions.openStorageSettings)
            }
            .controlSize(.small)
            VStack(alignment: .leading, spacing: 10) {
                Toggle(DriveHomeContent.connectAutomaticallyTitle(listsDrives: listsDrives), isOn: $connectAutomatically)
                if let loginItem { LoginItemToggle(model: loginItem, style: .panel) }
            }
            .controlSize(.small)
            AirHairline()
            HStack {
                Menu {
                    AdvancedMenuItems(input: input, details: details, actions: actions)
                } label: {
                    HStack(spacing: 4) {
                        Text("More")
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    }
                }
                .menuStyle(.button)
                .buttonStyle(.airText)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More")
                Spacer()
                Button("Quit ParaAir", action: actions.quit).buttonStyle(.airText)
            }
        }
        .padding(18)
        .frame(width: 320)
        .airAnimation(AirMotion.settle, value: DriveHomeContent.motionKey(presentation))
        .airSurface()
    }
}

// MARK: - Shared pieces

/// The drive's name in ink with the sage line the lead plane drew beneath it, its state on a quiet line below, and in
/// the window the planes in the open paper beside them. When the state changes, the new words come out of a blur.
private struct DriveHeader: View {
    enum Size {
        case window, panel
        var display: CGFloat { self == .window ? Air.Size.hero : Air.Size.panel }
        var icon: CGFloat { self == .window ? 46 : 30 }
        var gap: CGFloat { self == .window ? 16 : 12 }
        /// Where the text column starts, so what follows the header lines up under the name.
        var textInset: CGFloat { icon + gap }
    }

    let name: String
    let icon: NSImage?
    let status: HomePresentation.Status
    let size: Size

    var body: some View {
        HStack(alignment: .top, spacing: size.gap) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable().scaledToFit()
                } else {
                    // With no drive icon, the bare mark stands in, quiet in the flock's greys, so the lead plane in ink and
                    // sage is the one mark in the header.
                    ParaAirMark(badge: false, quiet: true).padding(size.icon * 0.08)
                }
            }
            .frame(width: size.icon, height: size.icon)
            .padding(.top, size == .window ? 4 : 1)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: size == .window ? 11 : 8) {
                Text(name)
                    .airDisplay(size.display)
                    .foregroundStyle(Air.ink)
                    .lineLimit(1).truncationMode(.middle)
                    .minimumScaleFactor(0.8)
                    .airUnderlined()
                StatusLine(status: status, size: size == .window ? 15 : 13)
                    .id(status.title)
                    .airTransition(.words)
            }
            Spacer(minLength: 0)
        }
        .airFlight(size == .window ? .window : .panel, seed: name, entrance: size == .window)
        .accessibilityElement(children: .combine)
    }
}

/// The state under the name: the tone's symbol, then the state in the quiet tone, shimmering while work is under way.
private struct StatusLine: View {
    let status: HomePresentation.Status
    let size: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: size * 0.4) {
            Image(systemName: StatusLabel.symbol(status.tone))
                .font(.system(size: size * 0.9, weight: .semibold))
                .foregroundStyle(StatusLabel.color(status.tone))
                .accessibilityHidden(true)
            Text(status.title)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(Air.quiet)
                .airShimmer(status.tone == .working)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct StatusLabel: View {
    let status: HomePresentation.Status

    var body: some View {
        Label {
            Text(status.title).airShimmer(status.tone == .working)
        } icon: {
            Image(systemName: Self.symbol(status.tone)).foregroundStyle(Self.color(status.tone))
        }
        .font(.callout)
        .foregroundStyle(Air.quiet)
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
        case .good: return Air.good
        case .working: return Air.quiet
        case .attention: return Air.attention
        case .problem: return Air.problem
        case .neutral: return Air.quiet
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
            .buttonStyle(.airProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!presentation.primary.enabled)
            if presentation.primary.busy {
                ProgressView().controlSize(.small).accessibilityLabel(presentation.status.title)
            }
            if presentation.offersCheckAgain {
                Button("Check Again", action: actions.checkAgain)
            }
            if presentation.offersTryAgain {
                Button("Try Again") { actions.perform(.connectDrive) }
                    .controlSize(large ? .large : .regular)
            }
            if presentation.offersOpenInFinder {
                Button("Open in Finder") { actions.perform(.openInFinder) }
            }
        }
        .controlSize(large ? .large : .regular)
    }
}

/// One drive: its Finder name and storage, its state, and the one action that state needs. In the window the state and
/// the action sit in fixed columns, so they line up from row to row whatever the names; the menu bar panel puts the
/// state under the name.
struct DriveListRow: View {
    let row: HomePresentation.DriveRow
    var compact = false
    let perform: (String, HomePresentation.Action) -> Void
    @State private var confirmingRemoval = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: compact ? 3 : 2) {
                Text(row.name).fontWeight(.medium).foregroundStyle(Air.ink)
                    .lineLimit(1).truncationMode(.middle)
                if compact {
                    stateLabel.font(.caption)
                } else {
                    Text(row.storage).font(.caption).foregroundStyle(Air.quiet)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            if !compact {
                stateLabel.font(.callout).frame(width: 128, alignment: .leading)
            }
            action.frame(width: compact ? nil : 132, alignment: .trailing)
            if !compact {
                // A fixed column, so the actions line up whether or not a row can be removed.
                more.frame(width: 22)
            }
        }
        .airTransition(.item)
        .accessibilityElement(children: .contain)
        .contextMenu {
            if row.removable { Button("Remove from List…") { confirmingRemoval = true } }
        }
        .confirmationDialog("Remove \(row.name) from ParaAir?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Remove from List", role: .destructive) { perform(row.id, .removeFromList) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("ParaAir stops listing, connecting and renewing this drive. Its files in storage and its state folder on this Mac stay; "
                 + "Choose State Folder… brings it back.")
        }
    }

    @ViewBuilder private var more: some View {
        if row.removable {
            Menu {
                Button("Remove from List…") { confirmingRemoval = true }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More for \(row.name)")
            .help("More for \(row.name)")
        } else {
            Color.clear.frame(height: 1).accessibilityHidden(true)
        }
    }

    private var stateLabel: some View {
        Label {
            Text(row.stateTitle).airShimmer(row.state == .connecting)
        } icon: {
            Image(systemName: StatusLabel.symbol(row.tone)).foregroundStyle(StatusLabel.color(row.tone))
        }
        .foregroundStyle(Air.quiet)
        .lineLimit(1)
    }

    @ViewBuilder private var action: some View {
        if let action = row.action, let title = row.actionTitle {
            let button = Button(title) { perform(row.id, action) }
                .controlSize(.small)
                .disabled(!row.enabled)
            if row.switchesFolder {
                button.help("Shows \(row.name)’s state folder in ParaAir, then opens Storage Settings.")
            } else {
                button
            }
        } else if row.state == .connecting {
            ProgressView().controlSize(.small).accessibilityLabel("\(row.name) is connecting")
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
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Air.good)
            }
            .font(.callout)
            if !compact { Spacer(minLength: 0) }
            Button("Install Update…", action: install)
                .controlSize(.small)
        }
        .airTransition(.item)
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
        .foregroundStyle(Air.ink)
        .airTransition(.item)
    }
}

/// The plan size, then the used figure and its meter, set like every other Drive row. Rows appear
/// only when `/v1/me` supplied the values, so a failed summary never shows as zero.
private struct PlanRows: View {
    let usage: CloudUsagePresentation

    var body: some View {
        if let plan = usage.planSize {
            LabeledContent {
                Text(plan).monospacedDigit()
            } label: {
                Text("Plan")
                if let scope = usage.scopeLine { Text(scope) }
            }
        }
        if let used = usage.usedSize {
            LabeledContent("Used") {
                HStack(spacing: 10) {
                    if let fraction = usage.fraction {
                        AirMeter(fraction: fraction, tone: fraction >= 1 ? Air.attention : Air.ink)
                            .frame(width: 120)
                    }
                    Text(used).monospacedDigit().frame(minWidth: 64, alignment: .trailing)
                }
            }
        }
    }
}

/// One setup step, numbered like a list of steps on the website: the number, the step and its note, and a mark for
/// where the step stands.
private struct StepRow: View {
    let step: HomePresentation.Step

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Air.Space.lg) {
            Text(String(format: "%02d", step.id))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(Air.quiet)
                .frame(width: 20, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(step.title)
                    .font(.system(size: 14, weight: step.state == .current ? .medium : .regular))
                    .tracking(-0.1)
                    .foregroundStyle(step.state == .upcoming ? Air.quiet : Air.ink)
                Text(step.detail).font(.callout).foregroundStyle(Air.quiet)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Group {
                switch step.state {
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Air.good)
                case .current: Image(systemName: "arrow.right.circle.fill").foregroundStyle(Air.ink)
                case .upcoming: Image(systemName: "circle").foregroundStyle(Air.quiet.opacity(0.6))
                }
            }
            .font(.system(size: 15))
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
        VStack(alignment: .leading, spacing: 12) {
            AirFlow {
                Button("File System Extension Settings…", action: actions.openExtensionSettings)
                if input.mounted { Button("Add to Finder Sidebar", action: actions.addToSidebar) }
            }
            AirFlow {
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
                    if let check = actions.checkForUpdates { Button("Check for Updates…", action: check).controlSize(.small) }
                }
            }
            if let checkUpdatesAutomatically {
                Toggle("Check for updates automatically", isOn: checkUpdatesAutomatically)
            }
        }
        .controlSize(.small)
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

/// Pictures the home window shows. The snapshot harness points them at the repository's copies.
enum HomeImages {
    /// The owner's screenshot of System Settings (macOS 27): File System Extensions with ParaAir file system on.
    static var extensionSwitch: NSImage? = Bundle.main.url(forResource: "ExtensionSwitch", withExtension: "png").flatMap(load)

    /// A 2x screenshot shown at its point size.
    static func load(_ url: URL) -> NSImage? {
        guard let image = NSImage(contentsOf: url), let rep = image.representations.first else { return nil }
        image.size = NSSize(width: CGFloat(rep.pixelsWide) / 2, height: CGFloat(rep.pixelsHigh) / 2)
        return image
    }
}
