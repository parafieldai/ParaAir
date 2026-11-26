import Foundation
import StreamDriveCore

/// ParaAir Cloud plan status from the `/v1/me` billing object, for Storage Settings and the home window. The plan
/// size stays the hero figure (CloudUsagePresentation); this adds what the subscription is doing and the one action
/// that helps. Dates are UTC, as in the billing emails. Every action maps to CloudAccountModel.
struct CloudBillingPresentation: Equatable {
    enum Action: Equatable { case choosePlan, updatePayment, managePlan }
    struct Control: Equatable, Identifiable {
        var action: Action
        var title: String
        /// Only when the workspace needs the action to keep its files or its plan.
        var prominent = false
        var id: String { title }
    }
    struct Row: Equatable { var label: String; var value: String }

    /// For example "Team, 3 seats, billed yearly".
    var summary: String?
    /// "Billing" while the plan is paid for; "Previous plan" once it has ended and nothing is billed.
    var summaryLabel = "Billing"
    var date: Row?
    var notice: HomePresentation.Notice?
    var controls: [Control] = []
    /// The home window's drive status for a workspace with no storage that no button here can fix, when it isn't "ask
    /// the owner": its owner can't buy Team because the service doesn't sell it.
    var noStorageDetail: String?

    static let choosePlan = Control(action: .choosePlan, title: "Choose a Plan…")
    static let startTrial = "Start Free Trial…"
    static let managePlan = Control(action: .managePlan, title: "Manage Plan…")
    /// While a payment page is open: the sheet shows it again (or starts over), never a second checkout.
    static let finishPayment = Control(action: .choosePlan, title: "Finish Payment…")
    static let previousPlan = "Previous plan"
    /// A team owner whose team can't buy Team (Stripe Managed Payments doesn't sell it): say so, so a Personal plan isn't
    /// bought for a team drive it doesn't cover (review 2026-11-26).
    static let teamUnavailable = "Team plans aren’t available yet, so this team workspace can’t get storage yet. A Personal plan covers only your personal workspace."
    /// The same for a team whose plan ended: nothing here can start a new one.
    static let teamPlanNotSold = "Team plans aren’t available yet, so this team can’t start a new plan."

    /// `planChoiceAvailable`: some workspace of the account offers checkout, so the plan sheet has something to sell.
    /// `pendingCheckout`: a payment page for this workspace is open and not paid yet.
    static func make(_ workspace: ParaAirCloudMe.Workspace?, state: CloudSummaryState, planChoiceAvailable: Bool,
                     pendingCheckout: Bool = false) -> CloudBillingPresentation {
        guard state != .failed, let workspace else { return .init() }
        guard let billing = workspace.billing else {
            // A service from before billing may still link a plan page.
            return .init(controls: workspace.plan?.manageUrl == nil ? [] : [managePlan])
        }
        var result = presentation(workspace, billing, planChoiceAvailable: planChoiceAvailable)
        if pendingCheckout, !billing.isLive {
            let prominent = result.controls.first { $0.action == .choosePlan }?.prominent ?? false
            result.controls = [Control(action: .choosePlan, title: finishPayment.title, prominent: prominent)]
                + result.controls.filter { $0.action != .choosePlan }
            if result.notice == nil {
                result.notice = .init(id: "billing", text: "A payment page is open for this workspace. Your plan shows here once the payment goes through.",
                                      tone: .neutral)
            }
        }
        return result
    }

    /// A self-serve workspace nothing has paid for yet: no subscription and no storage (contract README "Billing",
    /// added 2026-10-27). Uploads fail until its free trial or a plan starts.
    static func isUnpaid(_ workspace: ParaAirCloudMe.Workspace?) -> Bool {
        guard let workspace, let billing = workspace.billing, let plan = workspace.plan else { return false }
        return billing.status == .none && plan.storageLimitBytes == 0
    }

