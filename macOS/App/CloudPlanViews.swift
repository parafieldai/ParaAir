import SwiftUI
import AppKit
import StreamDriveCore

/// The subscription lines under the plan size: what is billed and the one date that matters now.
struct CloudBillingRows: View {
    let billing: CloudBillingPresentation

    var body: some View {
        if let summary = billing.summary {
            LabeledContent(billing.summaryLabel) { Text(summary).multilineTextAlignment(.trailing) }
        }
        if let date = billing.date {
            LabeledContent(date.label) { Text(date.value).monospacedDigit() }
        }
    }
}

/// Billing buttons. A prominent one appears only when the workspace needs it to keep its plan or its files.
struct CloudBillingButtons: View {
    let controls: [CloudBillingPresentation.Control]
    var allowsProminence = true
    var disabled = false
    let perform: (CloudBillingPresentation.Action) -> Void

    var body: some View {
        ForEach(controls) { control in
            if control.prominent && allowsProminence {
                Button(control.title) { perform(control.action) }.buttonStyle(.borderedProminent).disabled(disabled)
            } else {
                Button(control.title) { perform(control.action) }.disabled(disabled)
            }
        }
    }
}

/// Choose a plan, read the checkout terms and agree, then pay in the browser. The terms box and its two unticked
/// boxes come before any checkout opens (subscription policy 7.1, Appendix E1), and fit the sheet without scrolling.
struct CloudPlanSheet: View {
    enum Step: Equatable { case choose, review }

    @ObservedObject var model: CloudAccountModel
    private let now: Date
    @State private var step: Step
    @State private var plan: ParaAirCloudBilling.Plan
    @State private var interval: ParaAirCloudBilling.Interval
    @State private var seats: Int
    @State private var teamWorkspaceID: String?
    @State private var agreesToRenewal: Bool
    @State private var agreesToTerms: Bool

    /// The arguments past `model` set a starting state for the offscreen snapshot harness.
    init(model: CloudAccountModel, step: Step = .choose, plan: ParaAirCloudBilling.Plan? = nil, interval: ParaAirCloudBilling.Interval = .month,
         seats: Int? = nil, agreed: Bool = false, now: Date = Date()) {
        self.model = model; self.now = now
        let choice = model.planChoice
        _step = State(initialValue: step)
        _plan = State(initialValue: plan ?? (choice.personal.available || !choice.team.available ? .personal : .team))
        _interval = State(initialValue: interval)
        _seats = State(initialValue: seats ?? CloudPlanChoice.defaultSeats(choice.team.workspaces.first))
        _teamWorkspaceID = State(initialValue: choice.team.workspaces.first?.id)
        _agreesToRenewal = State(initialValue: agreed)
        _agreesToTerms = State(initialValue: agreed)
    }

