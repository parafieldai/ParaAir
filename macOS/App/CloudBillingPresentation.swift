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

    static let choosePlan = Control(action: .choosePlan, title: "Choose a Plan…")
    static let managePlan = Control(action: .managePlan, title: "Manage Plan…")
    static let previousPlan = "Previous plan"

    /// `planChoiceAvailable`: some workspace of the account offers checkout, so the plan sheet has something to sell.
    static func make(_ workspace: ParaAirCloudMe.Workspace?, state: CloudSummaryState, planChoiceAvailable: Bool) -> CloudBillingPresentation {
        guard state != .failed, let workspace else { return .init() }
        guard let billing = workspace.billing else {
            // A service from before billing may still link a plan page.
            return .init(controls: workspace.plan?.manageUrl == nil ? [] : [managePlan])
        }
        let owner = workspace.role == "owner"
        let checkout = billing.checkoutAvailable, portal = billing.portalAvailable
        var result = CloudBillingPresentation(summary: summary(billing))
        func day(_ date: Date?) -> String? { date.map(format) }
        switch billing.status {
        case .none:
            result.summary = nil
            if planChoiceAvailable { result.controls = [choosePlan] }
        case .active where billing.cancelAtPeriodEnd:
            let end = day(billing.readOnlyAt ?? billing.currentPeriodEnd)
            result.date = end.map { Row(label: "Ends", value: $0) }
            let after = day(billing.deletionAt).map { "Files then stay read-only until \($0) and are deleted after that." }
                ?? "Files then stay read-only for 30 days and are deleted after that."
            let ends = end.map { " and ends on \($0)" } ?? ""
            result.notice = .init(id: "billing", text: owner
                ? "Your plan is cancelled\(ends). \(after) To keep it, resume the plan in Manage Plan."
                : "This workspace’s plan is cancelled\(ends). \(after)", tone: .attention)
            if portal { result.controls = [managePlan] }
        case .active:
            result.date = day(billing.currentPeriodEnd).map { Row(label: "Renews", value: $0) }
            if portal { result.controls = [managePlan] }
        case .pastDue:
            let grace = day(billing.graceEndsAt)
            result.date = grace.map { Row(label: "Grace period ends", value: $0) }
            let until = grace.map { "Everything keeps working until \($0)." } ?? "Everything keeps working for now."
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
            result.notice = .init(id: "billing", text: owner
                ? "Your plan ended, so this workspace is read-only\(until). Choose a plan\(by), or the files are deleted."
                : "This workspace’s plan ended, so it’s read-only\(until). Ask the workspace owner to choose a plan\(by), or the files are deleted.",
                tone: .problem)
            result.controls = (checkout ? [Control(action: .choosePlan, title: "Choose a Plan…", prominent: true)] : []) + (portal ? [managePlan] : [])
        case .pendingDeletion:
            // Deletion waits for the service's purge, so the date is when it became possible, not a promise.
            result.summaryLabel = previousPlan
            let deletion = day(billing.deletionAt)
            result.date = deletion.map { Row(label: "Deletion scheduled", value: $0) }
            let ended = deletion.map { "The read-only period ended on \($0), so" } ?? "The read-only period ended, so"
            result.notice = .init(id: "billing", text: owner
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

    static func summary(_ billing: ParaAirCloudBilling) -> String? {
        guard let plan = billing.plan, let interval = billing.interval else { return nil }
        var parts = [plan == .team ? "Team" : "Personal"]
        if plan == .team, let seats = billing.seats { parts.append(seats == 1 ? "1 seat" : "\(seats) seats") }
        parts.append(interval == .year ? "billed yearly" : "billed monthly")
        if billing.extraStorageTb > 0 { parts.append("\(billing.extraStorageTb) TB added storage") }
        return parts.joined(separator: ", ")
    }

    static func format(_ date: Date) -> String {
        var style = Date.FormatStyle.dateTime.month(.wide).day().year()
        style.timeZone = TimeZone(identifier: "UTC") ?? .current
        return date.formatted(style)
    }
}

/// What the plan sheet can sell: Personal for the account's personal workspace, Team for a team workspace the user
/// owns. The service requires the plan to match the workspace's kind, so each option carries its workspaces.
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

    static func make(_ me: ParaAirCloudMe?, preferredWorkspaceID: String?) -> CloudPlanChoice {
        let all = me?.workspaces ?? []
        func option(_ plan: ParaAirCloudBilling.Plan) -> Option {
            let kind = all.filter { $0.kind == plan.rawValue }
            let open = kind.filter { $0.billing?.checkoutAvailable == true }
                .sorted { ($0.id == preferredWorkspaceID ? 0 : 1) < ($1.id == preferredWorkspaceID ? 0 : 1) }
            guard open.isEmpty else { return Option(plan: plan, workspaces: open) }
            let reason: String
            if kind.isEmpty {
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

    /// Team seats start at the seats the workspace has now (the service also requires one per member).
    static func defaultSeats(_ workspace: ParaAirCloudMe.Workspace?) -> Int {
        min(ParaAirCloudBillingCatalog.maxSeats, max(1, workspace?.plan?.seats ?? 1))
    }
}

/// Plan card figures. The plan size leads, the total price supports it, the per-unit price and the yearly saving
/// support that.
struct CloudPlanOffer: Equatable {
    var name: String
    var size: String
    var sizeCaption: String
    var price: String
    var detail: String

    static func make(_ plan: ParaAirCloudBilling.Plan, interval: ParaAirCloudBilling.Interval, seats: Int) -> CloudPlanOffer {
        let catalog = ParaAirCloudBillingCatalog.self
        let units = plan == .team ? seats : 1
        let period = interval == .year ? "year" : "month"
        let total = catalog.formatShortUSD(cents: catalog.amountCents(plan: plan, interval: interval, seats: units, storageTb: 0))
        let unit = catalog.formatShortUSD(cents: catalog.unitAmountCents(plan, interval))
        let saving = catalog.formatShortUSD(cents: catalog.yearlySavingsCents(plan) * units)
        let size = CloudUsagePresentation.format(catalog.terabyte * Int64(units))
        switch plan {
        case .personal:
            return .init(name: "Personal", size: size, sizeCaption: "of storage for you",
                         price: "\(total) per \(period)", detail: interval == .year ? "Saves \(saving) a year" : "Or \(catalog.formatShortUSD(cents: catalog.unitAmountCents(.personal, .year))) a year")
        case .team:
            return .init(name: "Team", size: size, sizeCaption: seats == 1 ? "shared by 1 member" : "shared by \(seats) members",
                         price: "\(total) per \(period)",
                         detail: interval == .year ? "\(unit) per member, saves \(saving) a year" : "\(unit) per member")
        }
    }

    /// Team when it can't be chosen here: the per-member terms, not a made-up team size.
    static func perMember(interval: ParaAirCloudBilling.Interval) -> CloudPlanOffer {
        let catalog = ParaAirCloudBillingCatalog.self
        let unit = catalog.formatShortUSD(cents: catalog.unitAmountCents(.team, interval))
        return .init(name: "Team", size: CloudUsagePresentation.format(catalog.terabyte), sizeCaption: "per member, shared by the team",
                     price: "\(unit) per member per \(interval == .year ? "year" : "month")",
                     detail: interval == .year ? "Saves \(catalog.formatShortUSD(cents: catalog.yearlySavingsCents(.team))) per member a year"
                         : "Or \(catalog.formatShortUSD(cents: catalog.unitAmountCents(.team, .year))) per member a year")
    }
}
