import SwiftUI
import Darwin
import os
import StreamDriveCore

/// The calls behind the Members section, the same routes and client code as `paraair members`
/// (ParaAirCloudAPI.members/addMember/setMemberRole/removeMember). Tests and snapshots pass fixtures.
struct CloudMembersService: Sendable {
    var list: @Sendable (URL, CloudAccount, String) throws -> ParaAirCloudMemberList
    /// root, account, workspace, email, role, notify
    var add: @Sendable (URL, CloudAccount, String, String, ParaAirCloudMemberRole, Bool) throws -> ParaAirCloudMemberAdded
    /// root, account, workspace, user id, role
    var setRole: @Sendable (URL, CloudAccount, String, String, ParaAirCloudMemberRole) throws -> ParaAirCloudWorkspaceMember
    /// root, account, workspace, user id
    var remove: @Sendable (URL, CloudAccount, String, String) throws -> Void

    static func live(_ dependencies: EngineOpenDependencies) -> CloudMembersService {
        @Sendable func api(_ root: URL, _ account: CloudAccount) throws -> ParaAirCloudAPI {
            try CloudAccountModel.api(root: root, accountID: account.id, dependencies: dependencies)
        }
        return CloudMembersService(
            list: { root, account, workspace in try api(root, account).members(workspaceID: workspace) },
            add: { root, account, workspace, email, role, notify in
                try api(root, account).addMember(workspaceID: workspace, email: email, role: role, notify: notify)
            },
            setRole: { root, account, workspace, userID, role in
                try api(root, account).setMemberRole(workspaceID: workspace, userID: userID, role: role)
            },
            remove: { root, account, workspace, userID in try api(root, account).removeMember(workspaceID: workspace, userID: userID) })
    }
}

/// What the signed-in person may do with a workspace's members (cloud README, "Members"). The service enforces the same
/// rules; these keep actions it would refuse off the screen. Your own row is never changed here, so nobody demotes or
/// removes themselves by accident (`paraair members` still can).
struct CloudMemberRules: Equatable {
    /// The signed-in person's role in the workspace, from `/v1/me`.
    var viewerRole: ParaAirCloudMemberRole?
    var viewerUserID: String
    var ownerCount: Int

    var canManage: Bool { viewerRole == .owner || viewerRole == .admin }

    /// Roles an invitation may give: only owners make owners.
    var inviteRoles: [ParaAirCloudMemberRole] {
        switch viewerRole {
        case .owner?: return [.member, .viewer, .admin, .owner]
        case .admin?: return [.member, .viewer, .admin]
        default: return []
        }
    }

    func isYou(_ member: ParaAirCloudWorkspaceMember) -> Bool { member.userId == viewerUserID }

    /// The roles `member` can be given, their current one included; empty when it can't be changed.
    func roleChoices(for member: ParaAirCloudWorkspaceMember) -> [ParaAirCloudMemberRole] {
        guard canManage, !isYou(member), let current = ParaAirCloudMemberRole(rawValue: member.role) else { return [] }
        switch viewerRole {
        case .owner?:
            // The last owner keeps the role (the service refuses with busy).
            return current == .owner && ownerCount <= 1 ? [] : [.owner, .admin, .member, .viewer]
        case .admin?:
            return current == .owner ? [] : [.admin, .member, .viewer]
        default:
            return []
        }
    }

    func canRemove(_ member: ParaAirCloudWorkspaceMember) -> Bool {
        guard canManage, !isYou(member), let current = ParaAirCloudMemberRole(rawValue: member.role) else { return false }
        if current == .owner { return viewerRole == .owner && ownerCount > 1 }
        return true
    }
}

/// Seats as the members list reports them. A Team with a live subscription grows by a paid seat when someone joins a
/// full workspace (cloud billing/seats.ts); any other workspace refuses the invitation.
struct CloudSeatPresentation: Equatable {
    var line: String
    var fraction: Double?
    var full: Bool
    /// Inviting now buys a seat: the app asks first.
    var invitationBuysSeat: Bool
    var notice: String?

    static func make(seats: Int, used: Int, billedTeam: Bool) -> CloudSeatPresentation {
        let line = "\(used) of \(seats) seat\(seats == 1 ? "" : "s") used"
        let full = used >= seats
        let fraction = seats > 0 ? min(1, max(0, Double(used) / Double(seats))) : nil
        guard full else { return .init(line: line, fraction: fraction, full: false, invitationBuysSeat: false, notice: nil) }
        if billedTeam {
            return .init(line: line, fraction: fraction, full: true, invitationBuysSeat: true,
                         notice: "Every seat is taken. Inviting someone adds a paid seat to the Team plan.")
        }
        return .init(line: line, fraction: fraction, full: true, invitationBuysSeat: false,
                     notice: "Every seat is taken. Remove someone or add seats to the plan to invite someone else.")
    }