    private static func presentation(_ workspace: ParaAirCloudMe.Workspace, _ billing: ParaAirCloudBilling,
                                     planChoiceAvailable: Bool) -> CloudBillingPresentation {
        let owner = workspace.role == "owner"
        let checkout = billing.checkoutAvailable, portal = billing.portalAvailable
        // The service sells this team no plan: billing is set up, the caller owns the team, and still `checkoutAvailable`
        // is false. For a workspace without a live subscription that means Team has no price (Stripe Managed Payments
        // doesn't sell it; contract README "What is sold"). Whether the account's other workspaces can buy (Personal
        // already paid for, or not) doesn't change that (review 2026-11-26).
        let teamNotSold = workspace.kind == ParaAirCloudBilling.Plan.team.rawValue && owner && !checkout && billing.provider != .none
            && workspace.status != "suspended"
        var result = CloudBillingPresentation(summary: summary(billing))
        func day(_ date: Date?) -> String? { date.map(format) }
        switch billing.status {
        case .none:
            result.summary = nil
            // The workspace's first checkout starts a free trial: the button says so.
            let title = billing.trialDays == nil ? choosePlan.title : startTrial
            // A team's plan is bought for that team, so a team drive offers Choose a Plan… only when the team itself can
            // check out. Otherwise the sheet could sell only Personal, which adds nothing to this team (review 2026-11-26).
            let team = workspace.kind == ParaAirCloudBilling.Plan.team.rawValue
            let canChoose = team ? checkout : planChoiceAvailable
            if isUnpaid(workspace) {
                // "No storage yet" is the headline (Storage Settings) or the drive status (home, menu bar); this says what to do.
                let trial = billing.trialDays.map { "Start your \($0)-day free trial to store files in ParaAir Cloud. Nothing is charged before it ends." }
                result.notice = .init(id: "billing", text: teamNotSold ? teamUnavailable : owner
                    ? trial ?? "Choose a plan to store files in ParaAir Cloud."
                    : "This workspace has no storage yet. Ask the workspace owner to choose a plan.", tone: .attention)
                if canChoose, owner { result.controls = [Control(action: .choosePlan, title: title, prominent: true)] }
                if teamNotSold { result.noStorageDetail = teamUnavailable }
            } else if canChoose {
                result.controls = [Control(action: .choosePlan, title: title)]
            }
        case .active where billing.cancelAtPeriodEnd:
            let end = day(billing.readOnlyAt ?? billing.currentPeriodEnd)
            result.date = end.map { Row(label: "Ends", value: $0) }
            let after = day(billing.deletionAt).map { "Files then stay read-only until \($0) and are deleted after that." }
                ?? "Files then stay read-only for 30 days and are deleted after that."
            let ends = end.map { " and ends on \($0)" } ?? ""
            if billing.inTrial {
                // Cancelled during the free trial: it ends then, and nothing is ever charged.
                result.notice = .init(id: "billing", text: owner
                    ? "Your free trial is cancelled\(ends), and you won’t be charged. \(after) To keep the plan, resume it in Manage Plan."
                    : "This workspace’s free trial is cancelled\(ends). \(after)", tone: .attention)
            } else {
                result.notice = .init(id: "billing", text: owner
                    ? "Your plan is cancelled\(ends). \(after) To keep it, resume the plan in Manage Plan."
                    : "This workspace’s plan is cancelled\(ends). \(after)", tone: .attention)
            }
            if portal { result.controls = [managePlan] }
        case .active where billing.inTrial:
            // The first charge falls when the trial ends; the summary says how it is billed after that.
            result.date = day(billing.trialEndsAt).map { Row(label: "Free trial ends", value: $0) }
            if portal { result.controls = [managePlan] }
        case .active:
            result.date = day(billing.currentPeriodEnd).map { Row(label: "Renews", value: $0) }
            if portal { result.controls = [managePlan] }
        case .pastDue:
            let grace = day(billing.graceEndsAt)
            result.date = grace.map { Row(label: "Grace period ends", value: $0) }
            let until = grace.map { "Everything keeps working until \($0)." } ?? "Everything keeps working for now."
            if checkout {
                // The service offers checkout during the grace period only once the processor has ended the subscription
                // over the payment: a new card no longer keeps the plan, a new plan does.
                result.notice = .init(id: "billing", text: "Your last payment didn’t go through, so your subscription has ended. \(until) "
                                      + "Choose a plan by then to keep full access.", tone: .attention)
                result.controls = [Control(action: .choosePlan, title: "Choose a Plan…", prominent: true)]
                break
            }
            result.notice = .init(id: "billing", text: owner
                ? "Your last payment didn’t go through. \(until) Update your payment method by then to keep your plan."
                : "This workspace’s last payment didn’t go through. \(until) Ask the workspace owner to update the payment method.",
                tone: .attention)
            if portal { result.controls = [Control(action: .updatePayment, title: "Update Payment…", prominent: true)] }
        case .readOnly:
            // Why, until when and what to do come first: the menu bar panel shows four lines.
            result.summaryLabel = previousPlan
            let deletion = day(billing.deletionAt)
            result.date = deletion.map { Row(label: "Read-only until", value: $0) }
            let until = deletion.map { " until \($0)" } ?? ""
            let by = deletion == nil ? "" : " by then"
            let readOnlyText: String
            if teamNotSold {
                // No Choose a Plan… to point at: say why, and what keeps the files.
                readOnlyText = "Your team’s plan ended, so this workspace is read-only\(until). \(teamPlanNotSold) "
                    + "Copy the files you need out of the drive\(by), or they’re deleted."
            } else {
                readOnlyText = owner
                    ? "Your plan ended, so this workspace is read-only\(until). Choose a plan\(by), or the files are deleted."
                    : "This workspace’s plan ended, so it’s read-only\(until). Ask the workspace owner to choose a plan\(by), or the files are deleted."
            }
            result.notice = .init(id: "billing", text: readOnlyText, tone: .problem)
            result.controls = (checkout ? [Control(action: .choosePlan, title: "Choose a Plan…", prominent: true)] : []) + (portal ? [managePlan] : [])
        case .pendingDeletion:
            // Deletion waits for the service's purge, so the date is when it became possible, not a promise.
            result.summaryLabel = previousPlan
            let deletion = day(billing.deletionAt)
            result.date = deletion.map { Row(label: "Deletion scheduled", value: $0) }
            let ended = deletion.map { "The read-only period ended on \($0), so" } ?? "The read-only period ended, so"
            result.notice = .init(id: "billing", text: teamNotSold
                ? "\(ended) this workspace’s files can be deleted at any time. \(teamPlanNotSold) Copy the files you need out of the drive now."
                : owner
                ? "\(ended) this workspace’s files can be deleted at any time. Choose a plan now to keep them."
                : "\(ended) this workspace’s files can be deleted at any time. Ask the workspace owner to choose a plan now to keep them.",
                tone: .problem)
            if checkout { result.controls = [Control(action: .choosePlan, title: "Choose a Plan…", prominent: true)] }
        case .deleting:
            result.summaryLabel = previousPlan
            result.notice = .init(id: "billing", text: "This workspace’s files are being deleted because its plan ended.", tone: .problem)
        case .deleted:
            result.summaryLabel = previousPlan
            result.notice = .init(id: "billing", text: checkout
                ? "This workspace’s files were deleted after its plan ended. Choose a plan to use it again."
                : "This workspace’s files were deleted after its plan ended.", tone: .neutral)
            if checkout { result.controls = [choosePlan] }
        }
        return result
    }

