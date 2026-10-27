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
    /// The free trial this workspace's next checkout starts with (added 2026-10-27); nil when none or checkout is unavailable.
    public var trialDays: Int?
    /// While the subscription is in its free trial (status `active`): when the trial ends and the first charge falls.
    public var trialEndsAt: Date?

    public init(provider: Provider, status: Status, plan: Plan? = nil, interval: Interval? = nil, seats: Int? = nil,
                extraStorageTb: Int = 0, currentPeriodEnd: Date? = nil, cancelAtPeriodEnd: Bool = false, graceEndsAt: Date? = nil,
                readOnlyAt: Date? = nil, deletionAt: Date? = nil, checkoutAvailable: Bool = false, portalAvailable: Bool = false,
                trialDays: Int? = nil, trialEndsAt: Date? = nil) {
        self.provider = provider; self.status = status; self.plan = plan; self.interval = interval; self.seats = seats
        self.extraStorageTb = extraStorageTb; self.currentPeriodEnd = currentPeriodEnd; self.cancelAtPeriodEnd = cancelAtPeriodEnd
        self.graceEndsAt = graceEndsAt; self.readOnlyAt = readOnlyAt; self.deletionAt = deletionAt
        self.checkoutAvailable = checkoutAvailable; self.portalAvailable = portalAvailable
        self.trialDays = trialDays; self.trialEndsAt = trialEndsAt
    }

    enum CodingKeys: String, CodingKey {
        case provider, status, plan, interval, seats, extraStorageTb, currentPeriodEnd, cancelAtPeriodEnd, graceEndsAt, readOnlyAt,
             deletionAt, checkoutAvailable, portalAvailable, trialDays, trialEndsAt
    }

    /// Longest free trial the app shows: anything longer is a malformed reply (the service offers at most 30 days).
    static let maxTrialDays = 365

    /// Unknown values and shapes the contract rules out are errors; the workspace then has no billing object. Counts
    /// are not capped here: the service raises Team seats past 1000 when members are added and takes storage blocks
    /// from the processor, and a paid status may come without a plan the price map knows. Those still decode, so the
    /// past-due notice and the portal stay reachable (review 2026-10-13); the presentation shows only what it knows.
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
        // A service from before free trials omits both.
        trialDays = try c.decodeIfPresent(Int.self, forKey: .trialDays)
        trialEndsAt = try c.decodeIfPresent(Date.self, forKey: .trialEndsAt)
        guard seats.map({ $0 >= 0 }) ?? true, extraStorageTb >= 0, trialDays.map({ (1...Self.maxTrialDays).contains($0) }) ?? true,
              provider != .none || (!checkoutAvailable && !portalAvailable),
              status != .none || (plan == nil && interval == nil) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid billing object"))
        }
    }

    /// A subscription that blocks a new checkout (the service answers 409 `busy`): use the portal instead.
    public var isLive: Bool { status == .active || status == .pastDue || status == .deleting }
    /// The subscription is in its free trial: nothing is charged before `trialEndsAt`.
    public var inTrial: Bool { status == .active && trialEndsAt != nil }
}

/// Limits and units the checkout request and the plan cards use. Prices are not here: they come from the service's
/// `GET /v1/billing/offer` (ParaAirCloudBillingOffer), so the app never shows an amount the service would not charge
/// (review 2026-10-13; subscription policy Appendix A fills the values "from the live price").
public enum ParaAirCloudBillingCatalog {
    /// `MAX_SEATS` and `MAX_STORAGE_TB` of the service's catalog: the bounds of a checkout request.
    public static let maxSeats = 1000
    public static let maxStorageTb = 100
    /// A plan seat and a storage block are each one decimal terabyte (policy 4.3).
    public static let terabyte: Int64 = 1_000_000_000_000
    /// Full-speed transfer each month per terabyte of plan storage (policy 4.4).
    public static let transferMultiple = 3

