import SwiftUI
import AppKit

/// Callbacks into MenuModel for the review sheet.
struct ReviewActions {
    /// Conflicts: keep this Mac's copy as a new file beside the original.
    var saveCopy: (PendingDecision) -> Void = { _ in }
    /// Refused changes: save this Mac's copy to a folder outside the drive.
    var export: (PendingDecision) -> Void = { _ in }
    /// Drop this Mac's copy, after confirming.
    var discard: (PendingDecision) -> Void = { _ in }
    var done: () -> Void = {}
}

/// Conflicts and changes storage refuses never upload by themselves. Each row offers
/// keeping this Mac's copy (beside the original, or exported for a drive that refuses new
/// files) or the version in storage.
struct ChangesReviewView: View {
    let decisions: [PendingDecision]
    /// The Mac that took over the drive, for refused changes.
    var ownerName: String?
    /// The file whose action is running; every row waits for it.
    var busyPath: String?
    var now = Date()
    let actions: ReviewActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Changes to Review").airDisplay(Air.Size.title).foregroundStyle(Air.ink)
                Text("These changes can’t upload by themselves. Choose what to keep for each file; until then, your copy stays on this Mac.")
                    .foregroundStyle(Air.quiet)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Air.Space.xl).padding(.top, 22).padding(.bottom, Air.Space.lg)
            ScrollView {
                AirRows {
                    if decisions.isEmpty {
                        Label("Nothing left to review.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Air.quiet)
                            .airTransition(.item)
                    } else {
                        ForEach(decisions) { decision in
                            ReviewRow(decision: decision, detail: detail(decision), busy: busyPath == decision.path,
                                      enabled: busyPath == nil, actions: actions)
                        }
                    }
                }
                .padding(.horizontal, Air.Space.xl).padding(.bottom, Air.Space.xl)
            }
            .airAnimation(AirMotion.settle, value: decisions.map(\.path))
            HStack {
                Spacer()
                Button("Done", action: actions.done).buttonStyle(.airProminent).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, Air.Space.xl).padding(.bottom, 18).padding(.top, 4)
        }
        .airSurface()
        .frame(width: 640, height: 420)
    }

    /// Why the change waits, where it is, its size and when it was made.
    private func detail(_ decision: PendingDecision) -> String {
        var parts: [String] = []
        switch decision.kind {
        case .conflict: parts.append("Changed on another device")
        case .refused(cloud: true): parts.append("Not uploaded: your plan is read-only")
        case .refused(cloud: false): parts.append("Not uploaded: \(ownerName ?? "another Mac") took over this drive")
        case .forbidden: parts.append("Not uploaded: your access here doesn’t allow this change")
        }
        if let folder = decision.folder { parts.append("in " + folder) }
        parts.append(ByteCountFormatter.string(fromByteCount: decision.size, countStyle: .file))
        if let modified = decision.modified {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            parts.append("changed " + formatter.localizedString(for: min(modified, now), relativeTo: now))
        }
        return parts.joined(separator: " · ")
    }
}

private struct ReviewRow: View {
    let decision: PendingDecision
    let detail: String
    let busy: Bool
    let enabled: Bool
    let actions: ReviewActions

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: decision.kind == .conflict ? "doc.on.doc" : "lock.doc")
                .font(.title3)
                .foregroundStyle(Air.attention)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(decision.name).fontWeight(.medium).foregroundStyle(Air.ink).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.caption).foregroundStyle(Air.quiet).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if busy { ProgressView().controlSize(.small).accessibilityLabel("Working on \(decision.name)") }
            // A change refused to this member may still be welcome as a new file (a folder where members may only
            // create), and can always be kept outside the drive.
            if decision.kind == .conflict || decision.kind == .forbidden {
                Button("Save My Copy As…") { actions.saveCopy(decision) }
            }
            if decision.kind != .conflict {
                Button("Export My Copy…") { actions.export(decision) }
            }
            // A fixed slot for the last action, so the actions line up from row to row whichever pair a row offers.
            Button(decision.kind == .conflict ? "Keep Theirs" : "Discard Mine") { actions.discard(decision) }
                .frame(width: 104, alignment: .trailing)
        }
        .controlSize(.small)
        .disabled(!enabled)
        .airTransition(.item)
        .accessibilityElement(children: .contain)
    }
}

/// The review sheet's alerts, built without running them so the snapshot harness can render them.
@MainActor
enum ReviewPrompts {
    /// The name for this Mac's copy, beside the original. Nil when cancelled.
    static func askCopyName(_ decision: PendingDecision, suggested: String?) -> String? {
        let prompt = copyNameAlert(decision, suggested: suggested)
        while true {
            guard prompt.alert.runModal() == .alertFirstButtonReturn else { return nil }
            let name = prompt.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, !name.contains("/"), name != ".", name != "..", name.utf8.count <= 255 { return name }
            prompt.alert.informativeText = "Choose a name without slashes, up to 255 bytes."
        }
    }
    static func copyNameAlert(_ decision: PendingDecision, suggested: String?) -> (alert: NSAlert, field: NSTextField) {
        let field = NSTextField(string: suggested ?? decision.name)
        field.frame.size.width = 320
        let alert = NSAlert()
        alert.messageText = "Save your copy of “\(decision.name)” as a new file?"
        alert.informativeText = "Your copy is saved beside the original with this name, and uploads. "
            + "The original keeps the version from the other device."
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Save Copy")
        alert.addButton(withTitle: "Cancel")
        return (alert, field)
    }
    static func discardAlert(_ decision: PendingDecision) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Discard your copy of “\(decision.name)”?"
        alert.informativeText = decision.kind == .conflict
            ? "The version from the other device stays. Your changes to this file are deleted from this Mac."
            : "The drive keeps the version it has. Your changes to this file are deleted from this Mac."
        alert.addButton(withTitle: "Discard My Copy").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        return alert
    }
}
