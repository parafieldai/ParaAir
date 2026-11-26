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

/// Where people get help: an email to Parafield support with the version and build filled in. The diagnostics to paste
/// into it come from Copy Diagnostics (Support.swift). One place, beside the legal pages, so every Get Help… writes the
/// same email.
enum SupportLinks {
    static let email = "support@parafield.ai"
    /// Where Copy Diagnostics is, for the email's last line.
    static let diagnosticsHint = "To include diagnostics, choose Copy Diagnostics in ParaAir (About ParaAir, or Advanced in the ParaAir window) and paste them here."

    /// `mailto:` with the subject and body filled in. Lines end in CRLF and everything outside RFC 3986's unreserved
    /// characters is percent-encoded (RFC 6068), so `&`, `=` and `?` in the version can't end a field early.
    static func helpEmail(version: AppVersionText, system: String) -> URL {
        let subject = "ParaAir help (\(version.line))"
        let body = ["What happened, and what did you expect?", "", "",
                    "ParaAir \(version.title)" + (version.build.map { ", build \($0)" } ?? ""), "macOS: \(system)", diagnosticsHint]
            .joined(separator: "\r\n")
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func encoded(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }
        return URL(string: "mailto:\(email)?subject=\(encoded(subject))&body=\(encoded(body))")!
    }
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