    private var choice: CloudPlanChoice { model.planChoice }
    private var target: ParaAirCloudMe.Workspace? {
        let option = choice.option(plan)
        return option.workspaces.first { plan == .personal || $0.id == teamWorkspaceID } ?? option.workspaces.first
    }
    private var working: Bool { model.checkout == .working }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if case .opened = model.checkout {
                opened
            } else if step == .review, let target {
                review(target)
            } else {
                choose
            }
        }
        .padding(24)
        .frame(width: 640, alignment: .leading)
    }

    private func header(_ title: String, _ detail: String?) -> some View {
        HStack(alignment: .center, spacing: 12) {
            GlideMark().frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.weight(.semibold))
                if let detail { Text(detail).foregroundStyle(.secondary) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Choose

    @ViewBuilder private var choose: some View {
        header("Choose a ParaAir Cloud plan", "Prices in US dollars. Tax is added at checkout.")
        Picker("Billing period", selection: $interval) {
            Text("Monthly").tag(ParaAirCloudBilling.Interval.month)
            Text("Yearly").tag(ParaAirCloudBilling.Interval.year)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        HStack(alignment: .top, spacing: 12) {
            PlanCard(option: choice.personal, offer: .make(.personal, interval: interval, seats: 1), selected: plan == .personal) {
                plan = .personal
            } footer: {
                EmptyView()
            }
            PlanCard(option: choice.team,
                     offer: choice.team.available ? .make(.team, interval: interval, seats: seats) : .perMember(interval: interval),
                     selected: plan == .team) {
                plan = .team
            } footer: {
                Stepper(value: $seats, in: 1...ParaAirCloudBillingCatalog.maxSeats) {
                    Text(seats == 1 ? "1 member" : "\(seats) members").monospacedDigit()
                }
                .accessibilityLabel("Team members")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        if plan == .team, choice.team.workspaces.count > 1 {
            Picker("Team workspace", selection: $teamWorkspaceID) {
                ForEach(choice.team.workspaces) { Text($0.name).tag(Optional($0.id)) }
            }
            .frame(maxWidth: 360)
        }
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { model.closePlans() }
                .keyboardShortcut(.cancelAction)
            Button("Continue") {
                agreesToRenewal = false; agreesToTerms = false
                step = .review
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(target == nil)
        }
    }

    // MARK: Review

    @ViewBuilder private func review(_ workspace: ParaAirCloudMe.Workspace) -> some View {
        let units = plan == .team ? seats : 1
        let disclosure = ParaAirCloudCheckoutDisclosure.make(plan: plan, interval: interval, seats: units, storageTb: 0, now: now,
                                                             seller: workspace.billing?.provider ?? .none)
        header("Review and agree", plan == .team ? "For \(workspace.name)" : "For your personal workspace")
        VStack(alignment: .leading, spacing: 8) {
            Text(disclosure.heading).font(.headline)
            Text(disclosure.priceLine).fontWeight(.medium)
            VStack(alignment: .leading, spacing: 5) {
                ForEach(disclosure.bullets, id: \.self) { bullet in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("•").foregroundStyle(.secondary).accessibilityHidden(true)
                        Text(bullet).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
        .accessibilityElement(children: .combine)
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $agreesToRenewal) { Text(disclosure.renewalConsent).fixedSize(horizontal: false, vertical: true) }
            Toggle(isOn: $agreesToTerms) { Text(disclosure.documentsConsent).fixedSize(horizontal: false, vertical: true) }
        }
        .toggleStyle(.checkbox)
        .disabled(working)
        if case .failed(let message) = model.checkout { ErrorLine(text: message) }
        HStack(spacing: 10) {
            Button("Back") { step = .choose }.disabled(working)
            Spacer()
            if working { ProgressView().controlSize(.small).accessibilityLabel("Opening the payment page") }
            Button("Cancel", role: .cancel) { model.closePlans() }
                .keyboardShortcut(.cancelAction)
            Button("Agree and Continue to Payment") {
                model.startCheckout(ParaAirCloudCheckoutRequest(workspaceID: workspace.id, plan: plan, interval: interval, seats: units))
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!agreesToRenewal || !agreesToTerms || working)
        }
    }

    // MARK: Paying in the browser

    /// Waiting for the processor's webhook, then the plan as `/v1/me` reports it.
    @ViewBuilder private var opened: some View {
        let workspace = model.summary?.workspaces.first { $0.id == model.checkoutWorkspaceID }
        let billing = workspace?.billing
        if let billing, billing.status == .active {
            header("Your \(billing.plan == .team ? "Team" : "Personal") plan is active", nil)
            // The plan size leads, as on the plan cards; it comes from /v1/me, so it is what the service now grants.
            VStack(alignment: .leading, spacing: 4) {
                if let limit = workspace?.plan?.storageLimitBytes, limit > 0 {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(CloudUsagePresentation.format(limit)).font(.system(size: 34, weight: .semibold)).monospacedDigit()
                        Text("of storage").font(.callout).foregroundStyle(.secondary)
                    }
                }
                let period = billing.interval == .year ? "Billed yearly." : "Billed monthly."
                Text([period, billing.currentPeriodEnd.map { "Renews \(CloudBillingPresentation.format($0))." }].compactMap { $0 }.joined(separator: " "))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        } else {
            header("Finish in your browser", nil)
            Text("Complete the payment on the page that just opened.")
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Waiting for the payment to go through…").foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
        HStack(spacing: 10) {
            if billing?.status != .active { Button("Open Payment Page Again", action: model.reopenCheckout) }
            Spacer()
            Button("Done") { model.closePlans() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// One plan as a selectable card. Rows sit on the same lines in both cards: name, size, size caption, price,
/// price detail, then a fixed-height footer (the seat stepper, or why the plan can't be chosen).
private struct PlanCard<Footer: View>: View {
    let option: CloudPlanChoice.Option
    let offer: CloudPlanOffer
    let selected: Bool
    let select: () -> Void
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        let ink: HierarchicalShapeStyle = option.available ? .primary : .secondary
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(offer.name).font(.headline)
                Spacer(minLength: 8)
                Image(systemName: selected && option.available ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected && option.available ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
            }
            Text(offer.size)
                .font(.system(size: 34, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(ink)
            Text(offer.sizeCaption).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Text(offer.price)
                .font(.title3.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(ink)
                .padding(.top, 10)
            Text(offer.detail).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Group {
                if let reason = option.reason {
                    Label(reason, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary).lineLimit(2)
                } else {
                    footer()
                }
            }
            .frame(minHeight: 30, alignment: .bottomLeading)
            .padding(.top, 8)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(selected && option.available ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: selected && option.available ? 2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture { if option.available { select() } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(offer.name), \(offer.size), \(offer.price)")
        .accessibilityAddTraits(selected && option.available ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { if option.available { select() } }
    }
}
