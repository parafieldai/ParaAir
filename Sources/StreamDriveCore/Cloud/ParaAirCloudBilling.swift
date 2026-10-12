import Foundation
import Darwin

/// `billing` of a workspace in `GET /v1/me` (contract README "Billing"). A service without billing omits it, and a
/// malformed object decodes as nil (`ParaAirCloudMe.Workspace`), so the app then offers neither checkout nor the
/// portal: billing UI fails closed while plan and usage keep working.
public struct ParaAirCloudBilling: Codable, Equatable, Sendable {
    public enum Provider: String, Codable, Sendable { case none, stripe, paddle }
    public enum Status: String, Codable, Sendable {
        case none, active, pastDue = "past_due", readOnly = "read_only", pendingDeletion = "pending_deletion", deleting, deleted
    }
    public enum Plan: String, Codable, Sendable, CaseIterable { case personal, team }
    public enum Interval: String, Codable, Sendable, CaseIterable { case month, year }

    public var provider: Provider
    public var status: Status
    public var plan: Plan?
    public var interval: Interval?
    /// Seats billed from the next renewal (1 for Personal); `plan.seats` is the seats usable now.
    public var seats: Int?
    public var extraStorageTb: Int
    public var currentPeriodEnd: Date?
    public var cancelAtPeriodEnd: Bool
    public var graceEndsAt: Date?
    /// The scheduled cancellation, the end of the grace period, or the start of the read-only period.
    public var readOnlyAt: Date?
    /// 30 days after `readOnlyAt`, when known.
    public var deletionAt: Date?
    public var checkoutAvailable: Bool
    public var portalAvailable: Bool

    public init(provider: Provider, status: Status, plan: Plan? = nil, interval: Interval? = nil, seats: Int? = nil,
                extraStorageTb: Int = 0, currentPeriodEnd: Date? = nil, cancelAtPeriodEnd: Bool = false, graceEndsAt: Date? = nil,
                readOnlyAt: Date? = nil, deletionAt: Date? = nil, checkoutAvailable: Bool = false, portalAvailable: Bool = false) {
        self.provider = provider; self.status = status; self.plan = plan; self.interval = interval; self.seats = seats
        self.extraStorageTb = extraStorageTb; self.currentPeriodEnd = currentPeriodEnd; self.cancelAtPeriodEnd = cancelAtPeriodEnd
        self.graceEndsAt = graceEndsAt; self.readOnlyAt = readOnlyAt; self.deletionAt = deletionAt
        self.checkoutAvailable = checkoutAvailable; self.portalAvailable = portalAvailable
    }

    enum CodingKeys: String, CodingKey {
        case provider, status, plan, interval, seats, extraStorageTb, currentPeriodEnd, cancelAtPeriodEnd, graceEndsAt, readOnlyAt,
             deletionAt, checkoutAvailable, portalAvailable
    }

    /// Unknown values and shapes the contract rules out are errors; the workspace then has no billing object.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decode(Provider.self, forKey: .provider); status = try c.decode(Status.self, forKey: .status)
        plan = try c.decodeIfPresent(Plan.self, forKey: .plan); interval = try c.decodeIfPresent(Interval.self, forKey: .interval)
        seats = try c.decodeIfPresent(Int.self, forKey: .seats); extraStorageTb = try c.decode(Int.self, forKey: .extraStorageTb)
        currentPeriodEnd = try c.decodeIfPresent(Date.self, forKey: .currentPeriodEnd)
        cancelAtPeriodEnd = try c.decode(Bool.self, forKey: .cancelAtPeriodEnd)
        graceEndsAt = try c.decodeIfPresent(Date.self, forKey: .graceEndsAt)
        readOnlyAt = try c.decodeIfPresent(Date.self, forKey: .readOnlyAt); deletionAt = try c.decodeIfPresent(Date.self, forKey: .deletionAt)
        checkoutAvailable = try c.decode(Bool.self, forKey: .checkoutAvailable)
        portalAvailable = try c.decode(Bool.self, forKey: .portalAvailable)
        let paid = status != .none
        guard seats.map({ (1...ParaAirCloudBillingCatalog.maxSeats).contains($0) }) ?? true,
              (0...ParaAirCloudBillingCatalog.maxStorageTb).contains(extraStorageTb),
              provider != .none || (!checkoutAvailable && !portalAvailable),
              paid ? plan != nil && interval != nil : plan == nil && interval == nil else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid billing object"))
        }
    }

    /// A subscription that blocks a new checkout (the service answers 409 `busy`): use the portal instead.
    public var isLive: Bool { status == .active || status == .pastDue || status == .deleting }
}

