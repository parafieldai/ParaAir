import SwiftUI
import AppKit
import Darwin
import StreamDriveCore

@MainActor
struct ConnectionsView: View {
    @StateObject private var model: ConnectionsModel
    @Binding private var reconnectRequest: String?
    @State private var pendingDisconnect: StorageConnection?
    @Environment(\.openWindow) private var openWindow

    init(stateRoot: URL, reconnectRequest: Binding<String?> = .constant(nil),
         vault: any ConnectionVault = KeychainConnectionVault(),
         onSaved: @escaping (StorageConnection) -> Void = { _ in }) {
        _model = StateObject(wrappedValue: ConnectionsModel(stateRoot: stateRoot, vault: vault, onSaved: onSaved))
        _reconnectRequest = reconnectRequest
    }

    var body: some View {
        Form {
            if !model.savedConnections.isEmpty {
                Section {
                    ForEach(model.savedConnections) { connection in
                        SavedConnectionRow(connection: connection, busy: model.isBusy,
                                           use: { model.use(connection) },
                                           reconnect: { model.reconnect(connection) },
                                           disconnect: { pendingDisconnect = connection })
                    }
                } header: {
                    HStack {
                        Text("Saved storage")
                        Spacer()
                        Button("Refresh", action: model.reload).disabled(model.isBusy).controlSize(.small)
                    }
                } footer: {
                    Text("Disconnecting stops this Mac from reaching that storage. Files waiting to upload and the local cache stay on this Mac.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if let reconnect = model.reconnectTarget {
                    LabeledContent("Signing in again to", value: reconnect.name)
                    Button("Add Different Storage Instead", action: model.beginNewConnection).disabled(model.isBusy)
                }
                Picker("Provider", selection: Binding(get: { model.provider }, set: { model.selectProvider($0) })) {
                    ForEach(ConnectionProvider.allCases, id: \.self) { Text($0.title).tag($0) }
                }.disabled(model.isBusy || model.isReconnecting)
                TextField("Name", text: $model.connectionName, prompt: Text("Shown in ParaAir"))
                    .disabled(model.isBusy)
            } header: {
                Text(model.isReconnecting ? "Sign in again" : (model.savedConnections.isEmpty ? "Add your storage" : "Add storage"))
            } footer: {
                Text("Choose your storage, authorize access, then pick the bucket ParaAir should use.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Group {
                    switch model.provider {
                    case .cloudflareR2: cloudflareFields
                    case .awsS3: awsFields
                    case .backblazeB2, .customS3: credentialFields
                    }
                }.disabled(model.isBusy)
            }

            Section {
                HStack(spacing: 10) {
                    Button("Verify and Save", action: model.verifyAndSave)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.isBusy || !model.canVerify)
                    if model.isBusy {
                        ProgressView().controlSize(.small)
                        Button("Cancel", action: model.cancel)
                    }
                }
                Label {
                    Text(model.status).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: model.isBusy ? "clock.fill" : "info.circle").foregroundStyle(.secondary)
                }
                .font(.callout).foregroundStyle(.secondary)
                if let authorizationURL = model.publicAuthorizationURL {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Browser sign-in link").font(.caption)
                        HStack {
                            BrowserSignInLinkField(value: authorizationURL.absoluteString)
                            Button("Copy Link", action: model.copyAuthorizationLink)
                        }
                        Text("Paste this link into the browser profile you want to authorize.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if model.showDriveHomeAction {
                    Button("Show ParaAir") { openWindow(id: "connections") }
                }
                if let error = model.error {
                    Label {
                        Text(error).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    }
                    .font(.callout)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 620, idealWidth: 680, minHeight: 620)
        .onAppear { model.reload(); applyReconnectRequest() }
        .onChange(of: reconnectRequest) { applyReconnectRequest() }
        .onChange(of: model.isBusy) { applyReconnectRequest() }
        .onDisappear { model.cancel() }
        .confirmationDialog(pendingDisconnect.map { "Disconnect \($0.name)?" } ?? "Disconnect?",
                            isPresented: Binding(get: { pendingDisconnect != nil },
                                                 set: { if !$0 { pendingDisconnect = nil } }),
                            presenting: pendingDisconnect) { connection in
            Button("Disconnect", role: .destructive) { model.disconnect(connection); pendingDisconnect = nil }
            Button("Cancel", role: .cancel) { pendingDisconnect = nil }
        } message: { _ in
            Text("ParaAir on this Mac will stop reaching this storage until you sign in again. Files waiting to upload and the local cache stay on this Mac.")
        }
    }

    /// Opens the saved connection the home window asked to renew, instead of a blank form.
    private func applyReconnectRequest() {
        // Wait while another sign-in or verification runs; .onChange(of: isBusy) retries.
        guard let id = reconnectRequest, !model.isBusy else { return }
        reconnectRequest = nil
        model.reload()
        if let connection = model.savedConnections.first(where: { $0.id == id }) { model.reconnect(connection) }
    }

    private var cloudflareFields: some View {
        Group {
            if Bundle.main.object(forInfoDictionaryKey: "StreamDriveCloudflareClientID") == nil {
                DisclosureGroup("Developer sign-in setup") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Registered public client ID", text: $model.cloudflareClientID)
                        Text("Register a public PKCE client with callback http://127.0.0.1:49731/oauth/callback, account-settings.read, workers-r2.write and refresh-token support. No client secret belongs in this app.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Save Registration", action: model.saveRegistration)
                            Link("Registration documentation", destination: URL(string: "https://developers.cloudflare.com/fundamentals/oauth/create-an-oauth-client/")!)
                        }
                    }.padding(.top, 8)
                }
            }
            Toggle("Open the sign-in page in my default browser", isOn: $model.openDefaultBrowserAutomatically)
            LabeledContent {
                Button("Sign In with Cloudflare", action: model.signInCloudflare)
            } label: {
                Text("Cloudflare account")
                Text("Cloudflare grants R2 access for the account you authorize. ParaAir uses only the bucket you choose, but the sign-in itself covers the account’s R2 storage.")
            }
            if model.cloudflareAuthorized {
                if model.cloudflareAccounts.isEmpty {
                    Text("No authorized Cloudflare accounts were returned.").foregroundStyle(.secondary)
                } else {
                    Picker("Account", selection: Binding(get: { model.cloudflareAccountID }, set: { model.selectCloudflareAccount($0) })) {
                        Text("Choose an account").tag("")
                        ForEach(model.cloudflareAccounts, id: \.id) { Text($0.name).tag($0.id) }
                    }.disabled(model.isReconnecting)
                }
                if !model.cloudflareAccountID.isEmpty {
                    Picker("Bucket", selection: $model.cloudflareBucketName) {
                        Text("Choose a bucket").tag("")
                        ForEach(model.cloudflareBuckets, id: \.name) { Text($0.name).tag($0.name) }
                    }.disabled(model.isReconnecting)
                    HStack {
                        Group {
                            switch model.cloudflareBucketListState {
                            case .notLoaded: Text("The bucket list hasn’t loaded yet.")
                            case .loading: Text("Loading R2 buckets…")
                            case .loaded:
                                if model.cloudflareBuckets.isEmpty {
                                    Text("No buckets in this account’s default jurisdiction. Create a Standard bucket below, or choose another account.")
                                }
                            case .failed: Text("The bucket list couldn’t load. Check the message below, then reload.")
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Reload Buckets", action: model.loadCloudflareBuckets).controlSize(.small)
                    }
                    if !model.isReconnecting {
                        LabeledContent {
                            HStack {
                                TextField("New bucket name", text: $model.cloudflareNewBucketName, prompt: Text("my-paraair-drive"))
                                    .labelsHidden()
                                Button("Create Bucket…", action: model.createCloudflareBucket)
                                    .disabled(model.cloudflareNewBucketName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        } label: {
                            Text("New Standard bucket")
                            Text("You confirm before anything is created. Cloudflare bills storage and requests.")
                        }
                    }
                }
            }
        }
    }

    private var awsFields: some View {
        Group {
            Text("AWS sign-in uses IAM Identity Center. Your organization provides the start URL and region.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Start URL", text: $model.awsStartURL, prompt: Text("https://example.awsapps.com/start"))
                .disabled(model.isReconnecting)
            TextField("Identity Center region", text: $model.awsSSORegion, prompt: Text("us-east-1"))
            LabeledContent {
                Button("Sign In with AWS", action: model.signInAWS)
            } label: {
                Text("AWS account")
            }
            if model.awsAuthorized {
                Picker("AWS account", selection: Binding(get: { model.awsAccountID }, set: { model.selectAWSAccount($0) })) {
                    Text("Choose an account").tag("")
                    ForEach(model.awsAccounts) { Text($0.accountName ?? $0.accountID).tag($0.accountID) }
                }.disabled(model.isReconnecting)
                if model.awsAccounts.isEmpty { Text("No AWS accounts are assigned to this sign-in.").foregroundStyle(.secondary) }
                if !model.awsAccountID.isEmpty {
                    Picker("Role", selection: $model.awsRoleName) {
                        Text("Choose a role").tag("")
                        ForEach(model.awsRoles) { Text($0.roleName).tag($0.roleName) }
                    }.disabled(model.isReconnecting)
                    if model.awsRoles.isEmpty { Text("No roles were returned for this account.").foregroundStyle(.secondary) }
                }
            }
            TextField("Bucket", text: $model.bucketName, prompt: Text("existing-bucket-name")).disabled(model.isReconnecting)
            TextField("Bucket region", text: $model.bucketRegion, prompt: Text("us-west-2")).disabled(model.isReconnecting)
            Text("The bucket region can differ from the Identity Center region. ParaAir checks access to an existing bucket; it doesn’t create AWS buckets.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var credentialFields: some View {
        Group {
            if model.provider == .backblazeB2 {
                LabeledContent {
                    Link("B2 S3 setup guide", destination: URL(string: "https://www.backblaze.com/apidocs/introduction-to-the-s3-compatible-api")!)
                } label: {
                    Text("Backblaze B2")
                    Text("Use an application key restricted to your existing bucket, with its S3 endpoint and region.")
                }
            }
            TextField("Endpoint", text: $model.endpoint,
                      prompt: Text(model.provider == .backblazeB2 ? "https://s3.us-west-004.backblazeb2.com" : "https://s3.example.com"))
                .disabled(model.isReconnecting)
            TextField("Bucket", text: $model.bucketName, prompt: Text("existing-bucket-name")).disabled(model.isReconnecting)
            TextField("Region", text: $model.bucketRegion,
                      prompt: Text(model.provider == .backblazeB2 ? "us-west-004" : "us-east-1")).disabled(model.isReconnecting)
            SecureField(model.provider == .backblazeB2 ? "Application key ID" : "Access key ID", text: $model.accessKey)
            SecureField(model.provider == .backblazeB2 ? "Application key" : "Secret access key", text: $model.secretKey)
            SecureField("Session token (optional)", text: $model.sessionToken)
            Text("Keys are saved in this Mac’s Keychain. The saved connection keeps only the storage address and bucket.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct SavedConnectionRow: View {
    let connection: StorageConnection
    let busy: Bool
    let use: () -> Void
    let reconnect: () -> Void
    let disconnect: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(connection.name)
                Label {
                    Text(connection.provider.title + " · " + ConnectionsModel.stateTitle(connection.state))
                } icon: {
                    Image(systemName: symbol).foregroundStyle(color)
                }
                .font(.caption).foregroundStyle(.secondary)
                if let bucket = connection.bucket {
                    Text(bucket).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Use for Drive", action: use)
                .disabled(busy || connection.state != .storageReady)
                .accessibilityLabel("Use for Drive, \(connection.name)")
            Button("Reconnect…", action: reconnect)
                .disabled(busy)
                .accessibilityLabel("Reconnect \(connection.name)")
            Button("Disconnect…", role: .destructive, action: disconnect)
                .disabled(busy || connection.state == .disconnected)
                .accessibilityLabel("Disconnect \(connection.name)")
        }
    }

    private var symbol: String {
        switch connection.state {
        case .storageReady: return "checkmark.circle.fill"
        case .needsSignIn: return "exclamationmark.triangle.fill"
        case .authorized: return "circle.dashed"
        case .disconnected: return "minus.circle"
        }
    }
    private var color: Color {
        switch connection.state {
        case .storageReady: return .green
        case .needsSignIn: return .orange
        case .authorized, .disconnected: return .secondary
        }
    }
}

private struct BrowserSignInLinkField: NSViewRepresentable {
    let value: String

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: value)
        field.isEditable = false
        field.isSelectable = true
        field.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        field.lineBreakMode = .byClipping
        field.setAccessibilityLabel("Browser sign-in link")
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) { field.stringValue = value }
}

@MainActor
final class ConnectionsModel: ObservableObject {
    enum BucketListState { case notLoaded, loading, loaded, failed }

    @Published private(set) var provider: ConnectionProvider = .cloudflareR2
    @Published var connectionName = "Cloudflare R2"
    @Published var cloudflareClientID = ""
    @Published var openDefaultBrowserAutomatically = true
    @Published private(set) var cloudflareAuthorized = false
    @Published private(set) var cloudflareAccounts: [CloudflareAccount] = []
    @Published private(set) var cloudflareAccountID = ""
    @Published private(set) var cloudflareBuckets: [CloudflareBucket] = []
    @Published private(set) var cloudflareBucketListState: BucketListState = .notLoaded
    @Published var cloudflareBucketName = ""
    @Published var cloudflareNewBucketName = ""
    @Published var awsStartURL = ""
    @Published var awsSSORegion = ""
    @Published private(set) var awsAuthorized = false
    @Published private(set) var awsAccounts: [AWSAccount] = []
    @Published private(set) var awsAccountID = ""
    @Published private(set) var awsRoles: [AWSAccountRole] = []
    @Published var awsRoleName = ""
    @Published var bucketName = ""
    @Published var bucketRegion = ""
    @Published var endpoint = ""
    @Published var accessKey = ""
    @Published var secretKey = ""
    @Published var sessionToken = ""
    @Published private(set) var isBusy = false
    @Published private(set) var status = "Authorize storage to begin."
    @Published private(set) var showDriveHomeAction = false
    @Published private(set) var savedConnections: [StorageConnection] = []
    @Published private(set) var reconnectTarget: StorageConnection?
    @Published private(set) var error: String?
    @Published private(set) var publicAuthorizationURL: URL?

    private let stateRoot: URL
    private let store: ConnectionStore
    private let vault: any ConnectionVault
    private let cloudflare = CloudflareR2Provider(transport: URLSessionOAuthTransport(maximumResponseBytes: 4 * 1024 * 1024))
    private let aws = AWSIdentityCenterClient()
    private let onSaved: (StorageConnection) -> Void
    private var cloudflareTokens: OAuthTokens?
    private var awsSession: AWSAccessSession?
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(stateRoot: URL, vault: any ConnectionVault = KeychainConnectionVault(),
         onSaved: @escaping (StorageConnection) -> Void = { _ in }) {
        self.stateRoot = stateRoot; self.store = ConnectionStore(root: stateRoot)
        self.vault = vault; self.onSaved = onSaved
        if let registration = try? CloudflareClientRegistration.load(stateRoot: stateRoot) {
            cloudflareClientID = registration.clientID
        }
    }

    var canVerify: Bool {
        guard !connectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch provider {
        case .cloudflareR2: return cloudflareAuthorized && !cloudflareAccountID.isEmpty && !cloudflareBucketName.isEmpty
        case .awsS3: return awsAuthorized && !awsAccountID.isEmpty && !awsRoleName.isEmpty && !bucketName.isEmpty && !bucketRegion.isEmpty
        case .backblazeB2, .customS3:
            return !endpoint.isEmpty && !bucketName.isEmpty && !bucketRegion.isEmpty && !accessKey.isEmpty && !secretKey.isEmpty
        }
    }
    var isReconnecting: Bool { reconnectTarget != nil }

    func reload() {
        do { savedConnections = try store.list() }
        catch { self.error = Self.safeMessage(error) }
    }

    func selectProvider(_ value: ConnectionProvider) {
        guard provider != value, reconnectTarget == nil else { return }
        cancel(); clearAuthorization(); provider = value; connectionName = value.title
        bucketName = ""; bucketRegion = ""; endpoint = ""; awsStartURL = ""; awsSSORegion = ""
        status = value == .cloudflareR2 || value == .awsS3 ? "Sign in to choose storage." : "Enter the credentials and target supplied by your storage service."
    }

    func beginNewConnection() {
        guard !isBusy else { return }
        cancel(); reconnectTarget = nil; connectionName = provider.title
        bucketName = ""; bucketRegion = ""; endpoint = ""; awsStartURL = ""; awsSSORegion = ""
        status = "Authorize a new storage connection."
    }

    func reconnect(_ connection: StorageConnection) {
        guard !isBusy else { return }
        cancel(); reconnectTarget = connection; provider = connection.provider; connectionName = connection.name
        bucketName = connection.bucket ?? ""; bucketRegion = connection.region ?? ""; endpoint = connection.endpoint ?? ""
        awsStartURL = connection.startURL ?? ""; awsSSORegion = ""
        // The session is read only to prefill the nonsecret SSO region. It is never
        // copied into UI text or files, and a new sign-in remains required.
        if connection.provider == .awsS3, let secrets = try? vault.load(id: connection.id),
           secrets.binding == connection.credentialBinding, let data = secrets.providerSession,
           let session = try? JSONDecoder().decode(AWSAccessSession.self, from: data) {
            awsSSORegion = session.region
        }
        status = "Sign in again or enter replacement keys for the existing storage target."
    }

    func use(_ connection: StorageConnection) {
        guard !isBusy else { return }
        showDriveHomeAction = false
        do {
            let existing = try ProfileStore(root: stateRoot).list().first
            if let existing, existing.connectionID != connection.id {
                error = nil
                status = "\"\(existing.name)\" already uses another storage connection. \(connection.name) is saved, but adding a second Finder drive isn't available in this setup screen yet. Open ParaAir to continue using your existing drive."
                showDriveHomeAction = true
                return
            }
            let (saved, _) = try store.credentials(connection.id, vault: vault)
            if let existing {
                status = "\"\(existing.name)\" already uses \(saved.name). Open ParaAir to continue Finder setup or open your drive."
                showDriveHomeAction = true
            }
            error = nil; onSaved(saved)
        } catch { self.error = Self.safeMessage(error); status = "Reconnect this saved connection to continue." }
    }

    func saveRegistration() {
        guard !isBusy else { return }
        do {
            let registration = CloudflareClientRegistration(clientID: cloudflareClientID.trimmingCharacters(in: .whitespacesAndNewlines), callbackPort: 49731)
            try registration.save(stateRoot: stateRoot)
            cloudflareClientID = registration.clientID
            error = nil; status = "OAuth registration saved. Sign in with Cloudflare to continue."
        } catch { self.error = Self.safeMessage(error) }
    }

    func signInCloudflare() {
        guard !isBusy else { return }
        let openAutomatically = openDefaultBrowserAutomatically
        clearAuthorization()
        let pendingStatus = openAutomatically ? "Complete Cloudflare authorization in your browser."
            : "Open the browser sign-in link in the profile you want to authorize."
        start(status: pendingStatus) { id in
            let registration = try CloudflareClientRegistration.load(stateRoot: self.stateRoot)
            guard registration.callbackPort == 49731 else { throw OAuthError.invalidConfiguration }
            let config = try CloudflareR2Provider.oauthConfiguration(clientID: registration.clientID, redirectURI: registration.redirectURI)
            let tokens = try await runLoopbackOAuth(configuration: config, openAuthorizationURL: { url in
                try await MainActor.run {
                    try self.checkCurrent(id)
                    self.publicAuthorizationURL = url
                }
                if openAutomatically { try await Self.openBrowser(url) }
            })
            try self.checkCurrent(id)
            self.publicAuthorizationURL = nil
            let granted = Set((tokens.scope ?? config.scopes.joined(separator: " ")).split(separator: " ").map(String.init))
            guard granted.contains("workers-r2.write") else { throw CloudflareConnectionError.insufficientPermission }
            guard let expiry = tokens.expiresAt, expiry > Date().addingTimeInterval(30) else { throw OAuthError.invalidTokenResponse }
            let accounts = try await self.cloudflare.listAccounts(accessToken: tokens.accessToken)
            try self.checkCurrent(id)
            self.cloudflareTokens = tokens; self.cloudflareAuthorized = true; self.cloudflareAccounts = accounts
            self.cloudflareAccountID = ""; self.cloudflareBuckets = []; self.cloudflareBucketName = ""
            self.cloudflareBucketListState = .notLoaded
            if let reconnect = self.reconnectTarget {
                guard let account = reconnect.accountID, let bucket = reconnect.bucket,
                      accounts.contains(where: { $0.id == account }) else { throw CloudflareConnectionError.accountNotAuthorized }
                self.cloudflareAccountID = account
                let buckets = try await self.fetchCloudflareBuckets(accountID: account, accessToken: tokens.accessToken, operationID: id)
                try self.checkCurrent(id)
                guard buckets.contains(where: { $0.name == bucket }) else { throw CloudflareConnectionError.bucketNotFound }
                self.cloudflareAccountID = account; self.cloudflareBuckets = buckets; self.cloudflareBucketName = bucket
            }
            self.status = accounts.isEmpty ? "No Cloudflare accounts were authorized." : "Signed in. Choose an account and existing bucket."
        }
    }

    func selectCloudflareAccount(_ value: String) {
        guard !isBusy, value.isEmpty || cloudflareAccounts.contains(where: { $0.id == value }) else { return }
        cloudflareAccountID = value; cloudflareBuckets = []; cloudflareBucketName = ""; cloudflareNewBucketName = ""
        cloudflareBucketListState = .notLoaded
        if !value.isEmpty { loadCloudflareBuckets() }
    }

    func createCloudflareBucket() {
        guard !isBusy, reconnectTarget == nil, let tokens = cloudflareTokens,
              let account = cloudflareAccounts.first(where: { $0.id == cloudflareAccountID }) else { return }
        let bucket = cloudflareNewBucketName.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            // Validate the exact target before presenting approval. This helper
            // builds a URL locally and performs no network request.
            _ = try CloudflareR2Provider.bucketEndpoint(accountID: account.id, bucketName: bucket)
        } catch { self.error = Self.safeMessage(error); return }
        let alert = NSAlert()
        alert.messageText = "Create Standard R2 bucket?"
        alert.informativeText = "Account: \(account.name) (\(account.id))\nBucket: \(bucket)\n\nThis creates a default-jurisdiction Standard bucket in your Cloudflare account. Stored data and requests can incur Cloudflare charges. R2 billing must already be enabled."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Create bucket")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        start(status: "Creating the confirmed Standard R2 bucket…") { id in
            try self.checkCurrent(id)
            let created = try await self.cloudflare.createBucket(accountID: account.id, bucketName: bucket, accessToken: tokens.accessToken)
            try self.checkCurrent(id)
            // Preserve a verified creation result even if the following list
            // request fails, so retrying a list does not repeat a bucket write.
            self.cloudflareBuckets.removeAll(where: { $0.name == created.name })
            self.cloudflareBuckets.append(created)
            self.cloudflareBucketName = created.name; self.cloudflareNewBucketName = ""
            do {
                let buckets = try await self.fetchCloudflareBuckets(accountID: account.id, accessToken: tokens.accessToken, operationID: id)
                try self.checkCurrent(id)
                self.cloudflareBuckets = buckets.contains(where: { $0.name == created.name }) ? buckets : buckets + [created]
                self.status = "Standard bucket created and selected. Verify & Save to authorize this connection."
            } catch {
                try self.checkCurrent(id)
                self.error = Self.safeMessage(error)
                self.status = "Standard bucket created and selected. The bucket list could not be refreshed."
            }
        }
    }

    func loadCloudflareBuckets() {
        guard !isBusy, let tokens = cloudflareTokens, !cloudflareAccountID.isEmpty else { return }
        let selected = cloudflareAccountID
        start(status: "Loading existing R2 buckets…") { id in
            let buckets = try await self.fetchCloudflareBuckets(accountID: selected, accessToken: tokens.accessToken, operationID: id)
            try self.checkCurrent(id)
            self.cloudflareBuckets = buckets
            if !buckets.contains(where: { $0.name == self.cloudflareBucketName }) { self.cloudflareBucketName = "" }
            self.status = buckets.isEmpty ? "No default-jurisdiction R2 buckets were returned." : "Choose the existing bucket for this connection."
        }
    }

    private func fetchCloudflareBuckets(accountID: String, accessToken: String,
                                         operationID: UUID) async throws -> [CloudflareBucket] {
        try checkCurrent(operationID)
        cloudflareBucketListState = .loading
        do {
            let buckets = try await cloudflare.listBuckets(accountID: accountID, accessToken: accessToken)
            try checkCurrent(operationID)
            cloudflareBucketListState = .loaded
            return buckets
        } catch {
            try checkCurrent(operationID)
            cloudflareBucketListState = .failed
            throw error
        }
    }

    func signInAWS() {
        guard !isBusy else { return }
        let startText = awsStartURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let region = awsSSORegion.trimmingCharacters(in: .whitespacesAndNewlines)
        clearAuthorization()
        start(status: "Complete AWS IAM Identity Center authorization in your browser.") { id in
            guard let url = URL(string: startText) else { throw OAuthError.invalidConfiguration }
            let authorization = try await self.aws.registerAndStart(startURL: url, region: region)
            try self.checkCurrent(id)
            try await Self.openBrowser(authorization.verificationURL)
            let session = try await self.aws.pollAuthorization(authorization)
            let accounts = try await self.aws.listAccounts(session: session)
            try self.checkCurrent(id)
            self.awsSession = session; self.awsAuthorized = true; self.awsAccounts = accounts
            self.awsAccountID = ""; self.awsRoles = []; self.awsRoleName = ""
            if let reconnect = self.reconnectTarget {
                guard let account = reconnect.accountID, let role = reconnect.roleName,
                      accounts.contains(where: { $0.accountID == account }) else { throw OAuthError.authorizationDenied }
                let roles = try await self.aws.listRoles(accountID: account, session: session)
                try self.checkCurrent(id)
                guard roles.contains(where: { $0.roleName == role }) else { throw OAuthError.authorizationDenied }
                self.awsAccountID = account; self.awsRoles = roles; self.awsRoleName = role
            }
            self.status = accounts.isEmpty ? "No AWS accounts were assigned." : "Signed in. Choose an account and role, then enter the bucket and its region."
        }
    }

    func selectAWSAccount(_ value: String) {
        guard !isBusy, value.isEmpty || awsAccounts.contains(where: { $0.accountID == value }) else { return }
        awsAccountID = value; awsRoles = []; awsRoleName = ""
        guard let session = awsSession, !value.isEmpty else { return }
        start(status: "Loading assigned AWS roles…") { id in
            let roles = try await self.aws.listRoles(accountID: value, session: session)
            try self.checkCurrent(id)
            self.awsRoles = roles; self.status = roles.isEmpty ? "No roles were returned for this AWS account." : "Choose a role and enter the existing bucket."
        }
    }

    func verifyAndSave() {
        guard canVerify, !isBusy else { return }
        let selectedProvider = provider
        let name = connectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedBucket = selectedProvider == .cloudflareR2 ? cloudflareBucketName : bucketName.trimmingCharacters(in: .whitespacesAndNewlines)
        let region = bucketRegion.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpointText = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = selectedProvider == .cloudflareR2 ? cloudflareAccountID : awsAccountID
        let role = awsRoleName
        let pendingTokens = cloudflareTokens
        let pendingSession = awsSession
        let reconnect = reconnectTarget
        let connectionID = reconnect?.id ?? UUID().uuidString.lowercased()
        // These remain in memory only, and are cleared after successful persistence.
        let key = accessKey, secret = secretKey, token = sessionToken
        start(status: "Verifying access to the selected bucket…") { id in
            let connection: StorageConnection
            let credentials: ConnectionSecrets
            if selectedProvider == .cloudflareR2 {
                guard let tokens = pendingTokens, let expiry = tokens.expiresAt, expiry > Date().addingTimeInterval(30) else {
                    throw OAuthError.expired
                }
                _ = try await self.cloudflare.validateBucket(accountID: account, bucketName: selectedBucket, accessToken: tokens.accessToken)
                let endpoint = try CloudflareR2Provider.bucketEndpoint(accountID: account, bucketName: selectedBucket)
                connection = StorageConnection(id: connectionID, provider: .cloudflareR2, name: name, state: .storageReady,
                    accountID: account, bucket: selectedBucket, endpoint: endpoint.absoluteString, region: "auto")
                credentials = ConnectionSecrets(binding: connection.credentialBinding, oauth: tokens, storageExpiresAt: expiry)
            } else {
                let target: S3ConnectionTarget
                let s3: S3Credentials
                var expiry: Date?
                var sessionData: Data?
                if selectedProvider == .awsS3 {
                    guard let session = pendingSession else { throw OAuthError.expired }
                    let suffix = region.hasPrefix("cn-") ? "amazonaws.com.cn" : "amazonaws.com"
                    guard let endpoint = URL(string: "https://s3.\(region).\(suffix)") else { throw S3ConnectionError.invalidTarget }
                    target = try S3ConnectionTarget(provider: .aws, endpoint: endpoint, bucket: selectedBucket, region: region)
                    let temporary = try await self.aws.credentials(accountID: account, roleName: role, session: session)
                    s3 = temporary.credentials; expiry = temporary.expiresAt
                    sessionData = try JSONEncoder().encode(session)
                } else {
                    guard let endpoint = URL(string: endpointText) else { throw S3ConnectionError.invalidTarget }
                    target = try S3ConnectionTarget(provider: selectedProvider == .backblazeB2 ? .backblazeB2 : .custom,
                        endpoint: endpoint, bucket: selectedBucket, region: region)
                    s3 = try S3Credentials(accessKey: key, secretKey: secret, sessionToken: token.isEmpty ? nil : token)
                }
                _ = try await S3ConnectionProbe().headBucket(target: target, credentials: s3)
                connection = StorageConnection(id: connectionID, provider: selectedProvider, name: name, state: .storageReady,
                    accountID: selectedProvider == .awsS3 ? account : nil, bucket: selectedBucket,
                    endpoint: target.endpoint.absoluteString, region: target.region,
                    roleName: selectedProvider == .awsS3 ? role : nil, startURL: pendingSession?.startURL.absoluteString)
                credentials = ConnectionSecrets(binding: connection.credentialBinding, s3: s3,
                                                storageExpiresAt: expiry, providerSession: sessionData)
            }
            try self.checkCurrent(id)
            try connection.validate()
            if let reconnect, reconnect.credentialBinding != connection.credentialBinding {
                throw DriveError(EXDEV, "Reconnect using the original storage target, or choose Add Different Storage Instead.")
            }
            try self.store.authorize(connection, secrets: credentials, vault: self.vault)
            self.reconnectTarget = nil; self.clearAuthorization(); self.reload()
            self.status = reconnect == nil ? "Bucket access verified and connection saved. Object upload permissions have not been tested."
                : "Authorization renewed for the existing storage target."
            self.onSaved(connection)
        }
    }

    func disconnect(_ connection: StorageConnection) {
        guard !isBusy else { return }
        do {
            try store.disconnect(connection.id, vault: vault); reload(); error = nil
            status = "Remote access disconnected. Local cache and pending writes are retained."
        } catch { self.error = Self.safeMessage(error) }
    }

    func cancel() {
        generation = UUID(); task?.cancel(); task = nil; isBusy = false
        showDriveHomeAction = false
        clearAuthorization(); error = nil; status = "Connection setup cancelled. Saved connections are retained."
    }

    func copyAuthorizationLink() {
        guard let url = publicAuthorizationURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    private func clearAuthorization() {
        publicAuthorizationURL = nil
        cloudflareTokens = nil; cloudflareAuthorized = false; cloudflareAccounts = []
        cloudflareAccountID = ""; cloudflareBuckets = []; cloudflareBucketName = ""; cloudflareNewBucketName = ""
        cloudflareBucketListState = .notLoaded
        awsSession = nil; awsAuthorized = false; awsAccounts = []; awsAccountID = ""; awsRoles = []; awsRoleName = ""
        accessKey = ""; secretKey = ""; sessionToken = ""
    }

    private func start(status: String, operation: @escaping @MainActor (UUID) async throws -> Void) {
        guard !isBusy else { return }
        showDriveHomeAction = false
        let id = UUID(); generation = id; isBusy = true; error = nil; self.status = status
        task = Task { [weak self] in
            guard let self else { return }
            do { try await operation(id) }
            catch {
                guard self.generation == id else { return }
                self.error = Self.safeMessage(error)
                self.status = "Connection setup needs attention."
                if error as? OAuthError == .expired || error as? CloudflareConnectionError == .unauthorized {
                    self.clearAuthorization(); self.status = "Authorization expired. Sign in again."
                } else if error as? OAuthError == .authorizationDenied || error as? CloudflareConnectionError == .accountNotAuthorized {
                    self.clearAuthorization(); self.status = "Sign in with access to the original account and storage target."
                }
            }
            guard self.generation == id else { return }
            self.publicAuthorizationURL = nil
            self.isBusy = false; self.task = nil
        }
    }

    private func checkCurrent(_ id: UUID) throws {
        guard generation == id, !Task.isCancelled else { throw CancellationError() }
    }

    private nonisolated static func openBrowser(_ url: URL) async throws {
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        guard opened else { throw OAuthError.requestFailed }
    }

    private static func safeMessage(_ error: Error) -> String {
        if error is CancellationError { return "Connection setup cancelled." }
        if let error = error as? OAuthError { return error.localizedDescription }
        if let error = error as? CloudflareConnectionError { return error.localizedDescription }
        if let error = error as? S3ConnectionError { return error.localizedDescription }
        if let error = error as? DriveError { return error.localizedDescription }
        return "The storage connection could not be completed. Check its target and authorization, then try again."
    }

    static func stateTitle(_ state: StorageConnectionState) -> String {
        switch state {
        case .authorized: return "Choose storage"
        case .storageReady: return "Storage ready"
        case .needsSignIn: return "Sign-in required"
        case .disconnected: return "Disconnected"
        }
    }
}
