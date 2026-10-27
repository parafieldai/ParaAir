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
    /// `GET /v1/billing/offer`, with a quote for the selection when one is given.
    typealias OfferLoader = @Sendable (URL, CloudAccount, ParaAirCloudOfferRequest?) throws -> ParaAirCloudBillingOffer
    enum CheckoutState: Equatable { case idle, working, opened(URL), failed(String) }
    /// What the service sells: prices, merchant of record and disclosure version. The plan sheet shows nothing else.
    enum OfferState: Equatable { case idle, loading, loaded(ParaAirCloudBillingOffer), failed(String) }
    /// The terms for one selection, shown in the review step exactly as the service will record them.
    struct Quote: Equatable {
        var selection: ParaAirCloudOfferRequest
        var offer: ParaAirCloudBillingOffer
        var terms: ParaAirCloudCheckoutTerms
    }
    enum QuoteState: Equatable { case idle, loading(ParaAirCloudOfferRequest), loaded(Quote), failed(ParaAirCloudOfferRequest, String) }
    /// A payment page this folder's account opened that ParaAir has not seen paid. While it exists no other checkout
    /// starts (review 2026-10-13): the sheet shows it again, and only Start Over replaces it.
    struct PendingCheckout: Equatable {
        var workspaceID: String
        var url: URL
        var openedAt: Date
        /// The workspace's billing status when the page opened; a different status means the checkout was settled.
        var status: ParaAirCloudBilling.Status?
        /// The free trial the checkout starts (0 for none): the page then only collects a payment method.
        var trialDays = 0
    }

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
    @Published private(set) var offer: OfferState = .idle
    @Published private(set) var quote: QuoteState = .idle
    @Published private(set) var pendingCheckout: PendingCheckout?
    /// The wait for the processor's webhook ran out without the plan changing: the sheet turns neutral (Check Again).
    @Published private(set) var paymentWaitTimedOut = false
    /// Seconds between `/v1/me` reloads while waiting for a payment or a portal change: quick at first, then wider,
    /// about 15 minutes in all. Tests shorten it.
    var billingWatchDelays: [Double] = [3, 5, 10, 15, 30, 30, 60, 60, 120, 120, 180, 240]
    /// How long an open payment page is remembered. Stripe expires a Checkout Session after 24 hours by default; any
    /// older page is closed by the service when the next checkout starts, so forgetting it cannot cause a second charge.
    nonisolated static let pendingLifetime: TimeInterval = 24 * 3600
    /// Open payment pages by state folder and account for the life of the app, so a model replaced by a folder switch
    /// still knows the page it opened.
    private static var pendingCheckouts: [String: PendingCheckout] = [:]

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
    private let offerLoader: OfferLoader
    private var offerID = UUID()
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
         checkoutStarter: CheckoutStarter? = nil, portalStarter: PortalStarter? = nil, offerLoader: OfferLoader? = nil,
         openURL: (@MainActor (URL) -> Bool)? = nil) {
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
        self.offerLoader = offerLoader ?? Self.liveOffer(dependencies)
        self.openURL = openURL ?? { NSWorkspace.shared.open($0) }
        reload()
        if policy.allowsLoopbackHTTP { developerAddress = self.baseURL?.absoluteString ?? "" }
        // Back from the browser: the payment or portal change shows as soon as the service has it, also after the
        // watch has given up while a payment page is still open.
        activation = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.billingWatch != nil || self.pendingCheckout != nil else { return }
                    self.reloadSummary()
                }
            }
    }

    // MARK: State

    var signedInAccount: CloudAccount? {
        if case .signedIn(let account) = phase { return account }
        return nil
    }
    /// The account the drive choice belongs to: a fresh sign-in, or this folder's account.
    var choosingAccountEmail: String? { pending?.account.email ?? currentAccount()?.email }
    /// The drive's workspace (saved in its profile, else looked up), or the personal one in a folder without a
    /// ParaAir Cloud drive, where Create Drive puts a new drive. Nil while a drive's workspace is unknown: then no plan,
    /// usage or billing is shown, never another workspace's (review 2026-10-13).
    var workspace: ParaAirCloudMe.Workspace? {
        guard let me = summary else { return nil }
        guard let profile, profile.backend == .paraairCloud else {
            return me.workspaces.first { $0.kind == "personal" } ?? me.workspaces.first
        }
        guard let id = driveWorkspaceID else { return nil }
        return me.workspaces.first { $0.id == id }
    }
    private var driveWorkspaceID: String? { profile?.cloudWorkspaceID ?? workspaceID }
    /// The summary state as shown: a loaded summary whose drive workspace is unknown reads as unavailable, with Retry.
    var presentationState: CloudSummaryState { summaryState == .loaded && summary != nil && workspace == nil ? .failed : summaryState }
    var usage: CloudUsage {
        CloudUsage(workspace: workspace, state: presentationState, planChoiceAvailable: planChoiceAvailable,
                   pendingCheckout: pendingCheckout != nil && pendingCheckout?.workspaceID == workspace?.id)
    }
    var manageURL: URL? { workspace?.plan?.manageUrl }
    /// Some workspace of the account offers checkout.
    var planChoiceAvailable: Bool { summary?.workspaces.contains { $0.billing?.checkoutAvailable == true } ?? false }
    var planChoice: CloudPlanChoice {
        if case .loaded(let offer) = offer { return CloudPlanChoice.make(summary, preferredWorkspaceID: workspace?.id, offer: offer) }
        return CloudPlanChoice.make(summary, preferredWorkspaceID: workspace?.id, offer: nil)
    }
    var billing: CloudBillingPresentation { usage.billing }

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
        else if pendingCheckout == nil, let key = pendingKey, let saved = Self.pendingCheckouts[key] { pendingCheckout = saved }
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
        let request = SummaryRequest(stateRoot: stateRoot, account: account, driveID: profile?.cloudDriveID, workspaceID: driveWorkspaceID)
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
                self.settlePendingCheckout()
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

    /// Opens the plan sheet and asks the service what it sells. A sheet already open is left as it is (the home
    /// window's Choose a Plan… never resets it), and an open payment page is shown again instead of a new choice.
    func presentPlans() {
        guard signedInAccount != nil, !planSheetPresented else { return }
        if let pending = pendingCheckout, Date().timeIntervalSince(pending.openedAt) > Self.pendingLifetime { setPending(nil) }
        if let pending = pendingCheckout {
            checkoutID = UUID(); checkout = .opened(pending.url); checkoutWorkspaceID = pending.workspaceID
            planSheetPresented = true
            reloadSummary()
            return
        }
        guard planChoiceAvailable else { return }
        checkoutID = UUID(); checkout = .idle; checkoutWorkspaceID = nil; quote = .idle
        planSheetPresented = true
        loadOffer()
    }

    /// `GET /v1/billing/offer` without a quote: the prices and the merchant for the plan cards.
    func loadOffer() {
        guard let account = signedInAccount, planSheetPresented else { return }
        let id = UUID(); offerID = id
        offer = .loading
        let root = stateRoot, loader = offerLoader
        Task {
            do {
                let value = try await ParaAirCloudBlocking.run { try loader(root, account, nil) }
                guard signedInAccount == account, offerID == id else { return }
                offer = .loaded(value)
            } catch {
                guard signedInAccount == account, offerID == id else { return }
                log.error("cloud billing offer failed errno=\(Self.code(error))")
                offer = .failed(Self.message(error))
            }
        }
    }

    /// The service's terms for `selection` (Appendix A), shown before the two consent boxes. Text that cannot be shown
    /// as a box and two sentences, or a plan the service no longer sells, offers no checkout.
    func loadQuote(_ selection: ParaAirCloudOfferRequest, force: Bool = false) {
        guard let account = signedInAccount, planSheetPresented else { return }
        if !force {
            switch quote {
            case .loading(let current) where current == selection: return
            case .loaded(let current) where current.selection == selection: return
            default: break
            }
        }
        quote = .loading(selection)
        let root = stateRoot, loader = offerLoader
        Task {
            let outcome: QuoteState
            do {
                let value = try await ParaAirCloudBlocking.run { try loader(root, account, selection) }
                if let quoted = value.quote {
                    outcome = ParaAirCloudCheckoutTerms(quoted).map { .loaded(Quote(selection: selection, offer: value, terms: $0)) }
                        ?? .failed(selection, "ParaAir Cloud sent plan terms this app can’t show. Try again later.")
                } else {
                    outcome = .failed(selection, "This plan can’t be bought right now.")
                }
                if signedInAccount == account, case .loading(let current) = quote, current == selection { offer = .loaded(value) }
            } catch {
                log.error("cloud billing terms failed errno=\(Self.code(error))")
                outcome = .failed(selection, Self.message(error))
            }
            guard signedInAccount == account, case .loading(let current) = quote, current == selection else { return }
            quote = outcome
        }
    }

    /// Asks the service for a checkout and opens it in the browser. Only the selection whose terms are on screen may
    /// start, with that quote's disclosure version and both boxes ticked, and never while another payment page is open.
    /// Only an issuer payment page or a documented processor checkout host is opened (ParaAirCloudBillingLink), checked
    /// here as well as in the API. A reply that arrives after the sheet closed opens nothing.
    func startCheckout(_ request: ParaAirCloudCheckoutRequest) {
        guard let account = signedInAccount, planSheetPresented, pendingCheckout == nil else { return }
        if case .working = checkout { return }
        guard case .loaded(let shown) = quote, shown.selection == request.selection, let consent = request.consent,
              consent.disclosureVersion == shown.offer.disclosureVersion, consent.autoRenew, consent.terms,
              request.trialDays == (shown.offer.quote?.trialDays ?? 0) else { return }
        let id = UUID(); checkoutID = id
        checkout = .working; checkoutWorkspaceID = request.workspaceID
        let root = stateRoot, starter = checkoutStarter
        let status = summary?.workspaces.first { $0.id == request.workspaceID }?.billing?.status
        log.notice("cloud checkout requested plan=\(request.plan.rawValue, privacy: .public) interval=\(request.interval.rawValue, privacy: .public)")
        Task {
            do {
                let url = try await ParaAirCloudBlocking.run { try starter(root, account, request) }
                guard signedInAccount == account, checkoutID == id else { return }
                let checked = try Self.billingLink(url, kind: .checkout, account: account)
                guard openURL(checked) else { throw DriveError(EIO, "The payment page couldn’t be opened in your browser") }
                setPending(PendingCheckout(workspaceID: request.workspaceID, url: checked, openedAt: Date(), status: status,
                                           trialDays: request.trialDays))
                checkout = .opened(checked)
                watchBilling(workspaceID: request.workspaceID, baseline: nil)
            } catch {
                guard signedInAccount == account, checkoutID == id else { return }
                log.error("cloud checkout failed errno=\(Self.code(error))")
                checkout = .failed(Self.message(error))
                // 409 disclosure_outdated: show the service's new text, which must be agreed to again.
                if (error as? DriveError)?.code == ESTALE { loadQuote(request.selection, force: true) }
            }
        }
    }

    func reopenCheckout() {
        guard case .opened(let url) = checkout else { return }
        _ = openURL(url)
    }

    /// "I closed it, start over": forgets the open payment page and returns to the plan choice. The contract has no
    /// call that only expires a checkout; the next checkout does it ("A new checkout makes the workspace's earlier
    /// unpaid checkouts unpayable"), and one paid meanwhile is refused with 409 busy, so starting over cannot charge twice.
    func startOver() {
        guard pendingCheckout != nil else { return }
        log.notice("cloud checkout started over")
        setPending(nil)
        billingWatch?.cancel(); billingWatch = nil; billingWatchID = UUID()
        checkoutID = UUID(); checkout = .idle; checkoutWorkspaceID = nil; quote = .idle
        if planSheetPresented { loadOffer() }
    }

    /// After the wait gave up: reload now and wait again.
    func checkPaymentAgain() {
        guard let pending = pendingCheckout else { return }
        paymentWaitTimedOut = false
        reloadSummary()
        watchBilling(workspaceID: pending.workspaceID, baseline: nil)
    }

    /// Closes the sheet. A checkout still being created is dropped: its page never opens. An open payment page is
    /// kept, so the sheet shows it again.
    func closePlans() {
        planSheetPresented = false
        checkoutID = UUID(); offerID = UUID()
        if checkout != .idle { checkout = .idle }
        if quote != .idle { quote = .idle }
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

    private var pendingKey: String? { signedInAccount.map { stateRoot.path + "\n" + $0.id } }

    private func setPending(_ value: PendingCheckout?) {
        if let key = pendingKey { Self.pendingCheckouts[key] = value }
        if pendingCheckout != value { pendingCheckout = value }
        if value == nil, paymentWaitTimedOut { paymentWaitTimedOut = false }
    }

    /// Ends the open payment page once the summary shows it settled: the plan is live, the status moved on, the
    /// workspace or its billing is gone, or the page is too old to matter. A sheet showing a page that ended without a
    /// live plan goes back to the plan choice.
    private func settlePendingCheckout() {
        guard let pending = pendingCheckout else { return }
        let billing = summary?.workspaces.first { $0.id == pending.workspaceID }?.billing
        let expired = Date().timeIntervalSince(pending.openedAt) > Self.pendingLifetime
        guard expired || billing == nil || billing?.isLive == true || billing?.status != pending.status else { return }
        log.notice("cloud checkout settled live=\(billing?.isLive == true) expired=\(expired)")
        setPending(nil)
        if billing?.isLive != true, case .opened = checkout {
            checkoutID = UUID(); checkout = .idle; checkoutWorkspaceID = nil; quote = .idle
            if planSheetPresented { loadOffer() }
        }
    }

    /// Reloads `/v1/me` on `billingWatchDelays` until the change arrives, and whenever ParaAir becomes active again
    /// meanwhile. The webhook, not the browser, changes the plan. For a checkout (`baseline` nil) only a settled
    /// payment ends the wait, not an intermediate change such as the processor's customer appearing first; when the
    /// wait runs out the sheet turns neutral. For the portal, a change to the plan's terms or status ends it.
    private func watchBilling(workspaceID: String, baseline: ParaAirCloudBilling?) {
        billingWatch?.cancel()
        let account = signedInAccount, id = UUID(), delays = billingWatchDelays
        billingWatchID = id
        paymentWaitTimedOut = false
        billingWatch = Task { [weak self] in
            var done = false
            for delay in delays {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled, account != nil, self.signedInAccount == account else { return }
                if let baseline {
                    let now = self.summary?.workspaces.first(where: { $0.id == workspaceID })?.billing
                    done = now.map { !Self.sameTerms($0, baseline) } ?? true
                } else {
                    done = self.pendingCheckout == nil
                }
                if done { break }
                self.reloadSummary()
            }
            guard let self, self.billingWatchID == id, !Task.isCancelled else { return }
            self.billingWatch = nil
            if !done, baseline == nil, self.pendingCheckout != nil { self.paymentWaitTimedOut = true }
        }
    }

    /// The fields a portal visit can change; `portalAvailable` and `checkoutAvailable` are not among them.
    nonisolated private static func sameTerms(_ a: ParaAirCloudBilling, _ b: ParaAirCloudBilling) -> Bool {
        a.status == b.status && a.plan == b.plan && a.interval == b.interval && a.seats == b.seats && a.extraStorageTb == b.extraStorageTb
            && a.cancelAtPeriodEnd == b.cancelAtPeriodEnd && a.currentPeriodEnd == b.currentPeriodEnd
    }

    /// Signed out: no sheet, no checkout, no polling. Unchanged values are not reassigned (each set republishes). The
    /// remembered payment page of this folder's account is kept for a later sign-in to the same account.
    private func endBilling() {
        billingWatch?.cancel(); billingWatch = nil; billingWatchID = UUID(); checkoutID = UUID(); offerID = UUID()
        if planSheetPresented { planSheetPresented = false }
        if checkout != .idle { checkout = .idle }
        if checkoutWorkspaceID != nil { checkoutWorkspaceID = nil }
        if offer != .idle { offer = .idle }
        if quote != .idle { quote = .idle }
        if pendingCheckout != nil { pendingCheckout = nil }
        if paymentWaitTimedOut { paymentWaitTimedOut = false }
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

    nonisolated static func liveOffer(_ dependencies: EngineOpenDependencies) -> OfferLoader {
        { root, account, selection in try api(root: root, accountID: account.id, dependencies: dependencies).billingOffer(selection) }
    }

    nonisolated static func livePortal(_ dependencies: EngineOpenDependencies) -> PortalStarter {
        { root, account, workspaceID in try api(root: root, accountID: account.id, dependencies: dependencies).billingPortal(workspaceID: workspaceID) }
    }

    nonisolated static func liveUploader(_ dependencies: EngineOpenDependencies) -> Uploader {
        { root, profile in
            UploadActivity(try Engine.open(profile: profile, stateRoot: root, dependencies: dependencies).flushUploads(), cloud: true)
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