/// The service's plan catalog, mirrored for display. `cloud/src/billing/catalog.ts` is the source of truth (PRICING.md
/// "Proposed prices", subscription policy 4.1); checkout sends only a plan, an interval and quantities, so what is
/// charged always comes from the service. `ParaAirCloudBillingTests` compares this copy with catalog.ts when the
/// service source sits beside the package.
public enum ParaAirCloudBillingCatalog {
    public static let maxSeats = 1000
    public static let maxStorageTb = 100
    /// A plan seat and a storage block are each one decimal terabyte (policy 4.3).
    public static let terabyte: Int64 = 1_000_000_000_000
    /// Full-speed transfer each month per terabyte of plan storage (policy 4.4).
    public static let transferMultiple = 3

    /// US cents per unit per interval, before tax, keyed by the service's catalog ids.
    static let unitAmounts: [String: Int] = [
        "personal_month": 1_000, "personal_year": 10_000, "team_month": 1_600, "team_year": 16_000,
        "storage_month": 1_000, "storage_year": 12_000,
    ]

    public static func unitAmountCents(_ plan: ParaAirCloudBilling.Plan, _ interval: ParaAirCloudBilling.Interval) -> Int {
        unitAmounts["\(plan.rawValue)_\(interval.rawValue)"]!
    }
    public static func storageUnitAmountCents(_ interval: ParaAirCloudBilling.Interval) -> Int {
        unitAmounts["storage_\(interval.rawValue)"]!
    }
    /// catalog.ts `catalogAmount`: Team is per seat, Personal is one unit; storage is per block.
    public static func amountCents(plan: ParaAirCloudBilling.Plan, interval: ParaAirCloudBilling.Interval, seats: Int, storageTb: Int) -> Int {
        unitAmountCents(plan, interval) * (plan == .team ? seats : 1) + storageUnitAmountCents(interval) * storageTb
    }
    /// What paying yearly saves against twelve monthly payments, per unit (the discount covers the plan, not storage).
    public static func yearlySavingsCents(_ plan: ParaAirCloudBilling.Plan) -> Int {
        unitAmountCents(plan, .month) * 12 - unitAmountCents(plan, .year)
    }
    /// The service's `formatUsd`: "$1,600.00".
    public static func formatUSD(cents: Int) -> String {
        let dollars = String(cents / 100).reversed().enumerated()
            .map { $0.offset > 0 && $0.offset % 3 == 0 ? ",\($0.element)" : String($0.element) }.joined()
        return "$" + String(dollars.reversed()) + "." + String(format: "%02d", cents % 100)
    }
    /// Whole dollars drop the cents ("$10", "$1,600"), for compact price lines.
    public static func formatShortUSD(cents: Int) -> String {
        let full = formatUSD(cents: cents)
        return cents % 100 == 0 ? String(full.dropLast(3)) : full
    }
}

/// The two places ParaAir sends a browser for billing: a checkout and the processor's customer portal. A URL the
/// service returns is opened only on the issuer's own payment link page or a processor host documented for that
/// purpose; anything else is refused, so a compromised or confused reply cannot send the user to another site.
public enum ParaAirCloudBillingLink {
    public enum Kind: Sendable { case checkout, portal }

    /// Stripe Checkout Session `url` (https://docs.stripe.com/api/checkout/sessions/object); Paddle hosted checkouts
    /// on "pay.paddle.io or sandbox.pay.paddle.io" (https://developer.paddle.com/build/checkout/custom-subdomains).
    static let checkoutHosts: Set<String> = ["checkout.stripe.com", "pay.paddle.io", "sandbox.pay.paddle.io"]
    /// Stripe Customer Portal session `url` (https://docs.stripe.com/api/customer_portal/sessions); Paddle portal
    /// session links on customer-portal.paddle.com or sandbox-customer-portal.paddle.com
    /// (https://developer.paddle.com/api-reference/customer-portals/create-customer-portal-session,
    /// https://developer.paddle.com/changelog/2025/subscription-management-links-customer-portal).
    static let portalHosts: Set<String> = ["billing.stripe.com", "customer-portal.paddle.com", "sandbox-customer-portal.paddle.com"]
    /// Paddle's payment link page on the issuer (`<issuer>/billing/pay?_ptxn=txn_…`, contract README).
    static let issuerCheckoutPath = "/billing/pay"
    static let maxLength = 8192

