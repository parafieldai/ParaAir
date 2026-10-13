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

/// Choose a plan, read the checkout terms and agree, then pay in the browser. Prices, the merchant of record and the
/// terms come from the service's offer (`GET /v1/billing/offer`), so the box shows exactly what checkout records and
/// charges. The terms box and its two unticked boxes come before any checkout opens (subscription policy 7.1,
/// Appendix E1), and fit the sheet without scrolling. While a payment page is open the sheet shows it, never a second
/// checkout.
struct CloudPlanSheet: View {
    enum Step: Equatable { case choose, review }

    @ObservedObject var model: CloudAccountModel
    @State private var step: Step
    @State private var plan: ParaAirCloudBilling.Plan
    @State private var interval: ParaAirCloudBilling.Interval
    @State private var seats: Int
    @State private var teamWorkspaceID: String?
    @State private var agreesToRenewal: Bool
    @State private var agreesToTerms: Bool
    @State private var confirmingStartOver = false

    /// The arguments past `model` set a starting state for the offscreen snapshot harness.
    init(model: CloudAccountModel, step: Step = .choose, plan: ParaAirCloudBilling.Plan? = nil, interval: ParaAirCloudBilling.Interval = .month,
         seats: Int? = nil, agreed: Bool = false) {
        self.model = model
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
    private var loadedOffer: ParaAirCloudBillingOffer? {
        if case .loaded(let offer) = model.offer { return offer }
        return nil
    }
    private var selection: ParaAirCloudOfferRequest {
        ParaAirCloudOfferRequest(plan: plan, interval: interval, seats: plan == .team ? seats : 1)
    }

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
        .onChange(of: model.quote) { _, _ in agreesToRenewal = false; agreesToTerms = false }
        .onChange(of: model.offer) { _, _ in adoptOffer() }
        .confirmationDialog("Start over with a new payment page?", isPresented: $confirmingStartOver, titleVisibility: .visible) {
            Button("Start Over") { step = .choose; model.startOver() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Use this if you closed the payment page without paying. When you continue to payment again, the page you opened "
                 + "before stops working, so you can’t pay twice.")
        }
    }

    /// The offer arrived after the sheet opened: start on a plan that is on sale, and on the first team that can buy one.
    private func adoptOffer() {
        let other: ParaAirCloudBilling.Plan = plan == .personal ? .team : .personal
        if !choice.option(plan).available, choice.option(other).available { plan = other }
        if teamWorkspaceID == nil || !choice.team.workspaces.contains(where: { $0.id == teamWorkspaceID }) {
            teamWorkspaceID = choice.team.workspaces.first?.id
        }
    }