    /// Nil when the service sends a paid status without a plan it knows: the status, dates and actions still show.
    static func summary(_ billing: ParaAirCloudBilling) -> String? {
        guard let plan = billing.plan, let interval = billing.interval else { return nil }
        var parts = [plan == .team ? "Team" : "Personal"]
        if plan == .team, let seats = billing.seats, seats > 0 { parts.append(seats == 1 ? "1 seat" : "\(seats) seats") }
        // In a trial that renews, billing starts when it ends; a cancelled trial is never billed, so it says nothing more.
        parts.append((interval == .year ? "billed yearly" : "billed monthly") + (billing.inTrial && !billing.cancelAtPeriodEnd ? " after the trial" : ""))
        if billing.extraStorageTb > 0 { parts.append("\(billing.extraStorageTb) TB added storage") }
        return parts.joined(separator: ", ")
    }

    static func format(_ date: Date) -> String {
        var style = Date.FormatStyle.dateTime.month(.wide).day().year()
        style.timeZone = TimeZone(identifier: "UTC") ?? .current
        return date.formatted(style)
    }
    /// A deadline with its UTC time, "October 19, 2026 at 14:03 UTC", as the service's terms give it.
    static func formatDeadline(_ date: Date) -> String {
        var time = Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
        time.timeZone = TimeZone(identifier: "UTC") ?? .current
        time.locale = Locale(identifier: "en_GB")
        return "\(format(date)) at \(date.formatted(time)) UTC"
    }
}