    /// The service's `formatUsd`: "$1,600.00".
    public static func formatUSD(cents: Int) -> String { "$" + grouped(cents) }
    /// Whole dollars drop the cents ("$10", "$1,600"), for compact price lines.
    public static func formatShortUSD(cents: Int) -> String {
        let full = formatUSD(cents: cents)
        return cents % 100 == 0 ? String(full.dropLast(3)) : full
    }
    /// "1,600.00" for 160000; negative amounts never reach here (the offer refuses them).
    static func grouped(_ cents: Int) -> String {
        let units = String(cents / 100).reversed().enumerated()
            .map { $0.offset > 0 && $0.offset % 3 == 0 ? ",\($0.element)" : String($0.element) }.joined()
        return String(units.reversed()) + "." + String(format: "%02d", cents % 100)
    }
}

/// `GET /v1/billing/offer` (contract README, added 2026-10-13): what the service sells and how. The plan sheet shows
/// only these values: the merchant of record (policy 2.2), the catalog prices, and for the chosen plan the disclosure
/// box and consent sentences (Appendix A) exactly as checkout records them under `disclosureVersion` (policy 7.4,
/// Appendix E2). When the service sends no price for a plan, the app offers no checkout for it.
public struct ParaAirCloudBillingOffer: Equatable, Sendable {
    public struct Merchant: Equatable, Sendable {
        public var name: String
        /// A reseller and seller of record, "our online reseller" (policy 2.2): Paddle, or Link with Stripe Managed Payments.
        /// False when Parafield Inc. charges itself.
        public var reseller: Bool
        public init(name: String, reseller: Bool) { self.name = name; self.reseller = reseller }
    }
    public struct Price: Equatable, Sendable {
        public enum Kind: String, Sendable { case plan, storage }
        public var item: String
        public var kind: Kind
        public var plan: ParaAirCloudBilling.Plan?
        public var interval: ParaAirCloudBilling.Interval
        /// Per unit per interval, before tax: per member for Team (`perMember`), per 1 TB block for storage.
        public var unitAmountCents: Int
        public var perMember: Bool
        public init(item: String, kind: Kind, plan: ParaAirCloudBilling.Plan?, interval: ParaAirCloudBilling.Interval, unitAmountCents: Int,
                    perMember: Bool) {
            self.item = item; self.kind = kind; self.plan = plan; self.interval = interval; self.unitAmountCents = unitAmountCents
            self.perMember = perMember
        }
    }
    /// The first charge before tax and the Appendix A text for one selection.
    public struct Quote: Equatable, Sendable {
        public var plan: ParaAirCloudBilling.Plan
        public var interval: ParaAirCloudBilling.Interval
        public var seats: Int
        public var extraStorageTb: Int
        public var amountCents: Int
        public var currency: String
        /// A heading, the price line, then bullets prefixed "- ".
        public var terms: [String]
        /// The consent sentences; links are Markdown `[label](url)`.
        public var consent: String
        /// The free trial before the first charge (added 2026-10-27); nil without one. Checkout sends it back.
        public var trialDays: Int?
        /// The short screen's lines before the processor's page (added 2026-10-27): price and renewal, how to cancel, the
        /// refund, and with a trial what a failed first payment does. Empty from a service before them.
        public var summary: [String] = []
        /// When the first charge falls: now without a trial, the trial's end with one. Nil from a service before trials.
        public var firstChargeAt: Date?
        public init(plan: ParaAirCloudBilling.Plan, interval: ParaAirCloudBilling.Interval, seats: Int, extraStorageTb: Int, amountCents: Int,
                    currency: String, terms: [String], consent: String, trialDays: Int? = nil, firstChargeAt: Date? = nil, summary: [String] = []) {
            self.plan = plan; self.interval = interval; self.seats = seats; self.extraStorageTb = extraStorageTb
            self.amountCents = amountCents; self.currency = currency; self.terms = terms; self.consent = consent
            self.trialDays = trialDays; self.firstChargeAt = firstChargeAt; self.summary = summary
        }
    }

