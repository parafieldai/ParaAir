import Foundation
import AppKit
import Combine
import Darwin
import os
import StreamDriveCore

/// ParaAir Cloud sign-in, drive choice and plan summary for one state folder. Every
/// network call goes through `ParaAirCloudBlocking.run`, so neither the main actor nor
/// the cooperative pool waits on I/O. Values shown come only from `/v1/me`.
@MainActor
final class CloudAccountModel: ObservableObject {
    enum Phase: Equatable {
        case notConfigured, signedOut, signingIn
        case choosingDrive([ParaAirCloudDrive])
        case signedIn(CloudAccount)
        case failed(String)
    }
    struct SummaryRequest: Sendable {
        let stateRoot: URL
        let account: CloudAccount
        let driveID: String?
        /// Known once a drive was chosen or looked up; the loader skips the lookup then.
        let workspaceID: String?
    }
    typealias SummaryLoader = @Sendable (SummaryRequest) throws -> (me: ParaAirCloudMe, workspaceID: String?)
    /// Uploads what it can and returns what is still waiting.
    typealias Uploader = @Sendable (URL, DriveProfile) throws -> UploadActivity
    /// The account's drives and summary, for choosing a drive in an already signed-in folder.
    typealias DriveLister = @Sendable (URL, CloudAccount) throws -> (drives: [ParaAirCloudDrive], me: ParaAirCloudMe)
    /// `POST /v1/billing/checkout` and `POST /v1/billing/portal`: the page to open in the browser.
    typealias CheckoutStarter = @Sendable (URL, CloudAccount, ParaAirCloudCheckoutRequest) throws -> URL
    typealias PortalStarter = @Sendable (URL, CloudAccount, String) throws -> URL
    enum CheckoutState: Equatable { case idle, working, opened(URL), failed(String) }

    nonisolated static let inviteOnly = "ParaAir Cloud is invite-only right now. Use the email address your invite was sent to."

    @Published private(set) var phase: Phase = .signedOut
    @Published private(set) var summary: ParaAirCloudMe?
    @Published private(set) var summaryState: CloudSummaryState = .idle
    @Published var pendingUploads: UploadActivity?
    @Published private(set) var authorizationURL: URL?
    @Published var openDefaultBrowserAutomatically = true
    @Published private(set) var isBusy = false
    @Published private(set) var message: String?
    @Published private(set) var hasDrive = false
    @Published var signOutRequested = false
    @Published var developerAddress = ""
    @Published private(set) var planSheetPresented = false
    @Published private(set) var checkout: CheckoutState = .idle
    /// The workspace the last checkout was for, so the sheet can tell when its plan becomes active.
    @Published private(set) var checkoutWorkspaceID: String?
    @Published private(set) var billingBusy = false

    let stateRoot: URL
    let policy: ParaAirCloudTransportPolicy
    /// Set by the app so the sign-out confirmation counts uploads that are current.
    var refreshPendingUploads: (@MainActor () async -> UploadActivity?)?
    private(set) var baseURL: URL?
    private let dependencies: EngineOpenDependencies
    private let resolveBaseURL: @MainActor (URL) -> URL?
    private let summaryLoader: SummaryLoader
    private let uploader: Uploader
    private let driveLister: DriveLister
    private let checkoutStarter: CheckoutStarter
    private let portalStarter: PortalStarter
    private let openURL: @MainActor (URL) -> Bool
    private var billingWatch: Task<Void, Never>?
    private var billingWatchID = UUID()
    /// The checkout request whose reply may still open the browser; closing the sheet replaces it.
    private var checkoutID = UUID()
    private var activation: AnyCancellable?
    private var profile: DriveProfile?
    private var pending: ParaAirCloudSignIn.Result?
    private var workspaceID: String?
    private var generation = UUID()
    private var signInTask: Task<Void, Never>?
    private var summaryTask: Task<Void, Never>?
    private var summaryLoadedAt: Date?
    private let log = Logger(subsystem: "dev.streamdrive.app", category: "cloud")

