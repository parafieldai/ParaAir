import SwiftUI
import Darwin
import os
import StreamDriveCore

/// The account deletion calls (cloud item P4): status, request with the typed address, and cancel. Tests and snapshots
/// pass fixtures.
struct CloudAccountDeletionService: Sendable {
    /// Nil when the service doesn't offer account deletion.
    var status: @Sendable (URL, CloudAccount) throws -> ParaAirCloudAccountDeletion?
    /// root, account, the typed address
    var request: @Sendable (URL, CloudAccount, String) throws -> ParaAirCloudAccountDeletion
    var cancel: @Sendable (URL, CloudAccount) throws -> ParaAirCloudAccountDeletion

    static func live(_ dependencies: EngineOpenDependencies) -> CloudAccountDeletionService {
        @Sendable func api(_ root: URL, _ account: CloudAccount) throws -> ParaAirCloudAPI {
            try CloudAccountModel.api(root: root, accountID: account.id, dependencies: dependencies)
        }
        return CloudAccountDeletionService(
            status: { root, account in try api(root, account).accountDeletion() },
            request: { root, account, email in try api(root, account).requestAccountDeletion(confirmEmail: email) },
            cancel: { root, account in try api(root, account).cancelAccountDeletion() })
    }
}

/// The words for a deletion: what happens to each workspace, what must change first, and the date. Pure, so the
/// snapshot harness checks it.
enum CloudAccountDeletionText {
    /// The date and time in this Mac's time zone: the service deletes at `deleteAfter`, not at midnight.
    static func when(_ date: Date, timeZone: TimeZone = .current) -> String {
        var style = Date.FormatStyle.dateTime.month(.wide).day().year().hour().minute()
        style.timeZone = timeZone
        return date.formatted(style)
    }

    static func banner(_ request: ParaAirCloudAccountDeletion.Request, timeZone: TimeZone = .current) -> String {
        let who = request.requestedBy == "operator" ? "At your request, Parafield support scheduled your ParaAir Cloud account for deletion"
            : "Your ParaAir Cloud account will be deleted"
        return "\(who) on \(when(request.deleteAfter, timeZone: timeZone)). Until then everything keeps working; files added meanwhile are deleted too."
    }

    /// The home window's notice: the date, and where to cancel.
    static func homeNotice(_ date: Date, timeZone: TimeZone = .current) -> String {
        "Your ParaAir Cloud account will be deleted on \(when(date, timeZone: timeZone)). To keep it, choose Cancel Deletion in Storage Settings."
    }

    static func grace(_ days: Int) -> String {
        days == 0 ? "The account is deleted within about 15 minutes of confirming."
            : "The account is deleted \(days) day\(days == 1 ? "" : "s") after you confirm. Until then everything keeps working, and you can cancel here."
    }

    static func workspace(_ workspace: ParaAirCloudAccountDeletion.Workspace) -> String {
        switch workspace.action {
        case "delete": return "Deleted, with every file and version in it"
        case "leave": return "You leave it. Its files stay with the others in it"
        default: return "Changed when the account closes"
        }
    }

    static func blocker(_ blocker: ParaAirCloudAccountDeletion.Blocker, in status: ParaAirCloudAccountDeletion) -> String {
        let name = status.workspaces.first { $0.id == blocker.workspaceId }?.name ?? "A workspace"
        switch blocker.reason {
        case "sole_owner":
            return "You’re the only owner of \(name), which has other members. Make one of them an owner in Members, or remove them, first."
        case "subscription_active":
            return "\(name) has a plan that renews. Cancel it with Manage Plan… first; the account can be deleted once the plan no longer renews."
        default:
            return "\(name) needs a change before the account can be deleted."
        }
    }

    static func confirms(_ typed: String, email: String) -> Bool {
        typed.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(email) == .orderedSame
    }
}

/// Closing the signed-in ParaAir Cloud account from Storage Settings: the service schedules it after a grace period,
/// which Storage Settings and the home window show with its date, and which can be cancelled until it ends. A service
/// that predates account deletion offers nothing here.
@MainActor
final class CloudAccountDeletionModel: ObservableObject {
    enum State: Equatable { case idle, loading, unsupported, loaded(ParaAirCloudAccountDeletion), failed(String) }