    /// `stripe` or `paddle`.
    public var provider: ParaAirCloudBilling.Provider
    public var merchant: Merchant
    /// Sent back with checkout, so the consent record names the text that was shown.
    public var disclosureVersion: String
    /// ISO 4217; prices are before tax.
    public var currency: String
    public var prices: [Price]
    public var quote: Quote?

    public init(provider: ParaAirCloudBilling.Provider, merchant: Merchant, disclosureVersion: String, currency: String, prices: [Price],
                quote: Quote? = nil) {
        self.provider = provider; self.merchant = merchant; self.disclosureVersion = disclosureVersion; self.currency = currency
        self.prices = prices; self.quote = quote
    }

    /// One unit's price, at most this (US$1,000,000), so totals for 1000 seats and 100 TB cannot overflow.
    static let maxUnitAmountCents = 100_000_000
    static let maxTextLength = 2000

    public func unitAmountCents(_ plan: ParaAirCloudBilling.Plan, _ interval: ParaAirCloudBilling.Interval) -> Int? {
        prices.first { $0.kind == .plan && $0.plan == plan && $0.interval == interval }?.unitAmountCents
    }
    public func storageUnitAmountCents(_ interval: ParaAirCloudBilling.Interval) -> Int? {
        prices.first { $0.kind == .storage && $0.interval == interval }?.unitAmountCents
    }
    public func sells(_ plan: ParaAirCloudBilling.Plan) -> Bool { ParaAirCloudBilling.Interval.allCases.contains { unitAmountCents(plan, $0) != nil } }
    /// What the plan cards show before a quote: per member for Team, plus storage blocks.
    public func amountCents(plan: ParaAirCloudBilling.Plan, interval: ParaAirCloudBilling.Interval, seats: Int, storageTb: Int = 0) -> Int? {
        guard let unit = unitAmountCents(plan, interval), (1...ParaAirCloudBillingCatalog.maxSeats).contains(seats),
              (0...ParaAirCloudBillingCatalog.maxStorageTb).contains(storageTb) else { return nil }
        let perMember = prices.first { $0.kind == .plan && $0.plan == plan && $0.interval == interval }?.perMember ?? false
        guard storageTb == 0 else { return storageUnitAmountCents(interval).map { unit * (perMember ? seats : 1) + $0 * storageTb } }
        return unit * (perMember ? seats : 1)
    }
    /// What paying yearly saves against twelve monthly payments, per unit; nil unless both are sold and yearly is cheaper.
    public func yearlySavingsCents(_ plan: ParaAirCloudBilling.Plan) -> Int? {
        guard let month = unitAmountCents(plan, .month), let year = unitAmountCents(plan, .year), month * 12 > year else { return nil }
        return month * 12 - year
    }
    /// "$1,600.00", or "1,600.00 EUR" for another currency.
    public func format(cents: Int, short: Bool = false) -> String {
        guard currency == "USD" else {
            let text = ParaAirCloudBillingCatalog.grouped(cents)
            return (short && cents % 100 == 0 ? String(text.dropLast(3)) : text) + " " + currency
        }
        return short ? ParaAirCloudBillingCatalog.formatShortUSD(cents: cents) : ParaAirCloudBillingCatalog.formatUSD(cents: cents)
    }

    /// Printable text the plan sheet can show as is: no control characters, bounded length.
    static func isDisplayable(_ value: String, max: Int = maxTextLength) -> Bool {
        !value.isEmpty && value.count <= max && !value.unicodeScalars.contains { $0.properties.generalCategory == .control }
            && value.trimmingCharacters(in: .whitespaces) == value
    }
    /// The service's version rule: 1 to 64 printable ASCII characters.
    static func isVersion(_ value: String) -> Bool { (1...64).contains(value.utf8.count) && value.utf8.allSatisfy { (0x21...0x7e).contains($0) } }
}