    /// The seats follow a live Team subscription (cloud billing/seats.ts: active or past due).
    static func isBilledTeam(_ billing: ParaAirCloudBilling?) -> Bool {
        guard let billing, billing.plan == .team else { return false }
        return billing.status == .active || billing.status == .pastDue
    }
}

enum CloudMemberText {
    static func role(_ value: String) -> String {
        switch ParaAirCloudMemberRole(rawValue: value) {
        case .owner?: return "Owner"
        case .admin?: return "Admin"
        case .member?: return "Member"
        case .viewer?: return "Viewer"
        case nil: return value.capitalized
        }
    }
    static func role(_ value: ParaAirCloudMemberRole) -> String { role(value.rawValue) }

    /// The second line of a member's row: who they are to you and whether they have signed in.
    static func detail(_ member: ParaAirCloudWorkspaceMember, you: Bool) -> String? {
        let status: String?
        switch member.status {
        case "invited": status = "Hasn’t signed in yet"
        case "disabled": status = "Account disabled"
        default: status = nil
        }
        return [you ? "You" : nil, status].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
    }

    /// Owners first, then admins, members and viewers; by address within a role.
    static func sorted(_ members: [ParaAirCloudWorkspaceMember]) -> [ParaAirCloudWorkspaceMember] {
        func rank(_ role: String) -> Int {
            switch ParaAirCloudMemberRole(rawValue: role) { case .owner?: 0; case .admin?: 1; case .member?: 2; case .viewer?: 3; case nil: 4 }
        }
        return members.sorted { (rank($0.role), $0.email.lowercased()) < (rank($1.role), $1.email.lowercased()) }
    }