    @Published private(set) var state: State = .idle
    @Published private(set) var busy = false
    /// The last request's or cancel's failure.
    @Published private(set) var message: String?
    @Published private(set) var sheetPresented = false
    @Published var confirmEmail = ""
    @Published private(set) var account: CloudAccount?

    let stateRoot: URL
    private let service: CloudAccountDeletionService
    private var generation = UUID()
    private var loadedAt: Date?
    private var loading = false
    /// The status read in flight: a request or cancel replaces it, so a read sent before the change can't put back the
    /// state from before it.
    private var statusRequest = UUID()
    private let log = Logger(subsystem: "dev.streamdrive.app", category: "cloud")

    init(stateRoot: URL, service: CloudAccountDeletionService) {
        self.stateRoot = stateRoot.standardizedFileURL
        self.service = service
    }

    var status: ParaAirCloudAccountDeletion? {
        if case .loaded(let value) = state { return value }
        return nil
    }
    /// The deletion waiting for its grace period to end.
    var scheduled: ParaAirCloudAccountDeletion.Request? { status?.deletion.flatMap { $0.isScheduled ? $0 : nil } }
    /// The service offers deletion and none is scheduled.
    var canRequest: Bool { status != nil && scheduled == nil && status?.deletion == nil }
    var canConfirm: Bool {
        guard let status, let account, !busy, status.blockers.isEmpty, status.deletion == nil else { return false }
        return CloudAccountDeletionText.confirms(confirmEmail, email: account.email)
    }

    /// Follows `account`: another account starts over; the same one reloads when its status is older than `maxAge`.
    func show(account: CloudAccount, maxAge: TimeInterval = 300) {
        if self.account?.id != account.id { reset(); self.account = account }
        else if self.account != account { self.account = account }
        refresh(maxAge: maxAge)
    }

    func hide() {
        guard account != nil || state != .idle else { return }
        account = nil
        reset()
    }

    private func reset() {
        generation = UUID(); statusRequest = UUID(); loadedAt = nil; loading = false
        if state != .idle { state = .idle }
        if busy { busy = false }
        if message != nil { message = nil }
        if sheetPresented { sheetPresented = false }
        if !confirmEmail.isEmpty { confirmEmail = "" }
    }

    /// Reads the status unless one is younger than `maxAge`. Not while a request or cancel runs: its answer is newer.
    func refresh(maxAge: TimeInterval = 0) {
        guard let account, !loading, !busy else { return }
        if maxAge > 0, let loadedAt, Date().timeIntervalSince(loadedAt) < maxAge { return }
        let id = UUID(), root = stateRoot, service = service
        statusRequest = id
        loading = true
        if status == nil, state != .unsupported { state = .loading }
        Task {
            defer { if statusRequest == id { loading = false } }
            do {
                let value = try await ParaAirCloudBlocking.run { try service.status(root, account) }
                guard statusRequest == id else { return }
                loadedAt = Date()
                state = value.map { .loaded($0) } ?? .unsupported
            } catch {
                guard statusRequest == id else { return }
                log.error("cloud account deletion status failed errno=\((error as? DriveError)?.code ?? -1)")
                // A status already on screen stays; only a first load shows the failure.
                if status == nil { state = .failed(CloudAccountModel.message(error)) }
            }
        }
    }

    func presentSheet() {
        guard account != nil, canRequest else { return }
        message = nil; confirmEmail = ""
        sheetPresented = true
        refresh()
    }

    func closeSheet() {
        guard !busy else { return }
        sheetPresented = false; confirmEmail = ""
    }

    /// Schedules the deletion with the typed address. The service rechecks the address and what blocks it.
    func request() {
        guard canConfirm, let account else { return }
        let id = generation, root = stateRoot, service = service
        let typed = confirmEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        startChange()
        log.notice("cloud account deletion requested")
        Task {
            defer { if generation == id { busy = false } }
            do {
                let value = try await ParaAirCloudBlocking.run { try service.request(root, account, typed) }
                guard generation == id else { return }
                state = .loaded(value); loadedAt = Date()
                sheetPresented = false; confirmEmail = ""
            } catch {
                guard generation == id else { return }
                log.error("cloud account deletion request failed errno=\((error as? DriveError)?.code ?? -1)")
                message = CloudAccountModel.message(error)
                // A refusal (409) means something changed: show what blocks it now.
                busy = false; loadedAt = nil
                refresh()
            }
        }
    }