/// What the plan sheet can sell: Personal for the account's personal workspace, Team for a team workspace the user
/// owns, and only plans the service's offer has a price for. The service requires the plan to match the workspace's
/// kind, so each option carries its workspaces.
struct CloudPlanChoice: Equatable {
    struct Option: Equatable {
        var plan: ParaAirCloudBilling.Plan
        /// Workspaces where this plan can be bought now, the preferred one first.
        var workspaces: [ParaAirCloudMe.Workspace]
        /// Why the option can't be chosen, when `workspaces` is empty.
        var reason: String?
        var available: Bool { !workspaces.isEmpty }
    }
    var personal: Option
    var team: Option

    func option(_ plan: ParaAirCloudBilling.Plan) -> Option { plan == .team ? team : personal }

    /// `offer` nil: not loaded yet, so nothing is on sale.
    static func make(_ me: ParaAirCloudMe?, preferredWorkspaceID: String?, offer: ParaAirCloudBillingOffer?) -> CloudPlanChoice {
        let all = me?.workspaces ?? []
        func option(_ plan: ParaAirCloudBilling.Plan) -> Option {
            let kind = all.filter { $0.kind == plan.rawValue }
            let open = kind.filter { $0.billing?.checkoutAvailable == true }
                .sorted { ($0.id == preferredWorkspaceID ? 0 : 1) < ($1.id == preferredWorkspaceID ? 0 : 1) }
            guard open.isEmpty || offer?.sells(plan) != true else { return Option(plan: plan, workspaces: open) }
            let reason: String
            if let offer, !offer.sells(plan) {
                // No price in either period (Team through Stripe Managed Payments): nothing here can change that.
                reason = notSold(plan)
            } else if kind.isEmpty {
                reason = plan == .team ? "For team workspaces. This account has none yet." : "This account has no personal workspace."
            } else if kind.contains(where: { $0.billing?.isLive == true }) {
                reason = plan == .team ? "Your team already has a plan." : "Your personal workspace already has a plan."
            } else if !kind.contains(where: { $0.role == "owner" }) {
                reason = "Only the workspace owner can choose this plan."
            } else {
                reason = "Not available right now."
            }
            return Option(plan: plan, workspaces: [], reason: reason)
        }
        return CloudPlanChoice(personal: option(.personal), team: option(.team))
    }

    /// "Team isn’t available yet.": the offer has no price for the plan in either period.
    static func notSold(_ plan: ParaAirCloudBilling.Plan) -> String { "\(plan == .team ? "Team" : "Personal") isn’t available yet." }

    /// The plan the sheet starts on: the drive's own kind when it can be bought (a team drive starts on Team for that
    /// team), else Personal when it can, else Team when it can, else Personal.
    static func initialPlan(_ choice: CloudPlanChoice, driveKind: String?) -> ParaAirCloudBilling.Plan {
        if driveKind == ParaAirCloudBilling.Plan.team.rawValue, choice.team.available { return .team }
        return choice.personal.available || !choice.team.available ? .personal : .team
    }

    /// Team seats start at the seats the team's members use, as the Members section's list reports them (`seatsUsed`),
    /// because the service refuses fewer seats than members; one when that list isn't loaded for this team. Not
    /// `plan.seats`: that is the seats usable now (an admin grant or the last paid count), which could pre-select seats
    /// nobody uses (review 2026-10-13).
    static func defaultSeats(_ workspace: ParaAirCloudMe.Workspace?, members: ParaAirCloudMemberList? = nil) -> Int {
        guard let workspace, let members, members.workspace.id == workspace.id else { return 1 }
        return min(ParaAirCloudBillingCatalog.maxSeats, max(1, members.workspace.seatsUsed))
    }

    /// The seats the sheet moves to when the team or its members list changes: the default for that team, unless the
    /// person set the seats or the count is already that. Nil: leave them.
    static func adoptedSeats(_ seats: Int, chosen: Bool, team: ParaAirCloudMe.Workspace?, members: ParaAirCloudMemberList?) -> Int? {
        guard !chosen else { return nil }
        let next = defaultSeats(team, members: members)
        return next == seats ? nil : next
    }
}

/// Plan card figures from the service's offer. The plan size leads, the total price supports it, the per-seat price
/// and the yearly saving support that. Nil when the offer has no price for the plan and period.
struct CloudPlanOffer: Equatable {
    var name: String
    var size: String
    var sizeCaption: String
    var price: String
    var detail: String

