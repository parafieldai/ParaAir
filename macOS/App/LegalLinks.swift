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

    /// The About panel's credits: the pages as links, one line, centred.
    static func aboutCredits() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                                                   .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph]
        let credits = NSMutableAttributedString()
        for (index, page) in about.enumerated() {
            if index > 0 { credits.append(NSAttributedString(string: "   ", attributes: base)) }
            var attributes = base
            attributes[.link] = page.url
            credits.append(NSAttributedString(string: page.title, attributes: attributes))
        }
        return credits
    }
}

/// A quiet line of legal links, as on the website's footer.
struct LegalLinksRow: View {
    let pages: [LegalLinks.Page]

    var body: some View {
        HStack(spacing: 16) {
            ForEach(pages) { GlideLink($0.title, destination: $0.url) }
        }
        .font(.caption)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Legal")
    }
}