    func cancel() {
        guard let account, scheduled != nil, !busy else { return }
        let id = generation, root = stateRoot, service = service
        startChange()
        log.notice("cloud account deletion cancelled")
        Task {
            defer { if generation == id { busy = false } }
            do {
                let value = try await ParaAirCloudBlocking.run { try service.cancel(root, account) }
                guard generation == id else { return }
                state = .loaded(value); loadedAt = Date()
            } catch {
                guard generation == id else { return }
                log.error("cloud account deletion cancel failed errno=\((error as? DriveError)?.code ?? -1)")
                message = CloudAccountModel.message(error)
            }
        }
    }

    /// A request or cancel starts: reads already sent are dropped, and none starts until it ends.
    private func startChange() {
        statusRequest = UUID(); loading = false
        busy = true; message = nil
    }
}

/// The scheduled deletion in Storage Settings: the date and Cancel Deletion.
struct CloudAccountDeletionBanner: View {
    @ObservedObject var model: CloudAccountDeletionModel

    var body: some View {
        if let scheduled = model.scheduled {
            banner(scheduled)
            // Cancel Deletion's failure ("too late to cancel"); the sheet shows a request's.
            if let message = model.message, !model.sheetPresented { ErrorLine(text: message) }
        }
    }

    private func banner(_ scheduled: ParaAirCloudAccountDeletion.Request) -> some View {
        Group {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label {
                    Text(CloudAccountDeletionText.banner(scheduled))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Glide.attention)
                }
                Spacer(minLength: 0)
                Button("Cancel Deletion", action: model.cancel).disabled(model.busy)
            }
            .font(.callout)
        }
    }
}

/// What closing the account does, what must change first, and the typed confirmation.
struct CloudAccountDeletionSheet: View {
    @ObservedObject var model: CloudAccountDeletionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Delete your ParaAir Cloud account?")
                .font(.glideHeading).foregroundStyle(Glide.ink)
            switch model.state {
            case .idle, .loading:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Checking what closing the account changes…").foregroundStyle(Glide.quiet)
                }
            case .unsupported:
                Text("This ParaAir Cloud service can’t delete accounts yet.").foregroundStyle(Glide.quiet)
            case .failed(let message):
                ErrorLine(text: message)
                Button("Try Again") { model.refresh() }
            case .loaded(let status):
                details(status)
            }
            if let message = model.message { ErrorLine(text: message) }
            LegalLinksRow(pages: [LegalLinks.cloudTerms, LegalLinks.privacy])
            HStack(spacing: 10) {
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", action: model.closeSheet)
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.busy)
                Button("Delete Account", role: .destructive, action: model.request)
                    .disabled(!model.canConfirm)
            }
        }
        .padding(24)
        .frame(width: 520)
        .glideSurface()
    }

    @ViewBuilder private func details(_ status: ParaAirCloudAccountDeletion) -> some View {
        if !status.workspaces.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(status.workspaces) { workspace in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(workspace.name).fontWeight(.medium)
                        Text(CloudAccountDeletionText.workspace(workspace)).font(.callout).foregroundStyle(Glide.quiet)
                    }
                }
            }
        }
        Text("Your email address, sign-ins and invitations are deleted too. Billing records stay, as the Privacy Policy says.")
            .font(.callout).foregroundStyle(Glide.quiet)
            .fixedSize(horizontal: false, vertical: true)
        if status.blockers.isEmpty {
            Text(CloudAccountDeletionText.grace(status.graceDays))
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Type \(model.account?.email ?? "your email address") to confirm.").font(.callout)
                TextField("Email address", text: $model.confirmEmail, prompt: Text(verbatim: model.account?.email ?? ""))
                    .labelsHidden()
                    .textContentType(.emailAddress)
                    .onSubmit(model.request)
                    .disabled(model.busy)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(status.blockers.enumerated()), id: \.offset) { _, blocker in
                    Label {
                        Text(CloudAccountDeletionText.blocker(blocker, in: status)).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Glide.attention)
                    }
                    .font(.callout)
                }
            }
        }
    }
}