    private func header(_ title: String, _ detail: String?) -> some View {
        HStack(alignment: .center, spacing: 12) {
            GlideMark().frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.weight(.semibold))
                if let detail { Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "Sold by Paddle, our reseller." or "Sold by Parafield Inc.", from the offer (policy 2.2).
    static func seller(_ offer: ParaAirCloudBillingOffer) -> String {
        let text = "Sold by \(offer.merchant.name)\(offer.merchant.reseller ? ", our reseller" : "")"
        return text.hasSuffix(".") ? text : text + "."
    }

    // MARK: Choose

    @ViewBuilder private var choose: some View {
        if let offer = loadedOffer {
            header("Choose a ParaAir Cloud plan",
                   "Prices in \(offer.currency == "USD" ? "US dollars" : offer.currency), before tax. \(Self.seller(offer))")
            if offer.sells(.personal) || offer.sells(.team) {
                cards(offer)
            } else {
                Text("Plans can’t be bought right now.").foregroundStyle(.secondary)
                HStack { Spacer(); Button("Close", role: .cancel) { model.closePlans() }.keyboardShortcut(.cancelAction) }
            }
        } else {
            header("Choose a ParaAir Cloud plan", nil)
            if case .failed(let message) = model.offer {
                ErrorLine(text: message)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { model.closePlans() }.keyboardShortcut(.cancelAction)
                    Button("Try Again") { model.loadOffer() }.keyboardShortcut(.defaultAction)
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Loading plans…").foregroundStyle(.secondary)
                }
                HStack { Spacer(); Button("Cancel", role: .cancel) { model.closePlans() }.keyboardShortcut(.cancelAction) }
            }
        }
    }

    @ViewBuilder private func cards(_ offer: ParaAirCloudBillingOffer) -> some View {
        let priced = offer.unitAmountCents(plan, interval) != nil
        Picker("Billing period", selection: $interval) {
            Text("Monthly").tag(ParaAirCloudBilling.Interval.month)
            Text("Yearly").tag(ParaAirCloudBilling.Interval.year)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        HStack(alignment: .top, spacing: 12) {
            PlanCard(option: choice.personal,
                     offer: CloudPlanOffer.make(.personal, interval: interval, seats: 1, offer: offer) ?? .unpriced(.personal, interval: interval),
                     selected: plan == .personal) {
                plan = .personal
            } footer: {
                EmptyView()
            }
            PlanCard(option: choice.team,
                     offer: (choice.team.available ? CloudPlanOffer.make(.team, interval: interval, seats: seats, offer: offer)
                             : CloudPlanOffer.perSeat(interval: interval, offer: offer)) ?? .unpriced(.team, interval: interval),
                     selected: plan == .team) {
                plan = .team
            } footer: {
                Stepper(value: $seats, in: 1...ParaAirCloudBillingCatalog.maxSeats) {
                    Text(seats == 1 ? "1 seat" : "\(seats) seats").monospacedDigit()
                }
                .accessibilityLabel("Team seats")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        if plan == .team, let target {
            HStack(spacing: 12) {
                if choice.team.workspaces.count > 1 {
                    Picker("Team workspace", selection: $teamWorkspaceID) {
                        ForEach(choice.team.workspaces) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .frame(maxWidth: 300)
                }
                Text("Choose at least one seat for each member of \(target.name).")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { model.closePlans() }
                .keyboardShortcut(.cancelAction)
            Button("Continue") {
                agreesToRenewal = false; agreesToTerms = false
                // Fresh terms each time: the renewal date in them is the day of the checkout.
                model.loadQuote(selection, force: true)
                step = .review
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(target == nil || !priced)
        }
    }

    // MARK: Review

    @ViewBuilder private func review(_ workspace: ParaAirCloudMe.Workspace) -> some View {
        let shown: CloudAccountModel.Quote? = {
            if case .loaded(let quote) = model.quote, quote.selection == selection { return quote }
            return nil
        }()
        let detail = [plan == .team ? "For \(workspace.name)." : "For your personal workspace.",
                      (shown?.offer ?? loadedOffer).map(Self.seller)].compactMap { $0 }.joined(separator: " ")
        header("Review and agree", detail)
        if let shown {
            terms(shown.terms)
        } else if case .failed(let failed, let message) = model.quote, failed == selection {
            ErrorLine(text: message)
        } else {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Loading the plan terms…").foregroundStyle(.secondary)
            }
        }
        if case .failed(let message) = model.checkout { ErrorLine(text: message) }
        HStack(spacing: 10) {
            Button("Back") { step = .choose }.disabled(working)
            Spacer()
            if working { ProgressView().controlSize(.small).accessibilityLabel("Opening the payment page") }
            if case .failed(let failed, _) = model.quote, failed == selection {
                Button("Try Again") { model.loadQuote(selection, force: true) }
            }
            Button("Cancel", role: .cancel) { model.closePlans() }
                .keyboardShortcut(.cancelAction)
            Button("Agree and Continue to Payment") {
                guard let shown else { return }
                model.startCheckout(ParaAirCloudCheckoutRequest(
                    workspaceID: workspace.id, plan: plan, interval: interval, seats: selection.seats,
                    consent: ParaAirCloudCheckoutConsent(disclosureVersion: shown.offer.disclosureVersion, autoRenew: agreesToRenewal,
                                                         terms: agreesToTerms)))
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(shown == nil || !agreesToRenewal || !agreesToTerms || working || model.pendingCheckout != nil)
        }
    }

    /// The service's box (Appendix A) above its two consent sentences, each with an unticked box.
    @ViewBuilder private func terms(_ terms: ParaAirCloudCheckoutTerms) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(terms.heading).font(.headline)
            Text(terms.priceLine).fontWeight(.medium)
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(terms.bullets.enumerated()), id: \.offset) { _, bullet in
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
            Toggle(isOn: $agreesToRenewal) { Text(Self.consentText(terms.renewalConsent)).fixedSize(horizontal: false, vertical: true) }
            Toggle(isOn: $agreesToTerms) { Text(Self.consentText(terms.documentsConsent)).fixedSize(horizontal: false, vertical: true) }
        }
        .toggleStyle(.checkbox)
        .disabled(working)
    }

    /// Consent text with its Markdown links. Only https links stay links; any other target shows as plain text.
    static func consentText(_ markdown: String) -> AttributedString {
        guard var text = try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return AttributedString(markdown)
        }
        let unsafe = text.runs.compactMap { run in run.link.map { $0.scheme?.lowercased() == "https" ? nil : run.range } ?? nil }
        for range in unsafe { text[range].link = nil }
        return text
    }

    // MARK: Paying in the browser

    /// Waiting for the processor's webhook, then the plan as `/v1/me` reports it. When the wait runs out the sheet
    /// turns neutral: the payment may still arrive, and Check Again looks once more.
    @ViewBuilder private var opened: some View {
        let workspace = model.summary?.workspaces.first { $0.id == model.checkoutWorkspaceID }
        let billing = workspace?.billing
        let paid = billing?.status == .active || billing?.status == .pastDue
        if let billing, paid {
            header("Your \(billing.plan.map { $0 == .team ? "Team " : "Personal " } ?? "")plan is active", nil)
            // The plan size leads, as on the plan cards; it comes from /v1/me, so it is what the service now grants.
            VStack(alignment: .leading, spacing: 4) {
                if let limit = workspace?.plan?.storageLimitBytes, limit > 0 {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(CloudUsagePresentation.format(limit)).font(.system(size: 34, weight: .semibold)).monospacedDigit()
                        Text("of storage").font(.callout).foregroundStyle(.secondary)
                    }
                }
                let period = billing.interval == .year ? "Billed yearly." : billing.interval == .month ? "Billed monthly." : nil
                Text([period, billing.currentPeriodEnd.map { "Renews \(CloudBillingPresentation.format($0))." }].compactMap { $0 }.joined(separator: " "))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        } else if model.paymentWaitTimedOut {
            header("Waiting for your payment", nil)
            Text("ParaAir hasn’t seen this payment yet. If you paid, your plan shows here once the payment goes through, which can take a few minutes. "
                 + "If you closed the page without paying, open it again or start over.")
                .fixedSize(horizontal: false, vertical: true)
        } else {
            header("Finish in your browser", nil)
            Text("Complete the payment on the page that opened. ParaAir updates your plan when the payment goes through.")
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Waiting for the payment to go through…").foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
        HStack(spacing: 10) {
            if !paid {
                if model.paymentWaitTimedOut { Button("Check Again", action: model.checkPaymentAgain) }
                Button("Open Payment Page Again", action: model.reopenCheckout)
                Button("Start Over…") { confirmingStartOver = true }
            }
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
