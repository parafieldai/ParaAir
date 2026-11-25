import Foundation

/// An account's deletion (`GET /v1/account/deletion`, cloud item P4). Closing an account deletes the workspaces it is the
/// only person in, with their files, and ends its membership in every other one, after a grace period in which it can
/// be cancelled. `blockers` must be empty before a deletion can be scheduled.
public struct ParaAirCloudAccountDeletion: Codable, Equatable, Sendable {
    /// A scheduled (or started) deletion. `state` is "scheduled" (the grace period; everything still works) or
    /// "deleting" (sign-in is refused, so a signed-in Mac rarely sees it). `requestedBy` is "user" or "operator".
    public struct Request: Codable, Equatable, Sendable {
        public var state: String
        public var requestedAt: Date
        public var deleteAfter: Date
        public var requestedBy: String

        public init(state: String, requestedAt: Date, deleteAfter: Date, requestedBy: String) {
            self.state = state; self.requestedAt = requestedAt; self.deleteAfter = deleteAfter; self.requestedBy = requestedBy
        }
        public var isScheduled: Bool { state == "scheduled" }
    }

    /// What closing the account does to one of its workspaces: `action` "delete" (it is the only person in it: the
    /// workspace and its files go) or "leave" (the membership ends; the workspace and its files stay).
    public struct Workspace: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var kind: String
        public var role: String
        public var action: String

        public init(id: String, name: String, kind: String, role: String, action: String) {
            self.id = id; self.name = name; self.kind = kind; self.role = role; self.action = action
        }
    }

    /// Something to change before the account can be deleted: `reason` "sole_owner" (the only owner of a workspace
    /// with other members) or "subscription_active" (a workspace that would be deleted has a plan that renews).
    public struct Blocker: Codable, Equatable, Sendable {
        public var workspaceId: String
        public var reason: String

        public init(workspaceId: String, reason: String) { self.workspaceId = workspaceId; self.reason = reason }
    }

    public var deletion: Request?
    public var graceDays: Int
    public var workspaces: [Workspace]
    public var blockers: [Blocker]

    public init(deletion: Request?, graceDays: Int, workspaces: [Workspace], blockers: [Blocker]) {
        self.deletion = deletion; self.graceDays = graceDays; self.workspaces = workspaces; self.blockers = blockers
    }

    var isValid: Bool {
        (0...30).contains(graceDays) && workspaces.count <= 1000 && blockers.count <= 1000
            && workspaces.allSatisfy {
                ParaAirCloudIDs.isWorkspaceID($0.id) && !$0.name.isEmpty && $0.name.utf8.count <= 400
                    && [$0.kind, $0.role, $0.action].allSatisfy { !$0.isEmpty && $0.utf8.count <= 32 }
            }
            && blockers.allSatisfy { ParaAirCloudIDs.isWorkspaceID($0.workspaceId) && !$0.reason.isEmpty && $0.reason.utf8.count <= 64 }
            && deletion.map { [$0.state, $0.requestedBy].allSatisfy { !$0.isEmpty && $0.utf8.count <= 32 } } ?? true
    }
}
