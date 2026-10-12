import SwiftUI
import AppKit
import StreamDriveCore

/// The first section of Storage Settings. Plan and usage figures come only from
/// `/v1/me`: the plan size leads, the used amount and its bar support it, and a failed
/// summary shows a message and Retry instead of zeros. The billing lines, notice and
/// buttons follow the plan size; choosing a plan opens CloudPlanSheet (presented by
/// ConnectionsView, outside the form rows).
struct CloudAccountSection: View {
    @ObservedObject var model: CloudAccountModel
    var onDriveReady: (URL) -> Void = { _ in }
    @State private var finderName = CloudDriveSetup.defaultFinderName

    var body: some View {
        Section {
            switch model.phase {
            case .notConfigured:
                Text("ParaAir Cloud isn’t available in this build.")
                    .foregroundStyle(.secondary)
            case .signedOut:
                signedOut(error: nil)
            case .failed(let error):
                signedOut(error: error)
            case .signingIn:
                signingIn
            case .choosingDrive(let drives):
                choosing(drives)
            case .signedIn(let account):
                signedIn(account)
            }
            if model.policy.allowsLoopbackHTTP { developerAddress }
        } header: {
            Text("ParaAir Cloud")
        }
    }

    // MARK: Signed out

    @ViewBuilder private func signedOut(error: String?) -> some View {
        Text("Storage from Parafield Inc. No buckets or keys to set up. Invite-only beta.")
            .fixedSize(horizontal: false, vertical: true)
        if let error { ErrorLine(text: error) }
        Toggle("Open the sign-in page in my default browser", isOn: $model.openDefaultBrowserAutomatically)
        HStack(spacing: 10) {
            Button("Sign In to ParaAir Cloud…") { model.signIn(onReady: onDriveReady) }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy || model.baseURL == nil)
        }
        if let message = model.message { ErrorLine(text: message) }
    }

    @ViewBuilder private var signingIn: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(model.openDefaultBrowserAutomatically ? "Finish signing in to ParaAir Cloud in your browser."
                 : "Open the sign-in link below in the browser you want to use.")
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Cancel", action: model.cancelSignIn)
        }
        if let url = model.authorizationURL {
            VStack(alignment: .leading, spacing: 6) {
                Text("Browser sign-in link").font(.caption)
                HStack {
                    BrowserSignInLinkField(value: url.absoluteString)
                    Button("Copy Link", action: model.copyAuthorizationLink)
                }
                Text("Paste this link into the browser profile you want to sign in with.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Drive choice

    @ViewBuilder private func choosing(_ drives: [ParaAirCloudDrive]) -> some View {
        if let email = model.choosingAccountEmail {
            LabeledContent("Account") { Text(email).textSelection(.enabled) }
        }
        Text(drives.isEmpty ? "Create a drive to see ParaAir Cloud in Finder on this Mac."
             : "Choose the drive to show in Finder on this Mac, or create a new one.")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        LabeledContent {
            TextField("Name in Finder", text: $finderName, prompt: Text(CloudDriveSetup.defaultFinderName))
                .labelsHidden()
        } label: {
            Text("Name in Finder")
            Text("A new drive uses this name too.")
        }
        ForEach(drives) { drive in
            LabeledContent {
                Button("Use This Drive") { model.useDrive(drive, finderName: finderName, onReady: onDriveReady) }
                    .disabled(model.isBusy)
                    .accessibilityLabel("Use \(drive.name)")
            } label: {
                Text(drive.name)
                Text(drive.writable ? "Created " + drive.createdAt.formatted(date: .long, time: .omitted) : "Read only")
            }
        }
        HStack(spacing: 10) {
            if drives.isEmpty {
                Button("Create Drive") { create() }.buttonStyle(.borderedProminent).disabled(model.isBusy)
            } else {
                Button("Create Drive") { create() }.disabled(model.isBusy)
            }
            Button("Cancel", action: model.cancelDriveChoice).disabled(model.isBusy)
            if model.isBusy { ProgressView().controlSize(.small) }
        }
        if let message = model.message { ErrorLine(text: message) }
    }

    private func create() {
        model.createDrive(name: finderName, finderName: finderName, onReady: onDriveReady)
    }

    // MARK: Signed in

    @ViewBuilder private func signedIn(_ account: CloudAccount) -> some View {
        let usage = CloudUsagePresentation.make(model.workspace, state: model.summaryState)
        let billing = model.billing
        LabeledContent("Account") { Text(account.email).textSelection(.enabled) }
        if let used = usage.usedLine {
            VStack(alignment: .leading, spacing: 6) {
                Text(usage.planLine)
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                Text(used)
                    .font(.callout).monospacedDigit()
                    .foregroundStyle(.secondary)
                if let fraction = usage.fraction {
                    ProgressView(value: fraction)
                        .tint(fraction >= 1 ? .orange : nil)
                        .accessibilityLabel(used)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            if usage.retainedLine != nil || usage.transferLine != nil {
                VStack(alignment: .leading, spacing: 4) {
                    if let retained = usage.retainedLine { Text(retained) }
                    if let transfer = usage.transferLine { Text(transfer) }
                }
                .font(.callout).monospacedDigit()
                .foregroundStyle(.secondary)
            }
            if let notice = usage.notice {
                NoticeRow(notice: .init(id: "throttled", text: notice, tone: .attention))
            }
            CloudBillingRows(billing: billing)
            if let notice = billing.notice { NoticeRow(notice: notice) }
        } else {
            HStack(spacing: 10) {
                if model.summaryState == .failed {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .accessibilityHidden(true)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(usage.planLine).foregroundStyle(.secondary)
                if model.summaryState == .failed {
                    Button("Retry") { model.reloadSummary() }
                }
            }
        }
        HStack(spacing: 10) {
            if !model.hasDrive {
                Button("Create Drive…", action: model.chooseDrive)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy)
            }
            CloudBillingButtons(controls: billing.controls, allowsProminence: model.hasDrive,
                                disabled: model.isBusy || model.billingBusy, perform: model.perform)
            Button("Sign Out…", action: model.requestSignOut)
                .disabled(model.isBusy)
                .confirmationDialog("Sign out of ParaAir Cloud?", isPresented: $model.signOutRequested,
                                    titleVisibility: .visible) {
                    if pendingCount > 0 {
                        Button("Upload First") { model.signOut(uploadFirst: true) }
                        Button("Sign Out Anyway", role: .destructive) { model.signOut(uploadFirst: false) }
                    } else {
                        Button("Sign Out", role: .destructive) { model.signOut(uploadFirst: false) }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(pendingCount > 0 ? UploadNotices.notUploaded(pendingCount)
                         : "This Mac stops reaching ParaAir Cloud until you sign in again. Files already on this Mac stay here.")
                }
            if model.isBusy || model.billingBusy { ProgressView().controlSize(.small) }
        }
        if let message = model.message { ErrorLine(text: message) }
    }

    private var pendingCount: Int { model.pendingUploads?.total ?? 0 }

    // MARK: Developer builds

    private var developerAddress: some View {
        DisclosureGroup("Developer service address") {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Service address", text: $model.developerAddress, prompt: Text("http://127.0.0.1:8787"))
                Text("This build may use a local ParaAir Cloud service. The address is saved in this state folder only.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Save Address", action: model.saveDeveloperAddress)
                    .disabled(model.isBusy)
            }
            .padding(.top, 8)
        }
    }
}

struct ErrorLine: View {
    let text: String

    var body: some View {
        Label {
            Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
        .font(.callout)
    }
}
