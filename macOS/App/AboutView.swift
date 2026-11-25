import SwiftUI
import AppKit

/// About ParaAir: the mark over the airflow, the name and version as one two-tone headline, the build, and the legal
/// pages. It replaces the standard panel and shows the same facts.
struct AboutView: View {
    var version = AppVersionText.current

    /// The pages the window links, in order.
    static let pages = LegalLinks.about

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                AirflowField(height: 170, clearLeading: 0, clearTrailing: 0.08)
                ParaAirMark(badge: false)
                    .frame(width: 62, height: 62)
                    .padding(.bottom, 26)
            }
            VStack(spacing: 2) {
                Text("ParaAir").airDisplay(Air.Size.hero).foregroundStyle(Air.ink)
                Text(version.title).airDisplay(Air.Size.panel, weight: .regular).foregroundStyle(Air.quiet)
                    .multilineTextAlignment(.center)
                if let build = version.build {
                    Text("Build \(build)").font(.callout).monospacedDigit().foregroundStyle(Air.quiet)
                        .textSelection(.enabled)
                        .padding(.top, 8)
                }
            }
            .accessibilityElement(children: .combine)
            LegalLinksRow(pages: Self.pages)
                .padding(.top, 24)
        }
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