    /// Returns the URL to open, or throws EPROTO. `issuer` is the account's validated service address.
    public static func validate(_ value: String, kind: Kind, issuer: URL) throws -> URL {
        let refused = DriveError(EPROTO, "ParaAir Cloud returned a payment page this app won’t open", disposition: .ambiguous)
        // Printable ASCII only: no spaces, controls or unencoded non-ASCII host spellings.
        guard !value.isEmpty, value.utf8.count <= maxLength, value.utf8.allSatisfy({ (0x21...0x7e).contains($0) }),
              let url = URL(string: value), let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.user == nil, c.password == nil, let scheme = c.scheme?.lowercased(), let encodedHost = c.percentEncodedHost,
              !encodedHost.isEmpty, !encodedHost.contains("%") else { throw refused }
        let host = encodedHost.lowercased()
        if scheme == "https", c.port == nil || c.port == 443, (kind == .checkout ? checkoutHosts : portalHosts).contains(host) {
            return url
        }
        guard kind == .checkout, let issuerParts = URLComponents(url: issuer, resolvingAgainstBaseURL: false),
              let issuerScheme = issuerParts.scheme?.lowercased(), let issuerHost = issuerParts.percentEncodedHost?.lowercased(),
              scheme == issuerScheme, host == issuerHost, effectivePort(c.port, scheme) == effectivePort(issuerParts.port, issuerScheme),
              c.percentEncodedPath == issuerCheckoutPath else { throw refused }
        return url
    }

    private static func effectivePort(_ port: Int?, _ scheme: String) -> Int? { port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : nil) }
}

/// `POST /v1/billing/checkout`. Amounts never leave the client: the service prices the plan from its catalog.
public struct ParaAirCloudCheckoutRequest: Equatable, Sendable {
    public var workspaceID: String
    public var plan: ParaAirCloudBilling.Plan
    public var interval: ParaAirCloudBilling.Interval
    /// Team seats, 1 to 1000 and at least the team's member count. Personal is always 1.
    public var seats: Int
    public var extraStorageTb: Int

    public init(workspaceID: String, plan: ParaAirCloudBilling.Plan, interval: ParaAirCloudBilling.Interval, seats: Int = 1, extraStorageTb: Int = 0) {
        self.workspaceID = workspaceID; self.plan = plan; self.interval = interval; self.seats = seats; self.extraStorageTb = extraStorageTb
    }

    var isValid: Bool {
        ParaAirCloudIDs.isWorkspaceID(workspaceID) && (0...ParaAirCloudBillingCatalog.maxStorageTb).contains(extraStorageTb)
            && (plan == .team ? (1...ParaAirCloudBillingCatalog.maxSeats).contains(seats) : seats == 1)
    }

    /// Personal sends no seat count (the service accepts only 1 or none).
    func body() throws -> Data {
        struct Body: Encodable { var workspaceId: String; var plan: String; var interval: String; var seats: Int?; var extraStorageTb: Int }
        return try ParaAirCloudJSON.encoder().encode(Body(workspaceId: workspaceID, plan: plan.rawValue, interval: interval.rawValue,
                                                          seats: plan == .team ? seats : nil, extraStorageTb: extraStorageTb))
    }
}

/// The checkout disclosure box (subscription policy Appendix A1 to A4) and its two consent sentences, which the app
/// shows above two unticked boxes before any checkout opens (policy 7.1, Appendix E1).
///
/// DRAFT TEXT PENDING COUNSEL. It follows the service's `cloud/src/billing/disclosure.ts` (refund Option A; "Paddle,
/// our reseller, charges" for Paddle and "we charge" for Stripe; the added-storage sentence is engineering wording)
/// with one app change: the cancel bullet names this app's real path (Storage Settings > ParaAir Cloud > Manage Plan)
/// instead of the draft's "Settings > Account > Subscription or at {account_url}", because the app has neither the
/// draft's settings path nor the service's account link. Change the wording only together with the draft and bump
/// `version`.
public struct ParaAirCloudCheckoutDisclosure: Equatable, Sendable {
    public static let version = "A-app-draft-2026-10-12"

    public var heading: String
    public var priceLine: String
    public var bullets: [String]
    public var renewalConsent: String
    public var documentsConsent: String