    /// A plausible address: the service checks it properly.
    static func validEmail(_ value: String) -> String? {
        let email = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.utf8.count <= 320, !email.contains(where: { $0.isWhitespace || $0.isNewline }),
              let at = email.firstIndex(of: "@"), at != email.startIndex, email.index(after: at) != email.endIndex,
              email.filter({ $0 == "@" }).count == 1 else { return nil }
        return email
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// The members of a ParaAir Cloud drive's workspace, for its owners and admins. Adds and removals are sent once, as by
/// `paraair members`: a retry after one that went through would answer "already a member" or "not a member". When the
/// answer is lost the change may have happened, so the list is reloaded and the message says to check it.
@MainActor
final class CloudMembersModel: ObservableObject {
    enum ListState: Equatable { case idle, loading, loaded(ParaAirCloudMemberList), failed(String) }
    enum Work: Equatable { case inviting, changing(String), removing(String) }
    struct Outcome: Equatable {
        var text: String
        var problem: Bool
    }

    static let uncertainAdd = "ParaAir Cloud didn’t confirm the invitation, so it may have gone through. Check the list before inviting again."
    static let uncertainRemove = "ParaAir Cloud didn’t confirm the removal, so it may have gone through. Check the list before trying again."

    @Published private(set) var list: ListState = .idle
    @Published private(set) var work: Work?
    @Published private(set) var outcome: Outcome?
    /// A list request is on its way (the first load, Refresh, or the reload after a change).
    @Published private(set) var refreshing = false
    /// Why the list on screen couldn't be refreshed; the outcome of a change stays beside it.
    @Published private(set) var refreshError: String?
    @Published var email = ""
    @Published var inviteRole: ParaAirCloudMemberRole = .member
    @Published var notify = true
    /// Waiting for "Remove" in the confirmation.
    @Published var pendingRemoval: ParaAirCloudWorkspaceMember?
    /// Waiting for the person to agree to a paid seat.
    @Published var seatPurchaseRequested = false
    @Published private(set) var workspace: ParaAirCloudMe.Workspace?
    @Published private(set) var account: CloudAccount?

    let stateRoot: URL
    private let service: CloudMembersService
    private var generation = UUID()
    /// The latest list request: only its answer updates the list, so an older GET that returns late can't put back
    /// members or seats from before a change.
    private var listRequest = UUID()
    private let log = Logger(subsystem: "dev.streamdrive.app", category: "cloud")

    init(stateRoot: URL, service: CloudMembersService) {
        self.stateRoot = stateRoot.standardizedFileURL
        self.service = service
    }

    var members: ParaAirCloudMemberList? {
        if case .loaded(let list) = list { return list }
        return nil
    }
    var rules: CloudMemberRules {
        CloudMemberRules(viewerRole: workspace.flatMap { ParaAirCloudMemberRole(rawValue: $0.role) },
                         viewerUserID: account?.userID ?? "",
                         ownerCount: members?.members.filter { $0.role == ParaAirCloudMemberRole.owner.rawValue }.count ?? 0)
    }
    var seats: CloudSeatPresentation? {
        guard let members else { return nil }
        return .make(seats: members.workspace.seats, used: members.workspace.seatsUsed,
                     billedTeam: CloudSeatPresentation.isBilledTeam(workspace?.billing))
    }
    /// Only with seat counts from a list read after the last change: an invitation decides whether it buys a seat from
    /// them, so none starts while the list is reloading or after a reload failed.
    var canInvite: Bool {
        guard work == nil, !refreshing, refreshError == nil, rules.canManage, CloudMemberText.validEmail(email) != nil,
              let seats else { return false }
        return !seats.full || seats.invitationBuysSeat
    }

    /// Shows `workspace`'s members to `account`. The same workspace keeps its list (a summary reload only refreshes the
    /// role and billing); another one starts over. Members and viewers can't list members, so nothing is asked then.
    func show(workspace: ParaAirCloudMe.Workspace, account: CloudAccount) {
        let same = self.workspace?.id == workspace.id && self.account?.id == account.id
        if self.workspace != workspace { self.workspace = workspace }
        if self.account != account { self.account = account }
        if !inviteRolesContain(inviteRole) { inviteRole = .member }
        guard rules.canManage else {
            if !same { reset() }
            return
        }
        if same, list != .idle { return }
        if !same { reset() }
        reload()
    }

    /// Signed out, or the drive's workspace isn't a team: forget everything, and drop replies still on their way.
    func hide() {
        guard workspace != nil || account != nil || list != .idle else { return }
        workspace = nil; account = nil
        reset()
    }

    private func reset() {
        generation = UUID(); listRequest = UUID()
        if list != .idle { list = .idle }
        if refreshing { refreshing = false }
        if refreshError != nil { refreshError = nil }
        if work != nil { work = nil }
        if outcome != nil { outcome = nil }
        if !email.isEmpty { email = "" }
        pendingRemoval = nil; seatPurchaseRequested = false
    }

    private func inviteRolesContain(_ role: ParaAirCloudMemberRole) -> Bool { rules.inviteRoles.contains(role) || rules.inviteRoles.isEmpty }

    func reload() {
        guard let workspace, let account, rules.canManage else { return }
        let request = UUID(), root = stateRoot, service = service, workspaceID = workspace.id
        listRequest = request
        if members == nil { list = .loading }
        refreshing = true
        Task {
            defer { if listRequest == request { refreshing = false } }
            do {
                let value = try await ParaAirCloudBlocking.run { try service.list(root, account, workspaceID) }
                guard listRequest == request else { return }
                list = .loaded(value)
                refreshError = nil
            } catch {
                guard listRequest == request else { return }
                log.error("cloud members list failed errno=\((error as? DriveError)?.code ?? -1)")
                // A list already on screen stays, with a line saying it may be out of date.
                if members == nil { list = .failed(CloudAccountModel.message(error)) }
                else { refreshError = "The list couldn’t be refreshed: " + CloudAccountModel.message(error) }
            }
        }
    }

    /// Adds the address typed in, sent once. A full billed Team asks first, since the add buys a seat.
    func invite(seatConfirmed: Bool = false) {
        guard canInvite, let workspace, let account, let address = CloudMemberText.validEmail(email), let seats else { return }
        if seats.invitationBuysSeat, !seatConfirmed { seatPurchaseRequested = true; return }
        seatPurchaseRequested = false
        let id = generation, root = stateRoot, service = service, workspaceID = workspace.id
        let role = inviteRole, notify = notify
        work = .inviting; outcome = nil
        log.notice("cloud member add role=\(role.rawValue, privacy: .public) notify=\(notify) buysSeat=\(seats.invitationBuysSeat)")
        Task {
            defer { if generation == id { work = nil } }
            do {
                let result = try await ParaAirCloudBlocking.run { try service.add(root, account, workspaceID, address, role, notify) }
                guard generation == id else { return }
                let who = result.member.email, given = CloudMemberText.role(result.member.role).lowercased()
                let mail = result.notified ? " ParaAir Cloud emailed them an invitation."
                    : " Nothing was emailed: tell them to sign in to ParaAir with this address."
                outcome = .init(text: result.added ? "Added \(who) as \(given).\(mail)"
                                    : "\(who) is already \(Self.article(result.member.role)) \(given).\(result.notified ? mail : "")", problem: false)
                email = ""
            } catch {
                guard generation == id else { return }
                outcome = .init(text: Self.text(error, uncertain: Self.uncertainAdd), problem: true)
            }
            reload()
        }
    }

    func change(_ member: ParaAirCloudWorkspaceMember, to role: ParaAirCloudMemberRole) {
        guard work == nil, let workspace, let account, member.role != role.rawValue, rules.roleChoices(for: member).contains(role) else { return }
        let id = generation, root = stateRoot, service = service, workspaceID = workspace.id, userID = member.userId
        work = .changing(member.userId); outcome = nil
        log.notice("cloud member role role=\(role.rawValue, privacy: .public)")
        Task {
            defer { if generation == id { work = nil } }
            do {
                let updated = try await ParaAirCloudBlocking.run { try service.setRole(root, account, workspaceID, userID, role) }
                guard generation == id else { return }
                outcome = .init(text: "\(updated.email) is now \(Self.article(updated.role)) \(CloudMemberText.role(updated.role).lowercased()).",
                                problem: false)
            } catch {
                guard generation == id else { return }
                outcome = .init(text: CloudAccountModel.message(error), problem: true)
            }
            reload()
        }
    }

    func requestRemoval(_ member: ParaAirCloudWorkspaceMember) {
        guard work == nil, rules.canRemove(member) else { return }
        pendingRemoval = member
    }

    /// Removes the member the confirmation named, sent once.
    func confirmRemoval() {
        guard let member = pendingRemoval else { return }
        pendingRemoval = nil
        guard work == nil, let workspace, let account, rules.canRemove(member) else { return }
        let id = generation, root = stateRoot, service = service, workspaceID = workspace.id, userID = member.userId
        work = .removing(member.userId); outcome = nil
        log.notice("cloud member remove")
        Task {
            defer { if generation == id { work = nil } }
            do {
                try await ParaAirCloudBlocking.run { try service.remove(root, account, workspaceID, userID) }
                guard generation == id else { return }
                outcome = .init(text: "Removed \(member.email). They lose access to \(workspace.name)’s drives right away.", problem: false)
            } catch {
                guard generation == id else { return }
                outcome = .init(text: Self.text(error, uncertain: Self.uncertainRemove), problem: true)
            }
            reload()
        }
    }

    /// An answer that may have come after the service made the change (a lost connection, a server error, a malformed
    /// reply) gets the "check the list" text instead of the error, which names the CLI's command.
    nonisolated static func text(_ error: Error, uncertain: String) -> String {
        if let error = error as? DriveError, error.disposition == .ambiguous { return uncertain }
        return CloudAccountModel.message(error)
    }

    nonisolated static func article(_ role: String) -> String { role == ParaAirCloudMemberRole.admin.rawValue || role == ParaAirCloudMemberRole.owner.rawValue ? "an" : "a" }
}

/// Storage Settings' Members section: the drive's team, its seats and its people. Owners and admins invite, change
/// roles and remove; everyone else sees who manages it.
struct CloudMembersSection: View {
    @ObservedObject var model: CloudMembersModel
    let workspace: ParaAirCloudMe.Workspace
    let account: CloudAccount

    var body: some View {
        Section {
            if model.rules.canManage {
                content
            } else {
                Text("Only owners and admins of \(workspace.name) can see and change its members.")
                    .foregroundStyle(Glide.quiet)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            HStack {
                Text("Members").font(.glideHeading).foregroundStyle(Glide.ink)
                Spacer()
                if model.rules.canManage, model.members != nil {
                    if model.refreshing { ProgressView().controlSize(.small) }
                    Button("Refresh", action: model.reload).disabled(model.work != nil || model.refreshing).controlSize(.small)
                }
            }
        } footer: {
            if model.rules.canManage {
                Text("Members read and change files, viewers only read them. Admins also manage members and folder access.")
                    .foregroundStyle(Glide.quiet)
            }
        }
        .onAppear { model.show(workspace: workspace, account: account) }
        .onChange(of: workspace) { _, value in model.show(workspace: value, account: account) }
        .onChange(of: account) { _, value in model.show(workspace: workspace, account: value) }
        .confirmationDialog(model.pendingRemoval.map { "Remove \($0.email) from \(workspace.name)?" } ?? "Remove?",
                            isPresented: Binding(get: { model.pendingRemoval != nil }, set: { if !$0 { model.pendingRemoval = nil } }),
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive, action: model.confirmRemoval)
            Button("Cancel", role: .cancel) { model.pendingRemoval = nil }
        } message: {
            Text(CloudSeatPresentation.isBilledTeam(workspace.billing)
                 ? "They lose access to this team’s drives at once. Their seat stays paid until the billing period ends."
                 : "They lose access to this team’s drives at once.")
        }
        .confirmationDialog("Add a paid seat?", isPresented: $model.seatPurchaseRequested, titleVisibility: .visible) {
            Button("Invite and Add Seat") { model.invite(seatConfirmed: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every seat on the Team plan is taken. Inviting \(CloudMemberText.validEmail(model.email) ?? "this person") adds a seat, billed now for the rest of the period.")
        }
    }

    @ViewBuilder private var content: some View {
        switch model.list {
        case .idle, .loading:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Loading members…").foregroundStyle(Glide.quiet)
            }
        case .failed(let message):
            ErrorLine(text: message)
            Button("Retry", action: model.reload)
        case .loaded(let list):
            seats(list)
            ForEach(CloudMemberText.sorted(list.members), id: \.userId) { member in
                MemberRow(member: member, rules: model.rules, work: model.work,
                          change: { model.change(member, to: $0) }, remove: { model.requestRemoval(member) })
            }
            invite
        }
        if let outcome = model.outcome {
            if outcome.problem { ErrorLine(text: outcome.text) }
            else { NoticeRow(notice: .init(id: "members-outcome", text: outcome.text, tone: .good)) }
        }
        if let refreshError = model.refreshError { ErrorLine(text: refreshError) }
    }

    @ViewBuilder private func seats(_ list: ParaAirCloudMemberList) -> some View {
        if let seats = model.seats {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent(list.workspace.name) {
                    Text(seats.line).monospacedDigit()
                }
                if let fraction = seats.fraction {
                    ProgressView(value: fraction)
                        .tint(seats.full ? Glide.attention : Glide.controlTint)
                        .accessibilityLabel(seats.line)
                }
            }
            .accessibilityElement(children: .combine)
            if let notice = seats.notice {
                NoticeRow(notice: .init(id: "seats", text: notice, tone: seats.invitationBuysSeat ? .neutral : .attention))
            }
        }
    }

    @ViewBuilder private var invite: some View {
        let full = model.seats.map { $0.full && !$0.invitationBuysSeat } ?? false
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                TextField("Invite by email", text: $model.email, prompt: Text(verbatim: "name@example.com"))
                    .textContentType(.emailAddress)
                    .onSubmit { model.invite() }
                Picker("Role", selection: $model.inviteRole) {
                    ForEach(model.rules.inviteRoles, id: \.self) { Text(CloudMemberText.role($0)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Button("Invite") { model.invite() }
                    .disabled(!model.canInvite)
                if model.work == .inviting { ProgressView().controlSize(.small) }
            }
            .disabled(full || model.work != nil)
            Toggle("Email them an invitation", isOn: $model.notify)
                .glideControlTint()
                .disabled(full || model.work != nil)
        }
    }
}

private struct MemberRow: View {
    let member: ParaAirCloudWorkspaceMember
    let rules: CloudMemberRules
    let work: CloudMembersModel.Work?
    let change: (ParaAirCloudMemberRole) -> Void
    let remove: () -> Void

    var body: some View {
        let choices = rules.roleChoices(for: member)
        let busy = work == .changing(member.userId) || work == .removing(member.userId)
        LabeledContent {
            HStack(spacing: 10) {
                if busy { ProgressView().controlSize(.small) }
                if choices.isEmpty {
                    Text(CloudMemberText.role(member.role)).foregroundStyle(Glide.quiet)
                } else {
                    Picker("Role", selection: Binding(
                        get: { ParaAirCloudMemberRole(rawValue: member.role) ?? .member },
                        set: { change($0) })) {
                        ForEach(choices, id: \.self) { Text(CloudMemberText.role($0)).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("Role of \(member.email)")
                    .disabled(work != nil)
                }
                if rules.canRemove(member) {
                    Button("Remove…", action: remove)
                        .controlSize(.small)
                        .disabled(work != nil)
                        .accessibilityLabel("Remove \(member.email)")
                }
            }
        } label: {
            Text(member.email).textSelection(.enabled)
            if let detail = CloudMemberText.detail(member, you: rules.isYou(member)) { Text(detail) }
        }
    }
}