extension ParaAirCloudBillingOffer: Decodable {
    private struct Wire: Decodable {
        struct Merchant: Decodable { var name: String; var reseller: Bool }
        struct Price: Decodable {
            var item: String; var kind: String; var plan: String?; var interval: String; var unitAmountCents: Int; var perMember: Bool
        }
        /// A price row this app does not understand is skipped rather than failing the whole offer.
        struct Lossy<T: Decodable>: Decodable { var value: T?; init(from decoder: Decoder) throws { value = try? T(from: decoder) } }
        struct Quote: Decodable {
            var plan: ParaAirCloudBilling.Plan; var interval: ParaAirCloudBilling.Interval; var seats: Int; var extraStorageTb: Int
            var amountCents: Int; var currency: String; var terms: [String]; var consent: String
            var trialDays: Int?; var firstChargeAt: Date?; var summary: [String]?
        }
        var provider: ParaAirCloudBilling.Provider
        var merchantOfRecord: Merchant
        var disclosureVersion: String
        var currency: String
        var prices: [Lossy<Price>]
        var quote: Quote?
    }

    public init(from decoder: Decoder) throws {
        let wire = try Wire(from: decoder)
        func corrupt(_ why: String) -> DecodingError { .dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: why)) }
        guard wire.provider != .none else { throw corrupt("Billing offer without a processor") }
        guard Self.isDisplayable(wire.merchantOfRecord.name, max: 200) else { throw corrupt("Invalid merchant of record") }
        guard Self.isVersion(wire.disclosureVersion) else { throw corrupt("Invalid disclosure version") }
        guard wire.currency.utf8.count == 3, wire.currency.utf8.allSatisfy({ (65...90).contains($0) }) else { throw corrupt("Invalid currency") }
        var prices: [Price] = []
        for row in wire.prices.compactMap(\.value) {
            guard let kind = Price.Kind(rawValue: row.kind), let interval = ParaAirCloudBilling.Interval(rawValue: row.interval),
                  (0...Self.maxUnitAmountCents).contains(row.unitAmountCents), !row.item.isEmpty, row.item.utf8.count <= 64 else { continue }
            let plan = row.plan.flatMap(ParaAirCloudBilling.Plan.init(rawValue:))
            guard kind == .plan ? plan != nil : row.plan == nil,
                  !prices.contains(where: { $0.kind == kind && $0.plan == plan && $0.interval == interval }) else { continue }
            prices.append(Price(item: row.item, kind: kind, plan: plan, interval: interval, unitAmountCents: row.unitAmountCents,
                                perMember: row.perMember))
        }
        var quote: Quote?
        if let q = wire.quote {
            guard (1...ParaAirCloudBillingCatalog.maxSeats).contains(q.seats), (0...ParaAirCloudBillingCatalog.maxStorageTb).contains(q.extraStorageTb),
                  q.plan == .team || q.seats == 1, q.amountCents >= 0, q.amountCents <= Self.maxUnitAmountCents * 1_100,
                  q.currency == wire.currency, (3...60).contains(q.terms.count), q.terms.allSatisfy({ Self.isDisplayable($0) }),
                  Self.isDisplayable(q.consent, max: 4000),
                  q.trialDays.map({ (1...ParaAirCloudBilling.maxTrialDays).contains($0) }) ?? true,
                  (q.summary ?? []).count <= 8, (q.summary ?? []).allSatisfy({ Self.isDisplayable($0) }) else { throw corrupt("Invalid quote") }
            quote = Quote(plan: q.plan, interval: q.interval, seats: q.seats, extraStorageTb: q.extraStorageTb, amountCents: q.amountCents,
                          currency: q.currency, terms: q.terms, consent: q.consent, trialDays: q.trialDays, firstChargeAt: q.firstChargeAt,
                          summary: q.summary ?? [])
        }
        self.init(provider: wire.provider, merchant: Merchant(name: wire.merchantOfRecord.name, reseller: wire.merchantOfRecord.reseller),
                  disclosureVersion: wire.disclosureVersion, currency: wire.currency, prices: prices, quote: quote)
    }
}

