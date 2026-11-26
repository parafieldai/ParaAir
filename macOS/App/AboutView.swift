import SwiftUI
import AppKit

/// About ParaAir: the planes in the sky above the name, the sage line under it, the version and build, and the legal
/// pages. It replaces the standard panel and shows the same facts.
struct AboutView: View {
    var version = AppVersionText.current

    /// The pages the window links, in order.
    static let pages = LegalLinks.about

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 150).airSky()
            VStack(spacing: 6) {
                Text("ParaAir").airDisplay(Air.Size.hero).foregroundStyle(Air.ink).airUnderlined()
                Text(version.title).font(.system(size: 15, weight: .medium)).foregroundStyle(Air.quiet)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
                if let build = version.build {
                    Text("Build \(build)").font(.callout).monospacedDigit().foregroundStyle(Air.quiet)
                        .textSelection(.enabled)
                }
            }
            .accessibilityElement(children: .combine)
            LegalLinksRow(pages: Self.pages)
                .padding(.top, 24)
        }
        .airFlight(.about, seed: "ParaAir")
        .padding(.bottom, 30)
        .frame(width: 360)
        .airSurface()
    }
}

/// The app menu's About item: opens the About window and brings ParaAir forward (it has no Dock icon).
struct AboutMenuButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About ParaAir") {
            openWindow(id: "about")
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
