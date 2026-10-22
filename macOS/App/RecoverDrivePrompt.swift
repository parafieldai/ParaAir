import AppKit
import Darwin
import StreamDriveCore

/// The "Use Existing Drive…" dialogs: pick a drive backed up in the connection's bucket, or
/// type its folder when the connection can't list the bucket; name it for Finder; and
/// confirm taking it over from a Mac that used it recently.
@MainActor
enum RecoverDrivePrompt {
    struct Choice: Equatable {
        var volume: String
        var finderName: String
    }

    /// One menu line per drive, short enough for the alert's width: its Finder name, and the
    /// Mac that last used it and when.
    nonisolated static func title(_ drive: JuiceFSBackend.StoredDrive, now: Date) -> String {
        let name = drive.owner?.drive ?? drive.volume
        guard let owner = drive.owner else { return name }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "\(name) · \(owner.name), \(formatter.localizedString(for: min(owner.at, now), relativeTo: now))"
    }

    static func choose(_ listed: Result<[JuiceFSBackend.StoredDrive], Error>, connection: StorageConnection) -> Choice? {
        switch listed {
        case .success(let drives) where drives.isEmpty:
            let alert = NSAlert()
            alert.messageText = "No drives found in \(connection.name)"
            alert.informativeText = "A drive appears here once it has backed up its index into the bucket, shortly after its first changes. "
                + "Open ParaAir on the Mac that has the drive, then try again."
            alert.runModal()
            return nil
        case .success(let drives):
            // Most recently backed up first; backup names sort by time.
            return pick(drives.sorted { $0.latestBackup > $1.latestBackup }, connection: connection)
        case .failure(let error as DriveError) where error.code == ENOTSUP:
            return typeFolder(connection)
        case .failure(let error):
            let alert = NSAlert()
            alert.messageText = "ParaAir couldn’t read \(connection.name)"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return nil
        }
    }

    static func confirmTakeOver(_ reason: String) -> Bool { takeOverAlert(reason).runModal() == .alertFirstButtonReturn }
    static func takeOverAlert(_ reason: String) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Take over this drive?"
        alert.informativeText = reason
        // It cuts the other Mac off from changing the drive.
        alert.addButton(withTitle: "Take Over").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    private static let explanation = "ParaAir sets up the drive on this Mac from the latest backup of its index. "
        + "Changes made on another Mac since that backup, up to about an hour, won’t appear."

    /// The picker alert, built without running it (the snapshot harness renders it).
    struct PickAlert {
        let alert: NSAlert
        let menu: NSPopUpButton
        let field: NSTextField
        fileprivate let sync: NameFollowsSelection
    }
    static func pickAlert(_ drives: [JuiceFSBackend.StoredDrive], connectionName: String, now: Date = Date()) -> PickAlert {
        let menu = NSPopUpButton(frame: .zero, pullsDown: false)
        menu.addItems(withTitles: drives.map { title($0, now: now) })
        let field = NSTextField(string: suggestedName(drives[0]))
        let sync = NameFollowsSelection(menu: menu, field: field, names: drives.map(suggestedName))
        let alert = NSAlert()
        alert.messageText = "Use a drive from \(connectionName)?"
        alert.informativeText = explanation
        alert.accessoryView = form([("Drive", menu), ("Name in Finder", field)])
        alert.addButton(withTitle: "Use Drive")
        alert.addButton(withTitle: "Cancel")
        return PickAlert(alert: alert, menu: menu, field: field, sync: sync)
    }

    private static func pick(_ drives: [JuiceFSBackend.StoredDrive], connection: StorageConnection) -> Choice? {
        let prompt = pickAlert(drives, connectionName: connection.name)
        let alert = prompt.alert, menu = prompt.menu, field = prompt.field
        while true {
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                try DriveProfile.validateFinderName(name)
                return withExtendedLifetime(prompt.sync) { Choice(volume: drives[menu.indexOfSelectedItem].volume, finderName: name) }
            } catch {
                alert.informativeText = error.localizedDescription + "\n\n" + explanation
            }
        }
    }

    private static func typeFolder(_ connection: StorageConnection) -> Choice? {
        let folder = NSTextField(string: "")
        folder.placeholderString = "streamdrive-…"
        let field = NSTextField(string: "ParaAir")
        let alert = NSAlert()
        alert.messageText = "Which drive should ParaAir use?"
        let reason = "\(connection.name) can’t list its bucket, so type the drive’s folder name. "
            + "Find it in the bucket in your Cloudflare dashboard; it starts with streamdrive-. " + explanation
        alert.informativeText = reason
        alert.accessoryView = form([("Folder in the bucket", folder), ("Name in Finder", field)])
        alert.window.initialFirstResponder = folder
        alert.addButton(withTitle: "Use Drive")
        alert.addButton(withTitle: "Cancel")
        let volume = try! NSRegularExpression(pattern: "^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$")
        while true {
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            let typed = folder.stringValue.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "/")))
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard volume.firstMatch(in: typed, range: NSRange(typed.startIndex..., in: typed)) != nil else {
                alert.informativeText = "That isn’t a drive folder name: use lowercase letters, digits and hyphens, as shown in the bucket.\n\n" + reason
                continue
            }
            do {
                try DriveProfile.validateFinderName(name)
                return Choice(volume: typed, finderName: name)
            } catch {
                alert.informativeText = error.localizedDescription + "\n\n" + reason
            }
        }
    }

    private nonisolated static func suggestedName(_ drive: JuiceFSBackend.StoredDrive) -> String { drive.owner?.drive ?? "ParaAir" }

    /// Labels above their controls, at the width NSAlert gives accessory views.
    private static func form(_ rows: [(String, NSView)]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        for (index, (label, control)) in rows.enumerated() {
            if index > 0 { stack.setCustomSpacing(12, after: stack.arrangedSubviews.last!) }
            stack.addArrangedSubview(NSTextField(labelWithString: label))
            stack.addArrangedSubview(control)
            control.widthAnchor.constraint(equalToConstant: 340).isActive = true
        }
        stack.frame.size = stack.fittingSize
        return stack
    }
}

/// Keeps the Finder name in step with the chosen drive until the person edits it.
@MainActor
private final class NameFollowsSelection: NSObject {
    private let menu: NSPopUpButton
    private let field: NSTextField
    private let names: [String]

    init(menu: NSPopUpButton, field: NSTextField, names: [String]) {
        self.menu = menu; self.field = field; self.names = names
        super.init()
        menu.target = self
        menu.action = #selector(changed)
    }

    @objc private func changed() {
        guard names.contains(field.stringValue), names.indices.contains(menu.indexOfSelectedItem) else { return }
        field.stringValue = names[menu.indexOfSelectedItem]
    }
}