/// `GET /v1/billing/offer` with a quote: the selection the plan sheet is about to show terms for. The same rules as
/// checkout: Team only takes seats, storage is 0 to 100 blocks.
public struct ParaAirCloudOfferRequest: Equatable, Sendable {
    public var plan: ParaAirCloudBilling.Plan
    public var interval: ParaAirCloudBilling.Interval
    public var seats: Int
    public var extraStorageTb: Int
    /// The workspace the checkout is for: the quote then includes the free trial it starts with (added 2026-10-27).
    public var workspaceID: String?

    public init(plan: ParaAirCloudBilling.Plan, interval: ParaAirCloudBilling.Interval, seats: Int = 1, extraStorageTb: Int = 0,
                workspaceID: String? = nil) {
        self.plan = plan; self.interval = interval; self.seats = seats; self.extraStorageTb = extraStorageTb; self.workspaceID = workspaceID
    }

    var isValid: Bool {
        (0...ParaAirCloudBillingCatalog.maxStorageTb).contains(extraStorageTb)
            && (plan == .team ? (1...ParaAirCloudBillingCatalog.maxSeats).contains(seats) : seats == 1)
            && (workspaceID.map(ParaAirCloudIDs.isWorkspaceID) ?? true)
    }

    var query: [URLQueryItem] {
        var items = [URLQueryItem(name: "plan", value: plan.rawValue), URLQueryItem(name: "interval", value: interval.rawValue)]
        if plan == .team { items.append(URLQueryItem(name: "seats", value: String(seats))) }
        items.append(URLQueryItem(name: "extraStorageTb", value: String(extraStorageTb)))
        if let workspaceID { items.append(URLQueryItem(name: "workspaceId", value: workspaceID)) }
        return items
    }

    /// The quote answers exactly this selection.
    func matches(_ quote: ParaAirCloudBillingOffer.Quote) -> Bool {
        quote.plan == plan && quote.interval == interval && quote.seats == seats && quote.extraStorageTb == extraStorageTb
    }
}

/// The checkout screen's text from the service's quote (Appendix A; policy 6.1 and 7.1): the short summary it leads
/// with, the full box behind "Show full terms", and the consent sentences beside one unticked box (operator decision
/// 2026-10-27). The text is shown as the service sends it, so the consent record's `disclosureVersion` names what the
/// buyer read.
public struct ParaAirCloudCheckoutTerms: Equatable, Sendable {
    /// What the screen leads with; empty from a service before summaries, which shows the full box instead.
    public var summary: [String]
    public var heading: String
    public var priceLine: String
    public var bullets: [String]
    /// Both consent sentences, as the one box shows them. Links are Markdown `[label](url)`.
    public var consent: String
    /// The first box: automatic renewal at the stated price until cancelled (policy 7.1).
    public var renewalConsent: String
    /// The second box: the Terms and the policy. Links are Markdown `[label](url)`.
    public var documentsConsent: String

