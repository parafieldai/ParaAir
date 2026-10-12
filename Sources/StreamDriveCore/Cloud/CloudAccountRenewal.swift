import Foundation
import Darwin

/// The app's proactive refresh for every signed-in ParaAir Cloud account of a state
/// folder. The extension and the CLI refresh only on demand (spec 3.5).
public actor CloudAccountRenewal {
    private let root: URL
    private let vault: any ConnectionVault
    private let configuration: Configuration
    private let policy: ParaAirCloudTransportPolicy
    private let now: @Sendable () -> Date
    private var sessions: [String: ParaAirCloudSession] = [:]

    private struct Configuration: @unchecked Sendable { let value: URLSessionConfiguration }

    public init(root: URL, vault: any ConnectionVault = CloudAccountStore.liveVault, configuration: URLSessionConfiguration = .ephemeral,
                policy: ParaAirCloudTransportPolicy = .current, now: @escaping @Sendable () -> Date = { Date() }) {
        self.root = root; self.vault = vault; self.configuration = Configuration(value: configuration)
        self.policy = policy; self.now = now
    }

    /// Outcome per account id in `<root>/cloud-accounts`; unreadable records are `.failed`.
    public func renewDue(within: TimeInterval = 120) async -> [String: RenewalOutcome] {
        let listed = CloudAccountStore(root: root).list()
        var outcomes: [String: RenewalOutcome] = [:]
        for id in listed.unreadable where (try? ConnectionStore.validateID(id)) != nil { outcomes[id] = .failed }
        let signedIn = listed.accounts.filter { $0.state == .signedIn }
        sessions = sessions.filter { id, _ in signedIn.contains { $0.id == id } }
        for account in signedIn {
            if Task.isCancelled { break }
            let session: ParaAirCloudSession
            if let existing = sessions[account.id] { session = existing }
            else {
                var options = ParaAirCloudSession.Options(); options.proactiveWindow = within
                do {
                    session = try ParaAirCloudSession(root: root, accountID: account.id, vault: vault, configuration: configuration.value,
                                                      policy: policy, options: options, now: { [now] in now() })
                } catch { outcomes[account.id] = .failed; continue }
                sessions[account.id] = session
            }
            do {
                let refreshed = try await ParaAirCloudBlocking.run { try session.refreshIfDue(within: within) }
                outcomes[account.id] = refreshed ? .renewed : .notDue
            } catch let error as DriveError {
                switch error.code {
                case EACCES, EXDEV: outcomes[account.id] = .authorizationEnded
                case ENETDOWN, ENETUNREACH, EHOSTUNREACH, ECONNREFUSED, ECONNRESET, ETIMEDOUT, ENOTCONN, EIO, EAGAIN, EBUSY:
                    outcomes[account.id] = .transientFailure
                default: outcomes[account.id] = .failed
                }
            } catch { outcomes[account.id] = .failed }
        }
        return outcomes
    }
}