    private static let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
                                 "November", "December"]

    public static func make(plan: ParaAirCloudBilling.Plan, interval: ParaAirCloudBilling.Interval, seats: Int, storageTb: Int,
                            now: Date, seller: ParaAirCloudBilling.Provider) -> ParaAirCloudCheckoutDisclosure {
        let team = plan == .team, yearly = interval == .year
        let unit = ParaAirCloudBillingCatalog.formatUSD(cents: ParaAirCloudBillingCatalog.unitAmountCents(plan, interval))
        let total = ParaAirCloudBillingCatalog.formatUSD(cents: ParaAirCloudBillingCatalog.amountCents(plan: plan, interval: interval,
                                                                                                       seats: seats, storageTb: storageTb))
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = calendar.component(.day, from: now), month = months[calendar.component(.month, from: now) - 1]
        let when = yearly ? "every year on \(month) \(day)" : "on the \(ordinal(day)) of every month"
        let period = yearly ? "year" : "month"
        let charger = seller == .paddle ? "Paddle, our reseller, charges" : "we charge"
        let name = team ? "Team" : "Personal"
        var bullets: [String] = []
        if team { bullets.append("You are buying \(seats) member seats\(storageTb > 0 ? " and added storage" : ""): \(total) per \(period) plus tax.") }
        bullets.append("Today you pay \(total) plus any tax, which is shown before you pay.")
        if storageTb > 0 {
            let block = ParaAirCloudBillingCatalog.formatUSD(cents: ParaAirCloudBillingCatalog.storageUnitAmountCents(interval))
            bullets.append("This includes \(storageTb) TB of added storage at \(block) per TB per \(period) plus tax.")
        }
        bullets.append(team
            ? "Then \(charger) for the current number of members, at \(unit) per member plus tax\(storageTb > 0 ? ", plus added storage" : ""), \(when)."
            : "Then \(charger) \(total) plus tax \(when).")
        if team {
            bullets.append("Your \(yearly ? "yearly" : "monthly") charge changes when you add or remove members. Adding a member charges a prorated amount "
                + "\(yearly ? "for the rest of the year " : "")right away. Removing a member lowers the charge from your next \(yearly ? "yearly " : "")renewal; "
                + "the seat stays paid until then.")
            bullets.append("Includes 1 TB of storage per member, shared by the team, and up to 3 TB of full-speed transfer per member each month, shared. "
                + "No overage charges.")
        } else {
            bullets.append(storageTb > 0
                ? "Includes \(1 + storageTb) TB of storage and up to \(3 * (1 + storageTb)) TB of full-speed transfer each month. No overage charges."
                : "Includes 1 TB of storage and up to 3 TB of full-speed transfer each month. No overage charges.")
        }
        if yearly {
            bullets.append(team ? "We will email the owner and billing admins 25 to 30 days before each yearly renewal."
                           : "We will email you 25 to 30 days before each yearly renewal.")
        }
        let appPath = "in the ParaAir app (Storage Settings > ParaAir Cloud > Manage Plan)"
        bullets.append(team
            ? "The owner, or an admin with billing access, can cancel any time online \(appPath). Cancel before your renewal date to avoid the next charge."
            : "Cancel any time online \(appPath). Cancel before your renewal date to avoid the next charge. "
                + "You keep access until the end of the \(period) you paid for.")
        bullets.append("Full refund if you ask within 14 days of this first payment\(yearly ? " or within 14 days of any yearly renewal charge" : "").")
        bullets.append("We will email you at least 14 days before any price change, and you can cancel first.")
        let renewal = team
            ? "I agree that this ParaAir Cloud Team plan renews automatically at \(unit) per member per \(period) plus tax, for the number of members at each renewal, until I cancel."
            : "I agree that my ParaAir Cloud Personal plan renews automatically at \(total) per \(period) plus tax until I cancel."
        let documents = "I agree to the Terms of Service and the Subscription, Cancellation and Refund Policy\(team ? ", and I am authorized to agree for this team" : "")."
        return ParaAirCloudCheckoutDisclosure(
            heading: "ParaAir Cloud \(name), billed \(yearly ? "yearly" : "monthly")",
            priceLine: "\(unit) \(team ? "per member " : "")per \(period) plus tax. Renews automatically every \(period) until you cancel.",
            bullets: bullets, renewalConsent: renewal, documentsConsent: documents)
    }

    static func ordinal(_ day: Int) -> String {
        let tens = day % 100, ones = day % 10
        let suffix = (11...13).contains(tens) ? "th" : ones == 1 ? "st" : ones == 2 ? "nd" : ones == 3 ? "rd" : "th"
        return "\(day)\(suffix)"
    }
}