    static func make(_ plan: ParaAirCloudBilling.Plan, interval: ParaAirCloudBilling.Interval, seats: Int,
                     offer: ParaAirCloudBillingOffer) -> CloudPlanOffer? {
        let units = plan == .team ? seats : 1
        guard let unitCents = offer.unitAmountCents(plan, interval),
              let totalCents = offer.amountCents(plan: plan, interval: interval, seats: units) else { return nil }
        let period = interval == .year ? "year" : "month"
        let total = offer.format(cents: totalCents, short: true), unit = offer.format(cents: unitCents, short: true)
        let saving = offer.yearlySavingsCents(plan).map { offer.format(cents: $0 * units, short: true) }
        let size = CloudUsagePresentation.format(ParaAirCloudBillingCatalog.terabyte * Int64(units))
        switch plan {
        case .personal:
            let other = interval == .year ? saving.map { "Saves \($0) a year" }
                : offer.unitAmountCents(.personal, .year).map { "Or \(offer.format(cents: $0, short: true)) a year" }
            return .init(name: "Personal", size: size, sizeCaption: "of storage for you", price: "\(total) per \(period)",
                         detail: other ?? (interval == .year ? "Billed once a year" : "Billed every month"))
        case .team:
            return .init(name: "Team", size: size, sizeCaption: seats == 1 ? "1 seat, shared by the team" : "\(seats) seats, shared by the team",
                         price: "\(total) per \(period)",
                         detail: interval == .year ? "\(unit) per seat" + (saving.map { ", saves \($0) a year" } ?? "") : "\(unit) per seat")
        }
    }

    /// Team when it can't be chosen here: the per-seat terms, not a made-up team size.
    static func perSeat(interval: ParaAirCloudBilling.Interval, offer: ParaAirCloudBillingOffer) -> CloudPlanOffer? {
        guard let unitCents = offer.unitAmountCents(.team, interval) else { return nil }
        let unit = offer.format(cents: unitCents, short: true)
        let other = interval == .year
            ? offer.yearlySavingsCents(.team).map { "Saves \(offer.format(cents: $0, short: true)) per seat a year" }
            : offer.unitAmountCents(.team, .year).map { "Or \(offer.format(cents: $0, short: true)) per seat a year" }
        return .init(name: "Team", size: CloudUsagePresentation.format(ParaAirCloudBillingCatalog.terabyte), sizeCaption: "per seat, shared by the team",
                     price: "\(unit) per seat per \(interval == .year ? "year" : "month")", detail: other ?? "One seat for each member")
    }

    /// A plan the offer has no price for in this period, but has in the other: the size, and that it is not sold this way.
    static func unpriced(_ plan: ParaAirCloudBilling.Plan, interval: ParaAirCloudBilling.Interval) -> CloudPlanOffer {
        .init(name: plan == .team ? "Team" : "Personal", size: CloudUsagePresentation.format(ParaAirCloudBillingCatalog.terabyte),
              sizeCaption: plan == .team ? "per seat, shared by the team" : "of storage for you",
              price: "Not sold \(interval == .year ? "yearly" : "monthly")", detail: "Try the other billing period")
    }

    /// A plan the offer sells in neither period (Team through Stripe Managed Payments): not available yet, never "try
    /// the other billing period" (review 2026-11-26).
    static func notSold(_ plan: ParaAirCloudBilling.Plan) -> CloudPlanOffer {
        .init(name: plan == .team ? "Team" : "Personal", size: CloudUsagePresentation.format(ParaAirCloudBillingCatalog.terabyte),
              sizeCaption: plan == .team ? "per seat, shared by the team" : "of storage for you", price: "Not available yet",
              detail: plan == .team ? "A Personal plan doesn’t cover a team" : "Not sold monthly or yearly")
    }

    /// The card the plan sheet shows: the selection's price when the plan can be chosen; Team's per-seat terms when it
    /// can't be chosen here but is sold; otherwise why it can't be bought this period or at all.
    static func card(_ plan: ParaAirCloudBilling.Plan, interval: ParaAirCloudBilling.Interval, seats: Int, available: Bool,
                     offer: ParaAirCloudBillingOffer) -> CloudPlanOffer {
        let priced = plan == .team && !available ? perSeat(interval: interval, offer: offer)
            : make(plan, interval: interval, seats: plan == .team ? seats : 1, offer: offer)
        return priced ?? (offer.sells(plan) ? unpriced(plan, interval: interval) : notSold(plan))
    }
}