    init(stateRoot: URL, dependencies: EngineOpenDependencies = .live, baseURL: (@MainActor (URL) -> URL?)? = nil,
         summaryLoader: SummaryLoader? = nil, uploader: Uploader? = nil, driveLister: DriveLister? = nil,
         checkoutStarter: CheckoutStarter? = nil, portalStarter: PortalStarter? = nil, openURL: (@MainActor (URL) -> Bool)? = nil) {
        self.stateRoot = stateRoot.standardizedFileURL
        self.dependencies = dependencies
        policy = dependencies.cloudPolicy
        let policy = dependencies.cloudPolicy
        resolveBaseURL = baseURL ?? { ParaAirCloudConfiguration.baseURL(stateRoot: $0, policy: policy) }
        self.summaryLoader = summaryLoader ?? Self.liveSummary(dependencies)
        self.uploader = uploader ?? Self.liveUploader(dependencies)
        self.driveLister = driveLister ?? Self.liveDriveLister(dependencies)
        self.checkoutStarter = checkoutStarter ?? Self.liveCheckout(dependencies)
        self.portalStarter = portalStarter ?? Self.livePortal(dependencies)
        self.openURL = openURL ?? { NSWorkspace.shared.open($0) }
        reload()
        if policy.allowsLoopbackHTTP { developerAddress = self.baseURL?.absoluteString ?? "" }
        // Back from the browser: the payment or portal change shows as soon as the service has it.
        activation = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { if self?.billingWatch != nil { self?.reloadSummary() } } }
    }

    // MARK: State

    var signedInAccount: CloudAccount? {
        if case .signedIn(let account) = phase { return account }
        return nil
    }
    /// The account the drive choice belongs to: a fresh sign-in, or this folder's account.
    var choosingAccountEmail: String? { pending?.account.email ?? currentAccount()?.email }
    /// The drive's workspace when known, otherwise the personal one.
    var workspace: ParaAirCloudMe.Workspace? {
        guard let me = summary else { return nil }
        return me.workspaces.first { $0.id == workspaceID } ?? me.workspaces.first { $0.kind == "personal" } ?? me.workspaces.first
    }
    var usage: CloudUsage { CloudUsage(workspace: workspace, state: summaryState, planChoiceAvailable: planChoiceAvailable) }
    var manageURL: URL? { workspace?.plan?.manageUrl }
    /// Some workspace of the account offers checkout.
    var planChoiceAvailable: Bool { summary?.workspaces.contains { $0.billing?.checkoutAvailable == true } ?? false }
    var planChoice: CloudPlanChoice { CloudPlanChoice.make(summary, preferredWorkspaceID: workspace?.id) }
    var billing: CloudBillingPresentation {
        CloudBillingPresentation.make(workspace, state: summaryState, planChoiceAvailable: planChoiceAvailable)
    }

    /// Rereads this folder's account record, drive and service address. A sign-in or
    /// drive choice in progress keeps its phase.
    func reload() {
        let resolved = resolveBaseURL(stateRoot)
        if baseURL != resolved { baseURL = resolved }
        let profiles = (try? ProfileStore(root: stateRoot).list()) ?? []
        profile = profiles.first
        if hasDrive == profiles.isEmpty { hasDrive = !profiles.isEmpty }
        let account = currentAccount()
        switch phase {
        case .signingIn, .choosingDrive: return
        case .failed where account?.state != .signedIn && resolved != nil: return
        default: break
        }
        let next: Phase
        if let account, account.state == .signedIn { next = .signedIn(account) }
        else if resolved == nil { next = .notConfigured }
        else { next = .signedOut }
        if phase != next { phase = next }
        if signedInAccount == nil, summary != nil || summaryState != .idle {
            summary = nil; summaryState = .idle; summaryLoadedAt = nil; workspaceID = nil
        }
        if signedInAccount == nil { endBilling() }
    }

    private func currentAccount() -> CloudAccount? {
        let accounts = CloudAccountStore(root: stateRoot).list().accounts
        if let id = profile?.cloudAccountID { return accounts.first { $0.id == id } }
        return accounts.first { $0.state == .signedIn } ?? accounts.first
    }

    // MARK: Sign-in

    /// Opens the loopback PKCE sign-in. `onReady` receives the state folder once a drive
    /// is ready there: at once for an account that already has a drive, otherwise after
    /// the drive choice.
    func signIn(onReady: @escaping (URL) -> Void = { _ in }) {
        guard !isBusy, let issuer = baseURL else { return }
        switch phase { case .signingIn, .choosingDrive: return; default: break }
        let id = UUID(); generation = id
        message = nil; authorizationURL = nil; phase = .signingIn
        let root = stateRoot, policy = policy, vault = dependencies.cloudVault
        let configuration = dependencies.cloudConfiguration, openAutomatically = openDefaultBrowserAutomatically
        log.notice("cloud sign-in started browser=\(openAutomatically)")
        signInTask = Task { [weak self] in
            do {
                let result = try await ParaAirCloudSignIn.run(issuer: issuer, currentStateRoot: root, policy: policy, vault: vault,
                                                              configuration: configuration) { url in
                    try await MainActor.run {
                        guard let self, self.generation == id else { throw CancellationError() }
                        self.authorizationURL = url
                    }
                    if openAutomatically {
                        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
                        guard opened else { throw OAuthError.requestFailed }
                    }
                }
                let driveExists = (try? await ParaAirCloudBlocking.run { try ProfileStore(root: result.stateRoot).list().isEmpty == false }) ?? false
                guard let self, self.generation == id else {
                    if !driveExists { await ParaAirCloudSignIn.cancelUnfinished(result, vault: vault) }
                    return
                }
                self.signInTask = nil
                self.authorizationURL = nil
                self.summary = result.me; self.summaryState = .loaded; self.summaryLoadedAt = Date()
                self.log.notice("cloud sign-in finished drives=\(result.drives.count) hasDrive=\(driveExists) newFolder=\(result.createdStateRoot)")
                if driveExists {
                    self.phase = .signedIn(result.account)
                    onReady(result.stateRoot)
                    if result.stateRoot == self.stateRoot { self.reload() }
                } else {
                    self.pending = result
                    self.phase = .choosingDrive(result.drives)
                }
            } catch {
                guard let self, self.generation == id else { return }
                self.signInTask = nil
                self.authorizationURL = nil
                if error is CancellationError { self.phase = .signedOut; self.reload(); return }
                self.log.error("cloud sign-in failed errno=\(Self.code(error))")
                self.phase = .failed(Self.message(error))
            }
        }
    }

    func cancelSignIn() {
        guard case .signingIn = phase else { return }
        generation = UUID(); signInTask?.cancel(); signInTask = nil
        authorizationURL = nil; phase = .signedOut
        reload()
    }

    func copyAuthorizationLink() {
        guard let url = authorizationURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    // MARK: Drive choice

    /// From a signed-in folder without a drive: list the account's drives to attach or create one.
    func chooseDrive() {
        guard let account = signedInAccount, !hasDrive, !isBusy else { return }
        isBusy = true; message = nil
        let root = stateRoot, lister = driveLister
        Task {
            defer { isBusy = false }
            do {
                let (drives, me) = try await ParaAirCloudBlocking.run { try lister(root, account) }
                guard signedInAccount == account else { return }
                summary = me; summaryState = .loaded; summaryLoadedAt = Date()
                phase = .choosingDrive(drives)
            } catch { message = Self.message(error) }
        }
    }

    func useDrive(_ drive: ParaAirCloudDrive, finderName: String, onReady: @escaping (URL) -> Void = { _ in }) {
        guard let target = choiceTarget(), let name = validFinderName(finderName) else { return }
        let dependencies = dependencies, root = target.root, account = target.account
        finishDriveChoice(account: account, root: root, workspaceID: drive.workspaceId, onReady: onReady) {
            try CloudDriveSetup.attach(driveID: drive.id, finderName: name, name: DriveNaming.profileName(for: name),
                                       accountID: account.id, stateRoot: root, dependencies: dependencies)
        }
    }

    func createDrive(name: String, finderName: String, onReady: @escaping (URL) -> Void = { _ in }) {
        guard let target = choiceTarget(), let finder = validFinderName(finderName) else { return }
        let root = target.root, account = target.account
        let driveName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !driveName.isEmpty else { message = "Enter a name for the drive."; return }
        let candidates = (pending?.me ?? summary)?.workspaces.filter {
            $0.status == "active" && ($0.role == "owner" || $0.role == "admin")
        } ?? []
        guard let workspace = candidates.first(where: { $0.kind == "personal" }) ?? candidates.first else {
            message = "Your ParaAir Cloud account has no workspace where you can create drives."
            return
        }
        let dependencies = dependencies
        finishDriveChoice(account: account, root: root, workspaceID: workspace.id, onReady: onReady) {
            try CloudDriveSetup.create(workspaceID: workspace.id, name: driveName, finderName: finder,
                                       profileName: DriveNaming.profileName(for: finder), accountID: account.id,
                                       stateRoot: root, dependencies: dependencies)
        }
    }

    /// Leaves the choice. After a fresh sign-in this signs out, revokes, and removes a
    /// state folder that sign-in created for nothing.
    func cancelDriveChoice() {
        guard case .choosingDrive = phase, !isBusy else { return }
        message = nil
        guard let result = pending else { phase = .signedOut; reload(); return }
        pending = nil; isBusy = true
        let vault = dependencies.cloudVault
        Task {
            await ParaAirCloudSignIn.cancelUnfinished(result, vault: vault)
            isBusy = false
            summary = nil; summaryState = .idle
            phase = .signedOut
            reload()
        }
    }

    private func choiceTarget() -> (root: URL, account: CloudAccount)? {
        guard case .choosingDrive = phase, !isBusy else { return nil }
        if let pending { return (pending.stateRoot, pending.account) }
        guard let account = currentAccount(), account.state == .signedIn else { return nil }
        return (stateRoot, account)
    }

    private func validFinderName(_ value: String) -> String? {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        do { try DriveProfile.validateFinderName(name); return name }
        catch { message = error.localizedDescription; return nil }
    }

    private func finishDriveChoice(account: CloudAccount, root: URL, workspaceID: String, onReady: @escaping (URL) -> Void,
                                   _ setup: @escaping @Sendable () throws -> DriveProfile) {
        isBusy = true; message = nil
        Task {
            defer { isBusy = false }
            do {
                _ = try await ParaAirCloudBlocking.run(setup)
                log.notice("cloud drive ready newFolder=\(root != self.stateRoot)")
                pending = nil
                self.workspaceID = workspaceID
                phase = .signedIn(account)
                onReady(root)
                if root == stateRoot { reload() }
            } catch {
                log.error("cloud drive setup failed errno=\(Self.code(error))")
                message = Self.message(error)
            }
        }
    }

    // MARK: Summary

    /// Loads `/v1/me` unless a loaded summary is younger than `maxAge` seconds. Earlier
    /// values stay visible while a refresh runs; a failure hides them.
    func reloadSummary(maxAge: TimeInterval = 0) {
        guard let account = signedInAccount else { return }
        if maxAge > 0, summaryState == .loaded, let loaded = summaryLoadedAt, Date().timeIntervalSince(loaded) < maxAge { return }
        guard summaryTask == nil else { return }
        if summary == nil || summaryState != .loaded { summaryState = .loading }
        let request = SummaryRequest(stateRoot: stateRoot, account: account, driveID: profile?.cloudDriveID, workspaceID: workspaceID)
        let loader = summaryLoader
        summaryTask = Task { [weak self] in
            let outcome: Result<(me: ParaAirCloudMe, workspaceID: String?), Error>
            do { outcome = .success(try await ParaAirCloudBlocking.run { try loader(request) }) }
            catch { outcome = .failure(error) }
            guard let self else { return }
            self.summaryTask = nil
            guard self.signedInAccount?.id == account.id else { return }
            switch outcome {
            case .success(let value):
                self.summary = value.me
                if let id = value.workspaceID { self.workspaceID = id }
                self.summaryState = .loaded; self.summaryLoadedAt = Date()
            case .failure(let error):
                self.log.error("cloud summary failed errno=\(Self.code(error))")
                self.summaryState = .failed
            }
        }
    }

    // MARK: Sign-out

    /// Counts uploads that haven't finished, then asks for confirmation.
    func requestSignOut() {
        guard signedInAccount != nil, !isBusy else { return }
        Task {
            if let refresh = refreshPendingUploads, let current = await refresh() { pendingUploads = current }
            signOutRequested = true
        }
    }

    /// `uploadFirst` tries the uploads and stays signed in if any remain.
    func signOut(uploadFirst: Bool) {
        guard let account = signedInAccount, !isBusy else { return }
        isBusy = true; message = nil
        let root = stateRoot, vault = dependencies.cloudVault, uploader = uploader, profile = profile
        let policy = policy, configuration = dependencies.cloudConfiguration
        Task {
            defer { isBusy = false }
            if uploadFirst, let profile, profile.backend == .paraairCloud {
                do {
                    let remaining = try await ParaAirCloudBlocking.run { try uploader(root, profile) }
                    pendingUploads = remaining
                    guard remaining.total == 0 else {
                        message = "\(UploadNotices.files(remaining.total)) still \(remaining.total == 1 ? "hasn’t" : "haven’t") uploaded, so you’re still signed in."
                        return
                    }
                } catch {
                    message = Self.message(error)
                    return
                }
            }
            do {
                let tokens = try await ParaAirCloudBlocking.run { try CloudAccountStore(root: root).signOut(account.id, vault: vault) }
                log.notice("cloud signed out uploadFirst=\(uploadFirst)")
                summary = nil; summaryState = .idle; summaryLoadedAt = nil; workspaceID = nil
                endBilling()
                phase = .signedOut
                reload()
                // Best effort, after the record already says signed out (spec 3.5).
                if let tokens, let issuer = try? ParaAirCloudIssuer.validate(account.issuer) {
                    Task.detached { await ParaAirCloudSignIn.revoke(tokens, issuer: issuer, policy: policy, configuration: configuration) }
                }
            } catch { message = Self.message(error) }
        }
    }

    // MARK: Plans and billing

    /// The one action the billing status offers; the home window routes its buttons here too.
    func perform(_ action: CloudBillingPresentation.Action) {
        switch action {
        case .choosePlan: presentPlans()
        case .updatePayment, .managePlan: openPortal()
        }
    }

    func presentPlans() {
        guard signedInAccount != nil, planChoiceAvailable else { return }
        checkoutID = UUID(); checkout = .idle; checkoutWorkspaceID = nil
        planSheetPresented = true
    }

    /// Asks the service for a checkout and opens it in the browser. Only an issuer payment page or a documented
    /// processor checkout host is opened (ParaAirCloudBillingLink), checked here as well as in the API. A reply
    /// that arrives after the sheet closed opens nothing.
    func startCheckout(_ request: ParaAirCloudCheckoutRequest) {
        guard let account = signedInAccount, planSheetPresented else { return }
        if case .working = checkout { return }
        let id = UUID(); checkoutID = id
        checkout = .working; checkoutWorkspaceID = request.workspaceID
        let root = stateRoot, starter = checkoutStarter
        let baseline = summary?.workspaces.first { $0.id == request.workspaceID }?.billing
        log.notice("cloud checkout requested plan=\(request.plan.rawValue, privacy: .public) interval=\(request.interval.rawValue, privacy: .public)")
        Task {
            do {
                let url = try await ParaAirCloudBlocking.run { try starter(root, account, request) }
                guard signedInAccount == account, checkoutID == id else { return }
                let checked = try Self.billingLink(url, kind: .checkout, account: account)
                guard openURL(checked) else { throw DriveError(EIO, "The payment page couldn’t be opened in your browser") }
                checkout = .opened(checked)
                watchBilling(workspaceID: request.workspaceID, baseline: baseline)
            } catch {
                guard signedInAccount == account, checkoutID == id else { return }
                log.error("cloud checkout failed errno=\(Self.code(error))")
                checkout = .failed(Self.message(error))
            }
        }
    }

    func reopenCheckout() {
        guard case .opened(let url) = checkout else { return }
        _ = openURL(url)
    }

    /// Closes the sheet. A checkout still being created is dropped: its page never opens.
    func closePlans() {
        planSheetPresented = false
        checkoutID = UUID()
        if checkout != .idle { checkout = .idle }
    }

    /// The processor's portal for the drive's workspace (payment method, cancel, resume, invoices). A service from
    /// before billing may instead link a plan page (`plan.manageUrl`, parafield.ai only).
    func openPortal() {
        guard let account = signedInAccount, let workspace, !billingBusy else { return }
        guard let billing = workspace.billing else {
            if let manage = manageURL { _ = openURL(manage) }
            return
        }
        guard billing.portalAvailable else { return }
        billingBusy = true; message = nil
        let root = stateRoot, starter = portalStarter, id = workspace.id
        Task {
            defer { billingBusy = false }
            do {
                let url = try await ParaAirCloudBlocking.run { try starter(root, account, id) }
                guard signedInAccount == account else { return }
                let checked = try Self.billingLink(url, kind: .portal, account: account)
                guard openURL(checked) else { throw DriveError(EIO, "The billing page couldn’t be opened in your browser") }
                log.notice("cloud billing portal opened")
                watchBilling(workspaceID: id, baseline: billing)
            } catch {
                guard signedInAccount == account else { return }
                log.error("cloud billing portal failed errno=\(Self.code(error))")
                message = Self.message(error)
            }
        }
    }

    nonisolated static func billingLink(_ url: URL, kind: ParaAirCloudBillingLink.Kind, account: CloudAccount) throws -> URL {
        try ParaAirCloudBillingLink.validate(url.absoluteString, kind: kind, issuer: try ParaAirCloudIssuer.validate(account.issuer))
    }

    /// Reloads `/v1/me` on a widening schedule (about 15 minutes in all) until the workspace's billing changes,
    /// and whenever ParaAir becomes active again meanwhile. The webhook, not the browser, changes the plan.
    private func watchBilling(workspaceID: String, baseline: ParaAirCloudBilling?) {
        billingWatch?.cancel()
        let account = signedInAccount, id = UUID()
        billingWatchID = id
        billingWatch = Task { [weak self] in
            for delay in [3, 5, 10, 15, 30, 30, 60, 60, 120, 120, 180, 240] {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled, account != nil, self.signedInAccount == account else { return }
                if self.summary?.workspaces.first(where: { $0.id == workspaceID })?.billing != baseline { break }
                self.reloadSummary()
            }
            if let self, self.billingWatchID == id { self.billingWatch = nil }
        }
    }

    /// Signed out: no sheet, no checkout, no polling. Unchanged values are not reassigned (each set republishes).
    private func endBilling() {
        billingWatch?.cancel(); billingWatch = nil; billingWatchID = UUID(); checkoutID = UUID()
        if planSheetPresented { planSheetPresented = false }
        if checkout != .idle { checkout = .idle }
        if checkoutWorkspaceID != nil { checkoutWorkspaceID = nil }
    }

    // MARK: Developer service address

    func saveDeveloperAddress() {
        let text = developerAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            guard let url = URL(string: text) else { throw DriveError(EINVAL, "Invalid ParaAir Cloud service address") }
            try ParaAirCloudConfiguration.saveDeveloperBaseURL(url, stateRoot: stateRoot, policy: policy)
            message = nil
            if case .failed = phase { phase = .signedOut }
            reload()
        } catch { message = Self.message(error) }
    }

    // MARK: Live dependencies

    nonisolated static func api(root: URL, accountID: String, dependencies: EngineOpenDependencies) throws -> ParaAirCloudAPI {
        let session = try ParaAirCloudSession.shared(root: root, accountID: accountID, vault: dependencies.cloudVault,
                                                     configuration: dependencies.cloudConfiguration, policy: dependencies.cloudPolicy,
                                                     options: dependencies.cloudSessionOptions)
        return ParaAirCloudAPI(http: try session.http(), tokens: session)
    }

    nonisolated static func liveSummary(_ dependencies: EngineOpenDependencies) -> SummaryLoader {
        { request in
            let api = try api(root: request.stateRoot, accountID: request.account.id, dependencies: dependencies)
            let me = try api.me()
            // The drive's workspace decides which plan applies; the lookup is best effort.
            let workspaceID = request.workspaceID ?? request.driveID.flatMap { try? api.drive($0).drive.workspaceId }
            return (me, workspaceID)
        }
    }

    nonisolated static func liveDriveLister(_ dependencies: EngineOpenDependencies) -> DriveLister {
        { root, account in
            let api = try api(root: root, accountID: account.id, dependencies: dependencies)
            return (try api.drives(), try api.me())
        }
    }

    nonisolated static func liveCheckout(_ dependencies: EngineOpenDependencies) -> CheckoutStarter {
        { root, account, request in try api(root: root, accountID: account.id, dependencies: dependencies).billingCheckout(request) }
    }

    nonisolated static func livePortal(_ dependencies: EngineOpenDependencies) -> PortalStarter {
        { root, account, workspaceID in try api(root: root, accountID: account.id, dependencies: dependencies).billingPortal(workspaceID: workspaceID) }
    }

    nonisolated static func liveUploader(_ dependencies: EngineOpenDependencies) -> Uploader {
        { root, profile in
            UploadActivity(try Engine.open(profile: profile, stateRoot: root, dependencies: dependencies).flushUploads())
        }
    }

    /// Fixed, user-facing text. Service messages are already fixed per error code.
    nonisolated static func message(_ error: Error) -> String {
        if let error = error as? OAuthError {
            return error == .authorizationDenied ? inviteOnly : error.localizedDescription
        }
        if let error = error as? DriveError { return sentence(error.localizedDescription) }
        return "ParaAir Cloud couldn’t finish that. Try again."
    }

    /// Core messages are short phrases; shown alone they read as sentences.
    nonisolated private static func sentence(_ text: String) -> String {
        guard let last = text.last, !".!?".contains(last) else { return text }
        return text + "."
    }

    nonisolated private static func code(_ error: Error) -> Int32 { (error as? DriveError)?.code ?? -1 }
}