    /// Nil when the quote's text is not the shape the service sends; the plan sheet then offers no checkout.
    public init?(_ quote: ParaAirCloudBillingOffer.Quote) {
        guard quote.terms.count >= 3 else { return nil }
        var bullets: [String] = []
        for line in quote.terms.dropFirst(2) {
            guard line.hasPrefix("- "), line.count > 2 else { return nil }
            bullets.append(String(line.dropFirst(2)))
        }
        // The service joins the renewal sentence and the documents sentence with a space; each starts "I agree".
        guard quote.consent.hasPrefix("I agree"), let split = quote.consent.range(of: ". I agree") else { return nil }
        let renewal = String(quote.consent[..<split.lowerBound]) + "."
        let documents = String(quote.consent[quote.consent.index(after: split.lowerBound)...]).trimmingCharacters(in: .whitespaces)
        summary = quote.summary; heading = quote.terms[0]; priceLine = quote.terms[1]; self.bullets = bullets
        consent = quote.consent; renewalConsent = renewal; documentsConsent = documents
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

/// What the buyer agreed to before checkout opened: the disclosure version of the offer whose quote was shown, and
/// the two unticked boxes (policy 7.1; contract README `disclosureVersion` and `consent`).
public struct ParaAirCloudCheckoutConsent: Equatable, Sendable {
    public var disclosureVersion: String
    public var autoRenew: Bool
    public var terms: Bool

    public init(disclosureVersion: String, autoRenew: Bool, terms: Bool) {
        self.disclosureVersion = disclosureVersion; self.autoRenew = autoRenew; self.terms = terms
    }
}

/// `POST /v1/billing/checkout`. Amounts never leave the client: the service prices the plan from its catalog.
public struct ParaAirCloudCheckoutRequest: Equatable, Sendable {
    public var workspaceID: String
    public var plan: ParaAirCloudBilling.Plan
    public var interval: ParaAirCloudBilling.Interval
    /// Team seats, 1 to 1000 and at least the team's member count. Personal is always 1.
    public var seats: Int
    public var extraStorageTb: Int
    /// Nil only for callers that show no terms; the service refuses a checkout without consent (since 2026-10-23).
    public var consent: ParaAirCloudCheckoutConsent?
    /// The free trial the quote showed (0 for none); the service answers 409 `disclosure_outdated` when it differs.
    public var trialDays: Int

    public init(workspaceID: String, plan: ParaAirCloudBilling.Plan, interval: ParaAirCloudBilling.Interval, seats: Int = 1, extraStorageTb: Int = 0,
                consent: ParaAirCloudCheckoutConsent? = nil, trialDays: Int = 0) {
        self.workspaceID = workspaceID; self.plan = plan; self.interval = interval; self.seats = seats; self.extraStorageTb = extraStorageTb
        self.consent = consent; self.trialDays = trialDays
    }

    /// The selection a quote must answer before this checkout may open.
    public var selection: ParaAirCloudOfferRequest {
        ParaAirCloudOfferRequest(plan: plan, interval: interval, seats: plan == .team ? seats : 1, extraStorageTb: extraStorageTb,
                                 workspaceID: workspaceID)
    }

    /// Consent is both boxes ticked or nothing: the service refuses one without the other (400 `invalid_request`).
    var isValid: Bool {
        ParaAirCloudIDs.isWorkspaceID(workspaceID) && (0...ParaAirCloudBillingCatalog.maxStorageTb).contains(extraStorageTb)
            && (plan == .team ? (1...ParaAirCloudBillingCatalog.maxSeats).contains(seats) : seats == 1)
            && (consent.map { ParaAirCloudBillingOffer.isVersion($0.disclosureVersion) && $0.autoRenew && $0.terms } ?? true)
            && (0...ParaAirCloudBilling.maxTrialDays).contains(trialDays)
    }

    /// Personal sends no seat count (the service accepts only 1 or none); no trial sends no `trialDays`.
    func body() throws -> Data {
        struct Consent: Encodable { var autoRenew: Bool; var terms: Bool }
        struct Body: Encodable {
            var workspaceId: String; var plan: String; var interval: String; var seats: Int?; var extraStorageTb: Int
            var disclosureVersion: String?; var consent: Consent?; var trialDays: Int?
        }
        return try ParaAirCloudJSON.encoder().encode(Body(
            workspaceId: workspaceID, plan: plan.rawValue, interval: interval.rawValue, seats: plan == .team ? seats : nil,
            extraStorageTb: extraStorageTb, disclosureVersion: consent?.disclosureVersion,
            consent: consent.map { Consent(autoRenew: $0.autoRenew, terms: $0.terms) }, trialDays: trialDays > 0 ? trialDays : nil))
    }
}
