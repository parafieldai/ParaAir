import SwiftUI
import AppKit

/// ParaAir's legal pages on its site (paraair.parafield.ai; `/legal` lists them all). One place, so About, ParaAir Cloud
/// sign-in and the plan sheet link the same pages.
enum LegalLinks {
    struct Page: Equatable, Identifiable {
        let id: String
        let title: String
        var url: URL { site.appendingPathComponent(id) }
    }

    static let site = URL(string: "https://paraair.parafield.ai")!
    static let terms = Page(id: "terms", title: "Terms of Service")
    static let cloudTerms = Page(id: "cloud-terms", title: "ParaAir Cloud Terms")
    static let subscriptionPolicy = Page(id: "subscription-policy", title: "Subscription Policy")
    static let privacy = Page(id: "privacy", title: "Privacy Policy")
    static let index = Page(id: "legal", title: "All legal pages")

    /// Under ParaAir Cloud sign-in: what applies to an account.
    static let signIn = [cloudTerms, privacy]
    /// In the plan sheet: what applies to a paid plan.
    static let plans = [cloudTerms, subscriptionPolicy, privacy]
    /// In the About window.
    static let about = [terms, privacy, index]
}

/// A quiet line of legal links, as on the website's footer.
struct LegalLinksRow: View {
    let pages: [LegalLinks.Page]

    var body: some View {
        HStack(spacing: 16) {
            ForEach(pages) { AirLink($0.title, destination: $0.url) }
        }
        .font(.caption)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Legal")
    }
}
