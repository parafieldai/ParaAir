import SwiftUI
import AppKit

// ParaAir's interface language, "Air", shared with the website: cool paper, ink type set tight, sections set as type on
// the paper between hairlines, flat capsule controls, one sage accent from the mark, and the ParaAir planes: a lead plane
// in ink and sage, the sage line it leaves under the name it flew beneath, and a small grey flock in the open paper
// beside a header. Motion uses two curves: a long ease-out (0.22, 1, 0.36, 1) for things that arrive or move, a short
// standard ease for hover and press. Under Reduce Motion nothing slides, scales, blurs or flies; hover and press keep
// their colour fades. docs/app-design.md describes the system; this file is its only source of values.

// MARK: - Tokens

enum Air {
    // Surfaces and ink. Light: cool paper #F7F8FA and ink #0E0F12. Dark: near-black #0C0D10 and #F6F7F9.
    static let paper = adaptive(dark: 0x0C0D10, light: 0xF7F8FA)
    static let ink = adaptive(dark: 0xF6F7F9, light: 0x0E0F12)
    /// Supporting text: 5.2:1 on light paper, 5.4:1 on the light sheet, 4.8:1 on the muted fill; 7.0:1, 6.6:1 and 6.2:1
    /// on their dark counterparts.
    static let quiet = adaptive(dark: 0x969CA8, light: 0x646974)
    /// Tracks, hover fills and pressed controls.
    static let muted = adaptive(dark: 0x1A1C20, light: 0xEEF0F3)
    /// Hairlines between rows.
    static let rule = adaptive(dark: 0x24272C, light: 0xE6E8EC)
    /// The empty part of a meter: visible on the paper and on sheets in both appearances.
    static let track = adaptive(dark: (0xF6F7F9, 0.16), light: (0x0E0F12, 0.11))
    /// The edge of a control that must be found by its outline (a field, a checkbox, a switch that is off): 3:1 or
    /// more against the paper and sheets.
    static let controlEdge = adaptive(dark: (0xF6F7F9, 0.42), light: (0x0E0F12, 0.46))

    /// A hairline that has to hold its own: the edge of a secondary button.
    static let ruleStrong = adaptive(dark: 0x3A3E46, light: 0xC9CDD4)

    // Panels that hold a choice (a plan, the full terms, the drive icon): a flat sheet a shade lighter than the paper,
    // edged by a hairline. No panel or button casts a shadow; only a switch's knob keeps a hairline one.
    static let sheet = adaptive(dark: 0x15161A, light: 0xFDFDFE)
    static let cardEdge = adaptive(dark: (0xFFFFFF, 0.08), light: (0x0F172A, 0.08))

    // The planes, as on the website: the flock is the mark in two greys, its fold a step nearer the paper, so a small
    // plane still reads as folded paper; the lead plane's trail is the mark's sage, a step darker on light paper.
    static let planeGrey = adaptive(dark: 0x5E646F, light: 0xA4A9B2)
    static let planeFold = adaptive(dark: 0x3A3F47, light: 0xD3D7DD)
    static let trail = adaptive(dark: 0x9AC7B4, light: 0x5E9C83)

    // Controls.
    static let thumb = adaptive(dark: 0x2E3137, light: 0xFFFFFF)
    static let controlShadow = adaptive(dark: (0x000000, 0.45), light: (0x0F172A, 0.12))
    /// The prominent button: ink on light paper, the light ink on dark paper, with the paper as its label (18:1).
    static let inkFill = ink
    static let inkLabel = paper
    static let fieldFill = adaptive(dark: (0xFFFFFF, 0.05), light: (0xFFFFFF, 1))

    /// The one colour beside ink: the mark's sage, for switches that are on and things that are well.
    /// White on it: 6.1:1 (light) and 4.0:1 (dark); against the paper 5.7:1 and 4.9:1.
    static let accent = adaptive(dark: 0x588974, light: 0x3F6B5A)
    /// The mark's green itself (BrandIconGeometry.palette[2]).
    static let markGreen = adaptive(dark: 0x9AC7B4, light: 0x9AC7B4)

    // Status tones, each at least 4.5:1 on the paper and on sheets.
    static let good = adaptive(dark: 0x9AC7B4, light: 0x3F6B5A)
    static let attention = adaptive(dark: 0xE2B46B, light: 0x8A5A12)
    static let problem = adaptive(dark: 0xEE8F7E, light: 0xA63A2A)
    /// A label on a problem fill: white (6.1:1) in light mode, ink (8:1) on the lighter dark-mode fill.
    static let onProblem = adaptive(dark: 0x0E0F12, light: 0xFFFFFF)

    // Spacing on a 4-point scale, and the corner radii.
    enum Space {
        static let xs: CGFloat = 4, sm: CGFloat = 8, md: CGFloat = 12, lg: CGFloat = 16, xl: CGFloat = 24, xxl: CGFloat = 32
        /// The window's margin and the gap between sections.
        static let page: CGFloat = 28, section: CGFloat = 26
    }
    enum Radius {
        static let sheet: CGFloat = 22, inset: CGFloat = 12, field: CGFloat = 9
    }

    // Type: San Francisco at two weights, display sizes tracked in by 3% as on the website.
    enum Size {
        static let hero: CGFloat = 30, title: CGFloat = 24, panel: CGFloat = 19, heading: CGFloat = 15, figure: CGFloat = 34
    }

    // MARK: Colour helpers

    private static func ns(_ rgb: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                blue: CGFloat(rgb & 255) / 255, alpha: alpha)
    }

    private static func dynamic(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    static func adaptive(dark: UInt32, light: UInt32) -> Color { dynamic(dark: ns(dark), light: ns(light)) }
    static func adaptive(dark: (UInt32, CGFloat), light: (UInt32, CGFloat)) -> Color {
        dynamic(dark: ns(dark.0, dark.1), light: ns(light.0, light.1))
    }

    /// Fine grain for the paper: mid-grey specks with varied alpha, drawn once. 160 pixels square, shown at 80 points.
    static let grain: NSImage = {
        let side = 160
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        var seed: UInt64 = 0x5DEECE66D
        for index in stride(from: 0, to: pixels.count, by: 4) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let alpha = UInt8(truncatingIfNeeded: (seed >> 33) % 230)
            let grey = UInt8(Int(alpha) / 2)
            pixels[index] = grey; pixels[index + 1] = grey; pixels[index + 2] = grey; pixels[index + 3] = alpha
        }
        let image = pixels.withUnsafeMutableBytes { bytes -> CGImage? in
            CGContext(data: bytes.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
        guard let image else { return NSImage(size: NSSize(width: 80, height: 80)) }
        return NSImage(cgImage: image, size: NSSize(width: 80, height: 80))
    }()
}

// MARK: - Motion

enum AirMotion {
    /// Arrivals, morphs, a thumb sliding to its place: the website's 0.7 s ease-out.
    static let reveal = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.7)
    /// The same curve, shorter, for small things that move a few points.
    static let settle = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.4)
    /// Hover and colour changes.
    static let hover = Animation.timingCurve(0.4, 0, 0.2, 1, duration: 0.2)
    /// Press feedback.
    static let quick = Animation.timingCurve(0.4, 0, 0.2, 1, duration: 0.15)
}

/// The ambient motion (the lead plane's entrance and the working shimmer). The snapshot harness turns it off so captures
/// show a still frame; Reduce Motion turns it off for people.
private struct AirAmbientMotionKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var airAmbientMotion: Bool {
        get { self[AirAmbientMotionKey.self] }
        set { self[AirAmbientMotionKey.self] = newValue }
    }
}

/// Blur and fade together, as the website brings words in.
private struct BlurFade: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View { content.blur(radius: active ? 4 : 0).opacity(active ? 0 : 1) }
}

enum AirTransition {
    /// A row or notice arriving: up 6 points from 96%, fading in.
    case item
    /// Words replacing words: out of a 4-point blur.
    case words

    fileprivate var transition: AnyTransition {
        switch self {
        case .item: return .opacity.combined(with: .scale(scale: 0.96)).combined(with: .offset(y: 6))
        case .words: return .modifier(active: BlurFade(active: true), identity: BlurFade(active: false))
        }
    }
}

private struct AirTransitionModifier: ViewModifier {
    let kind: AirTransition
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View { content.transition(reduceMotion ? .opacity : kind.transition) }
}

private struct AirAnimationModifier<Value: Equatable>: ViewModifier {
    let animation: Animation
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View { content.animation(reduceMotion ? nil : animation, value: value) }
}

extension View {
    /// How this view enters and leaves; under Reduce Motion it only fades, never moves, scales or blurs.
    func airTransition(_ kind: AirTransition) -> some View { modifier(AirTransitionModifier(kind: kind)) }
    /// Animates changes to `value` on `animation`; under Reduce Motion the change is immediate.
    func airAnimation<Value: Equatable>(_ animation: Animation = AirMotion.reveal, value: Value) -> some View {
        modifier(AirAnimationModifier(animation: animation, value: value))
    }
}

// MARK: - Type

extension View {
    /// Display type: San Francisco medium, tracked in 3% of its size.
    func airDisplay(_ size: CGFloat, weight: Font.Weight = .medium) -> some View {
        font(.system(size: size, weight: weight)).tracking(-size * 0.03)
    }
    /// A section's name above its rows.
    func airHeading() -> some View {
        font(.system(size: Air.Size.heading, weight: .medium)).tracking(-0.2).foregroundStyle(Air.ink)
    }
}

extension Font {
    /// The figure beside a plan or a size ("1 TB"): the display face at figure size, tabular digits.
    static let airFigure = Font.system(size: Air.Size.figure, weight: .medium).monospacedDigit()
}

// MARK: - Surfaces

/// The window surface: paper with fine grain behind everything.
struct AirPaper: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Air.paper
            .overlay(Image(nsImage: Air.grain).resizable(resizingMode: .tile).opacity(scheme == .dark ? 0.06 : 0.045))
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

/// A panel that holds a choice: a flat sheet a shade lighter than the paper, edged by a hairline. It casts no shadow;
/// the website has none.
struct AirSurface: View {
    var radius: CGFloat = Air.Radius.sheet

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Air.sheet)
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Air.rule, lineWidth: 1))
            .accessibilityHidden(true)
    }
}

extension View {
    /// Paper and grain for a whole window, sheet or panel, with every button in it an outlined capsule unless it asks
    /// for ink.
    func airSurface() -> some View {
        buttonStyle(.airOutline)
            .toggleStyle(.airSwitch)
            .disclosureGroupStyle(.air)
            .labeledContentStyle(.air)
            .foregroundStyle(Air.ink)
            .background { AirPaper() }
    }
}

/// A scrolling page of sections on the paper.
struct AirPage<Content: View>: View {
    var padding: CGFloat = Air.Space.page
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Air.Space.section) { content }
                .padding(padding)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
    }
}

/// A group of rows set as type on the paper, its name above them and a note below, like a section of a settings form.
/// Rows are the content's views, with a hairline above, between and below them; with no rows only the name and note
/// show.
struct AirSection<Content: View, Header: View, Footer: View>: View {
    @ViewBuilder let content: Content
    @ViewBuilder let header: Header
    @ViewBuilder let footer: Footer

    init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header = { EmptyView() },
         @ViewBuilder footer: () -> Footer = { EmptyView() }) {
        self.content = content(); self.header = header(); self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Air.Space.sm + 2) {
            header.airHeading()
            AirRows { content }
            footer.font(.callout).foregroundStyle(Air.quiet).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
    }
}

/// Rows on the paper between hairlines, as the website lists the repository's folders: no card, no fill, no inset.
struct AirRows<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Group(subviews: content) { rows in
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        AirHairline()
                        row.padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    AirHairline()
                }
            }
        }
    }
}

/// One hairline across its container.
struct AirHairline: View {
    var body: some View { Rectangle().fill(Air.rule).frame(height: 1).accessibilityHidden(true) }
}

/// A label and its value on one row: the label's first line in ink and any further lines quiet under it, the value
/// trailing in the quiet tone, as a settings form sets them.
struct AirLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Air.Space.lg) {
            Group(subviews: configuration.label) { lines in
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                        if index == 0 {
                            line.foregroundStyle(Air.ink)
                        } else {
                            line.font(.callout).foregroundStyle(Air.quiet).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .layoutPriority(1)
            Spacer(minLength: Air.Space.md)
            configuration.content
                .foregroundStyle(Air.quiet)
                .multilineTextAlignment(.trailing)
        }
    }
}

extension LabeledContentStyle where Self == AirLabeledContentStyle {
    static var air: AirLabeledContentStyle { AirLabeledContentStyle() }
}

// MARK: - Flow

/// Lays its views out left to right and starts a new line when the next one would cross the edge, so a row of
/// buttons wraps instead of widening its window.
struct AirFlow: Layout {
    var spacing: CGFloat = Air.Space.sm - 2
    var lineSpacing: CGFloat = Air.Space.sm - 2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let limit = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > limit { x = 0; y += line + lineSpacing; line = 0 }
            widest = max(widest, x + size.width)
            x += size.width + spacing
            line = max(line, size.height)
        }
        return CGSize(width: min(widest, limit), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += line + lineSpacing; line = 0 }
            view.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

// MARK: - Buttons

/// Height, type size and side padding of a capsule for each control size.
struct AirButtonMetrics: Equatable {
    let height: CGFloat, font: CGFloat, padding: CGFloat

    init(_ size: ControlSize) {
        switch size {
        case .mini: (height, font, padding) = (20, 11, 9)
        case .small: (height, font, padding) = (24, 12, 11)
        case .large: (height, font, padding) = (36, 14, 18)
        case .extraLarge: (height, font, padding) = (44, 15, 22)
        default: (height, font, padding) = (30, 13, 15)
        }
    }
}

/// The one ink action per view: a flat ink capsule with the paper as its label, as the website's button. Hover lifts
/// the ink off by 14% opacity, press by 26%, over 0.2 s; it never moves (the label stays 9:1 or more). A destructive
/// role takes the problem tone and shades it instead, so its label keeps 4.5:1.
struct AirProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { AirProminentButton(configuration: configuration) }
}

/// A quiet capsule outlined by a firm hairline on the paper, for every action that isn't the one in ink. Hover fills it
/// with the muted tone; press deepens the fill.
struct AirOutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { AirOutlineButton(configuration: configuration) }
}

/// Text only, quiet until hovered: for small actions beside a heading.
struct AirTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { AirTextButton(configuration: configuration) }
}

extension ButtonStyle where Self == AirProminentButtonStyle { static var airProminent: AirProminentButtonStyle { .init() } }
extension ButtonStyle where Self == AirOutlineButtonStyle { static var airOutline: AirOutlineButtonStyle { .init() } }
extension ButtonStyle where Self == AirTextButtonStyle { static var airText: AirTextButtonStyle { .init() } }

private struct AirProminentButton: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @State private var hovering = false

    var body: some View {
        let metrics = AirButtonMetrics(controlSize)
        let destructive = configuration.role == .destructive
        let fill = destructive ? Air.problem : Air.inkFill
        configuration.label
            .font(.system(size: metrics.font, weight: .medium))
            .lineLimit(1)
            // A button keeps its whole title, as a native one does, rather than truncating beside a long label.
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, metrics.padding)
            .frame(height: metrics.height)
            .foregroundStyle(isEnabled ? (destructive ? Air.onProblem : Air.inkLabel) : Air.quiet)
            .background(Capsule(style: .circular).fill(isEnabled ? fill : Air.muted))
            .overlay {
                if destructive && isEnabled {
                    Capsule(style: .circular).fill(Color.black.opacity(configuration.isPressed ? 0.2 : hovering ? 0.1 : 0))
                        .allowsHitTesting(false)
                }
            }
            .opacity(isEnabled && !destructive ? (configuration.isPressed ? 0.74 : hovering ? 0.86 : 1) : 1)
            .contentShape(Capsule(style: .circular))
            .onHover { inside in withAnimation(AirMotion.hover) { hovering = inside } }
            .animation(AirMotion.quick, value: configuration.isPressed)
    }
}

private struct AirOutlineButton: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @State private var hovering = false

    var body: some View {
        let metrics = AirButtonMetrics(controlSize)
        let lit = hovering && isEnabled
        configuration.label
            .font(.system(size: metrics.font, weight: .medium))
            .lineLimit(1)
            // A button keeps its whole title, as a native one does, rather than truncating beside a long label.
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, metrics.padding)
            .frame(height: metrics.height)
            .foregroundStyle(isEnabled ? (configuration.role == .destructive ? Air.problem : Air.ink) : Air.quiet)
            .background {
                Capsule(style: .circular)
                    .fill(configuration.isPressed && isEnabled ? Air.ruleStrong.opacity(0.55) : lit ? Air.muted : .clear)
                    .overlay(Capsule(style: .circular).strokeBorder(Air.ruleStrong, lineWidth: 1))
            }
            .opacity(isEnabled ? 1 : 0.6)
            .contentShape(Capsule(style: .circular))
            .onHover { inside in withAnimation(AirMotion.hover) { hovering = inside } }
            .animation(AirMotion.quick, value: configuration.isPressed)
    }
}

private struct AirTextButton: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(.system(size: AirButtonMetrics(controlSize).font, weight: .medium))
            .foregroundStyle(hovering && isEnabled ? Air.ink : Air.quiet)
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.55)
            .contentShape(Rectangle())
            .onHover { inside in withAnimation(AirMotion.hover) { hovering = inside } }
    }
}

// MARK: - Switches and checkboxes

/// A toggle as a row: the label leading, a capsule switch trailing. Clicking anywhere on the row flips it, as a
/// checkbox's label does. The knob slides on the long ease-out; the track turns sage. VoiceOver and keyboard users get
/// a standard switch.
struct AirSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View { AirSwitchRow(configuration: configuration) }
}

private struct AirSwitchRow: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            withAnimation(reduceMotion ? nil : AirMotion.settle) { configuration.isOn.toggle() }
        } label: {
            HStack(alignment: .center, spacing: Air.Space.md) {
                configuration.label.frame(maxWidth: .infinity, alignment: .leading)
                AirSwitch(isOn: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

extension ToggleStyle where Self == AirSwitchToggleStyle { static var airSwitch: AirSwitchToggleStyle { .init() } }

/// The switch's drawing; the row around it is the control.
private struct AirSwitch: View {
    let isOn: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    var body: some View {
        let height: CGFloat = controlSize == .small || controlSize == .mini ? 18 : 22
        let knob = height - 4
        ZStack(alignment: isOn ? .trailing : .leading) {
            // A disabled switch dims its track; the knob keeps its outline so the control is still there.
            Group {
                Capsule(style: .circular).fill(isOn ? Air.accent : Air.muted)
                Capsule(style: .circular).strokeBorder(isOn ? Color.clear : Air.controlEdge, lineWidth: 1)
            }
            .opacity(isEnabled ? 1 : 0.4)
            Circle().fill(Color.white)
                .overlay(Circle().strokeBorder(Air.controlEdge.opacity(isOn ? 0 : 0.6), lineWidth: 0.5))
                .shadow(color: Air.controlShadow, radius: 1.5, y: 1)
                .frame(width: knob, height: knob)
                .padding(2)
        }
        .frame(width: height * 1.7, height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - Segmented control

/// A capsule track with a white thumb that slides to the chosen option, as the website's Monthly and Annual switch
/// does. VoiceOver and keyboard users get a standard segmented picker.
struct AirSegmented<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let title: String
        var id: Value { value }
    }

    let title: String
    @Binding var selection: Value
    let options: [Option]
    @Namespace private var thumb
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ title: String, selection: Binding<Value>, options: [(Value, String)]) {
        self.title = title; _selection = selection
        self.options = options.map { Option(value: $0.0, title: $0.1) }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                let chosen = option.value == selection
                Button {
                    withAnimation(reduceMotion ? nil : AirMotion.settle) { selection = option.value }
                } label: {
                    Text(option.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(chosen ? Air.ink : Air.quiet)
                        .lineLimit(1)
                        .padding(.horizontal, 14)
                        .frame(height: 26)
                        .background {
                            if chosen {
                                // Edged like any control found by its outline (3:1 or more), so the choice shows
                                // without a shadow.
                                Capsule(style: .circular).fill(Air.thumb)
                                    .overlay(Capsule(style: .circular).strokeBorder(Air.controlEdge, lineWidth: 1))
                                    .matchedGeometryEffect(id: "thumb", in: thumb)
                            }
                        }
                        .contentShape(Capsule(style: .circular))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule(style: .circular).fill(Air.muted).overlay(Capsule(style: .circular).strokeBorder(Air.cardEdge, lineWidth: 1)))
        .opacity(isEnabled ? 1 : 0.5)
        .fixedSize()
        .accessibilityRepresentation {
            Picker(title, selection: $selection) {
                ForEach(options) { Text($0.title).tag($0.value) }
            }
            .pickerStyle(.segmented)
        }
    }
}

// MARK: - Menu picker

/// A pop-up choice drawn as an outlined capsule: the chosen value and a small chevron. The menu lists the options with a
/// check beside the chosen one. VoiceOver and keyboard users get a standard pop-up button.
struct AirMenuPicker<Value: Hashable, Options: View>: View {
    let title: String
    @Binding var selection: Value
    let value: String
    @ViewBuilder let options: Options

    init(_ title: String, selection: Binding<Value>, value: String, @ViewBuilder options: () -> Options) {
        self.title = title; _selection = selection; self.value = value; self.options = options()
    }

    var body: some View {
        Menu {
            Picker(title, selection: $selection) { options }
                .pickerStyle(.inline)
                .labelsHidden()
        } label: {
            HStack(spacing: 6) {
                Text(value).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Air.quiet)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.airOutline)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityRepresentation {
            Picker(title, selection: $selection) { options }.pickerStyle(.menu)
        }
    }
}

// MARK: - Disclosure

/// A disclosure row: the label with a chevron that turns as the content settles in below it.
struct AirDisclosureGroupStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View { AirDisclosure(configuration: configuration) }
}

extension DisclosureGroupStyle where Self == AirDisclosureGroupStyle { static var air: AirDisclosureGroupStyle { .init() } }

private struct AirDisclosure: View {
    let configuration: DisclosureGroupStyleConfiguration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : AirMotion.settle) { configuration.isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Air.quiet)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                    configuration.label.foregroundStyle(Air.ink)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(configuration.isExpanded ? "Hides the details" : "Shows the details")
            if configuration.isExpanded {
                configuration.content
                    .padding(.top, Air.Space.md)
                    .airTransition(.item)
            }
        }
    }
}

// MARK: - Fields

/// A text or secure field drawn as a white well with a hairline edge; the edge darkens and the system focus ring
/// shows while it has the keyboard.
private struct AirFieldModifier: ViewModifier {
    var width: CGFloat?
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Air.Radius.field, style: .continuous)
        content
            .textFieldStyle(.plain)
            .multilineTextAlignment(.leading)
            .focused($focused)
            .foregroundStyle(Air.ink)
            .padding(.horizontal, 10)
            .frame(width: width, height: 28)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .background(shape.fill(Air.fieldFill))
            .overlay(shape.strokeBorder(focused ? Air.ink.opacity(0.7) : Air.controlEdge, lineWidth: 1))
            .overlay(shape.inset(by: -3).strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3)
                .opacity(focused ? 1 : 0).allowsHitTesting(false))
            // Focus shows at once; nothing about it animates.
            .opacity(isEnabled ? 1 : 0.55)
    }
}

extension View {
    /// Draws a TextField or SecureField as an Air field, `width` wide or filling the row.
    func airField(width: CGFloat? = nil) -> some View { modifier(AirFieldModifier(width: width)) }
}

/// A labelled field row: the label leading (with an optional note under it), the field trailing.
struct AirFieldRow<Field: View>: View {
    let title: String
    var note: String?
    var width: CGFloat = 300
    @ViewBuilder let field: Field

    var body: some View {
        LabeledContent {
            field.labelsHidden().airField(width: width)
        } label: {
            Text(title)
            if let note { Text(note) }
        }
    }
}

// MARK: - Meter

/// A thin capsule filling to a fraction, as the website's stream bar does. The fill eases to a new value.
struct AirMeter: View {
    let fraction: Double
    var tone: Color = Air.ink

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .circular).fill(Air.track)
                // Nothing at zero; any other amount is at least a dot, so a little use still shows.
                let share = min(max(fraction, 0), 1)
                if share > 0 {
                    Capsule(style: .circular).fill(tone)
                        .frame(width: max(6, proxy.size.width * share))
                }
            }
        }
        .frame(height: 6)
        .airAnimation(value: fraction)
        .accessibilityHidden(true)
    }
}

// MARK: - Flight

/// ParaAir's mark as a paper plane, as the website draws its planes: the two polygons turned so the nose points along
/// +x, scaled by `size` (the mark's 454-unit width), and centred on the turned shape's own bounds, so it reaches
/// 0.59 x size ahead and behind and 0.37 x size to either side.
enum AirPlane {
    struct Shape { let body: Path, fold: Path }

    /// How far a plane reaches from its centre, as a share of its size: along its heading and across it.
    static let reach = CGSize(width: 0.59, height: 0.37)

    static func shape(size: CGFloat) -> Shape {
        let scale = size / 454, turn = CGFloat.pi / 4
        func turned(_ point: CGPoint) -> CGPoint {
            CGPoint(x: (point.x * cos(turn) - point.y * sin(turn)) * scale, y: (point.x * sin(turn) + point.y * cos(turn)) * scale)
        }
        let all = BrandIconGeometry.mark.flatMap(\.points).map(turned)
        let xs = all.map(\.x), ys = all.map(\.y)
        let centre = CGPoint(x: (xs.min()! + xs.max()!) / 2, y: (ys.min()! + ys.max()!) / 2)
        func path(_ polygon: BrandIconGeometry.Polygon) -> Path {
            var path = Path()
            for (index, point) in polygon.points.map(turned).enumerated() {
                let placed = CGPoint(x: point.x - centre.x, y: point.y - centre.y)
                if index == 0 { path.move(to: placed) } else { path.addLine(to: placed) }
            }
            path.closeSubpath()
            return path
        }
        return Shape(body: path(BrandIconGeometry.mark[0]), fold: path(BrandIconGeometry.mark[1]))
    }
}

/// Where a header's planes fly. `window`: a lead plane in ink and sage that rests in the open paper beside the words,
/// with a grey flock around it when there is room, and that can fly in under the underlined words. `panel`: one small
/// plane just off the end of the underline. `about`: a larger lead and its flock in the sky band above the name.
enum AirFlightStyle { case window, panel, about }

/// What the planes are placed around, measured in the flying view's own coordinates.
struct AirFlightMarks {
    /// The words the lead plane flew under; the sage line is drawn beneath them, and the planes fly beside them.
    var underline: Anchor<CGRect>?
    /// The open paper set aside for planes, where a view names one.
    var sky: Anchor<CGRect>?
}

private struct AirFlightKey: PreferenceKey {
    static var defaultValue: AirFlightMarks { AirFlightMarks() }
    static func reduce(value: inout AirFlightMarks, nextValue: () -> AirFlightMarks) {
        let next = nextValue()
        value.underline = value.underline ?? next.underline
        value.sky = value.sky ?? next.sky
    }
}

/// The planes of one header, laid out once for its size, then drawn at a point in the lead plane's entrance.
struct AirFlightLayout {
    struct Plane { var at: CGPoint; var angle: CGFloat; var size: CGFloat; var opacity: CGFloat; var near: Bool }

    /// A flight: straight from `start` to `run`, then a curve through `control`'s pull to `home`. The straight run keeps
    /// a plane under its words until it is past them, so the climb never cuts across their last letters.
    struct Flight {
        var start: CGPoint, run: CGPoint, control: CGPoint, home: CGPoint

        private var straight: CGFloat { hypot(run.x - start.x, run.y - start.y) }
        private var curve: CGFloat { hypot(control.x - run.x, control.y - run.y) + hypot(home.x - control.x, home.y - control.y) }
        /// How far along the straight run ends. The trail is only ever the curve: on the run, the line is the trail.
        var runShare: CGFloat { straight + curve > 0 ? straight / (straight + curve) : 0 }

        /// The point `t` of the way along, by distance, on both pieces together.
        func point(_ t: CGFloat) -> CGPoint {
            let straight = self.straight, curve = self.curve
            let at = min(1, max(0, t)) * (straight + curve)
            if straight > 0, at <= straight {
                let k = at / straight
                return CGPoint(x: start.x + (run.x - start.x) * k, y: start.y + (run.y - start.y) * k)
            }
            let k = curve > 0 ? (at - straight) / curve : 1, m = 1 - k
            return CGPoint(x: m * m * run.x + 2 * m * k * control.x + k * k * home.x,
                           y: m * m * run.y + 2 * m * k * control.y + k * k * home.y)
        }
    }

    /// How long the lead plane's entrance lasts: the website's hero entrance, 1.5 s on an ease-out cubic.
    static let duration: Double = 1.5
    /// The lead plane's size while it runs under the words, as a share of its resting size: small enough to pass
    /// between the name's descenders and the state line below.
    static let underScale: CGFloat = 0.5
    /// How far above the flying view the planes may go, into the margin over a header.
    static let headroom: CGFloat = 24

    private(set) var underline: CGRect?
    private(set) var lead: Plane?
    /// The lead plane's flight in: under the words, then up into its place. Its last stretch is the trail it rests with.
    private(set) var path: Flight?
    private(set) var reach: CGFloat = 0
    private(set) var flock: [Plane] = []

    init(style: AirFlightStyle, words: CGRect?, sky: CGRect?, width: CGFloat, seed: UInt64) {
        let thickness: CGFloat = style == .panel ? 1.5 : 2.25
        if let words, words.width > 8 {
            // Just below the descenders, so a g or a y never sits on the line.
            underline = CGRect(x: words.minX + 1, y: words.maxY + thickness * 0.8, width: words.width - 2, height: thickness)
        }
        switch style {
        case .window:
            // The open paper to the right of the name, from the margin above the header to just below the name, so a
            // plane never meets the state line under it. It depends on the name alone: the state changing doesn't move
            // a plane.
            guard let words, let line = underline else { return }
            let zone = CGRect(x: words.maxX + 40, y: -Self.headroom + 6, width: width - words.maxX - 40,
                              height: words.maxY + 14 + Self.headroom - 6)
            guard zone.width >= 120, zone.height >= 56 else { return }
            // Close enough to the words that its trail reads as the line it drew under them.
            let home = CGPoint(x: min(max(zone.minX + min(zone.width * 0.3, 100), zone.minX + 30), zone.maxX - 30),
                               y: zone.minY + zone.height * 0.42)
            // Just under the line, clear of the descenders above and the state below, until past the words.
            let start = CGPoint(x: line.minX + 6, y: line.midY + 4)
            let run = CGPoint(x: line.maxX + 10, y: start.y)
            let turn = CGPoint(x: run.x + max(20, (home.x - run.x) * 0.55), y: start.y)
            path = Flight(start: start, run: run, control: turn, home: home)
            reach = 120
            lead = Plane(at: home, angle: atan2(home.y - turn.y, home.x - turn.x), size: 30, opacity: 1, near: true)
            if zone.width >= 200 {
                flock = Self.flock(in: zone, lead: lead!, trail: Self.trail(path!, from: 1, reach: reach).map(\.point), seed: seed)
            }
        case .panel:
            guard let underline, let words else { return }
            let home = CGPoint(x: underline.maxX + 30, y: words.midY - 2)
            guard home.x + 16 <= width else { return }
            // The trail leaves the end of the line rather than running over it.
            let start = CGPoint(x: underline.maxX - 1, y: underline.midY)
            let turn = CGPoint(x: underline.maxX + 14, y: underline.midY)
            path = Flight(start: start, run: start, control: turn, home: home)
            reach = 40
            lead = Plane(at: home, angle: atan2(home.y - turn.y, home.x - turn.x), size: 15, opacity: 1, near: true)
        case .about:
            guard let sky else { return }
            // Clear of the window's buttons in the top corner.
            let zone = CGRect(x: sky.minX + 12, y: sky.minY + 30, width: sky.width - 24, height: sky.height - 38)
            let home = CGPoint(x: zone.midX + 18, y: zone.minY + zone.height * 0.5)
            let turn = CGPoint(x: home.x - 70, y: home.y + 26)
            let start = CGPoint(x: home.x - 170, y: home.y + 34)
            path = Flight(start: start, run: start, control: turn, home: home)
            reach = 110
            lead = Plane(at: home, angle: atan2(home.y - turn.y, home.x - turn.x), size: 44, opacity: 1, near: true)
            flock = Self.flock(in: zone, lead: lead!, trail: Self.trail(path!, from: 1, reach: reach).map(\.point), seed: seed)
        }
    }

    // MARK: Drawing

    /// Draws everything `progress` of the way through the lead plane's entrance; 1 is where it all rests.
    func draw(_ context: GraphicsContext, progress: Double) {
        let shape = AirPlane.shape(size: 1)
        for plane in flock {
            if plane.near {
                // As on the website: a faint grey line that starts at the plane's tail and tapers away behind it.
                let tail = plane.size * AirPlane.reach.width
                let points = (0...5).map { step -> (point: CGPoint, weight: CGFloat) in
                    let back = tail + CGFloat(step) * 9
                    return (CGPoint(x: plane.at.x - cos(plane.angle) * back, y: plane.at.y - sin(plane.angle) * back), 1 - CGFloat(step) / 5)
                }
                Self.stroke(context, points, color: Air.planeGrey, width: 1.5, opacity: 0.25)
            }
            Self.stamp(context, shape, plane, body: Air.planeGrey, fold: Air.planeFold, scale: plane.size)
        }
        guard let lead, let path else {
            if let underline { Self.drawUnderline(context, underline, drawn: Self.ease(progress)) }
            return
        }
        if progress >= 1 {
            if let underline { Self.drawUnderline(context, underline, drawn: 1) }
            Self.stroke(context, Self.trail(path, from: 1, reach: reach), color: Air.trail, width: lead.size * 0.075, opacity: 0.9)
            Self.stamp(context, shape, lead, body: Air.ink, fold: Air.markGreen, scale: lead.size)
            return
        }
        // In flight: the plane rides the tip of the line it draws, small, then climbs into its place, growing as it nears.
        let along = Self.ease(progress)
        let at = path.point(along)
        let ahead = path.point(min(1, along + 0.01))
        if let underline { Self.drawUnderline(context, underline, drawn: min(1, max(0, (at.x - underline.minX) / underline.width))) }
        let shown = min(1, progress / 0.12)
        let angle = along >= 0.99 ? lead.angle : atan2(ahead.y - at.y, ahead.x - at.x)
        let climbed = path.runShare < 1 ? max(0, (along - path.runShare) / (1 - path.runShare)) : 1
        let size = lead.size * (Self.underScale + (1 - Self.underScale) * climbed)
        Self.stroke(context, Self.trail(path, from: along, reach: reach), color: Air.trail, width: lead.size * 0.075, opacity: 0.9 * shown)
        Self.stamp(context, shape, Plane(at: at, angle: angle, size: size, opacity: shown, near: true),
                   body: Air.ink, fold: Air.markGreen, scale: size)
    }

    /// The website's entrance curve: an ease-out cubic.
    private static func ease(_ t: Double) -> CGFloat {
        1 - pow(1 - CGFloat(min(1, max(0, t))), 3)
    }

    /// The path behind a point on the flight, back `reach` points or to where its curve began, each point with its weight.
    private static func trail(_ path: Flight, from t: CGFloat, reach: CGFloat) -> [(point: CGPoint, weight: CGFloat)] {
        var points = [path.point(t)], length: CGFloat = 0, at = t
        let floor = path.runShare
        while at > floor, length < reach {
            at = max(floor, at - 0.004)
            let next = path.point(at)
            length += hypot(next.x - points.last!.x, next.y - points.last!.y)
            points.append(next)
        }
        // Tapers to nothing at its tail, as the website's trails do.
        return points.enumerated().map { ($0.element, 1 - CGFloat($0.offset) / CGFloat(max(1, points.count - 1))) }
    }

    /// A trail as one tapered shape, full width and opacity at its head and nothing at its tail, so overlapping caps
    /// never darken it.
    private static func stroke(_ context: GraphicsContext, _ points: [(point: CGPoint, weight: CGFloat)], color: Color,
                               width: CGFloat, opacity: CGFloat) {
        guard points.count > 1, opacity > 0 else { return }
        var left: [CGPoint] = [], right: [CGPoint] = []
        for (index, entry) in points.enumerated() {
            let before = points[max(0, index - 1)].point, after = points[min(points.count - 1, index + 1)].point
            let dx = after.x - before.x, dy = after.y - before.y, length = max(0.001, hypot(dx, dy))
            let half = max(0.1, width * entry.weight / 2)
            let normal = CGPoint(x: -dy / length * half, y: dx / length * half)
            left.append(CGPoint(x: entry.point.x + normal.x, y: entry.point.y + normal.y))
            right.append(CGPoint(x: entry.point.x - normal.x, y: entry.point.y - normal.y))
        }
        var shape = Path()
        shape.addLines(left + right.reversed())
        shape.closeSubpath()
        context.fill(shape, with: .linearGradient(Gradient(colors: [color.opacity(opacity), color.opacity(0)]),
                                                  startPoint: points.first!.point, endPoint: points.last!.point))
    }

    private static func stamp(_ context: GraphicsContext, _ shape: AirPlane.Shape, _ plane: Plane, body: Color, fold: Color, scale: CGFloat) {
        var context = context
        context.opacity = plane.opacity
        context.translateBy(x: plane.at.x, y: plane.at.y)
        context.rotate(by: .radians(plane.angle))
        context.scaleBy(x: scale, y: scale)
        context.fill(shape.body, with: .color(body))
        context.fill(shape.fold, with: .color(fold))
    }

    /// The sage line under the words: it fades in from the left, as the website's does, and is drawn from the left.
    /// The fade is a third of the line at most and about one and a half letters long, so a short name still reads as
    /// underlined from its first letter.
    private static func drawUnderline(_ context: GraphicsContext, _ line: CGRect, drawn: CGFloat) {
        guard drawn > 0 else { return }
        let shown = CGRect(x: line.minX, y: line.minY, width: max(line.height, line.width * drawn), height: line.height)
        let fade = min(0.35, line.height * 16 / max(line.width, 1))
        context.fill(Path(roundedRect: shown, cornerRadius: line.height / 2, style: .circular),
                     with: .linearGradient(Gradient(stops: [.init(color: Air.trail.opacity(0), location: 0),
                                                            .init(color: Air.trail, location: fade),
                                                            .init(color: Air.trail, location: 1)]),
                                           startPoint: CGPoint(x: line.minX, y: line.midY), endPoint: CGPoint(x: line.maxX, y: line.midY)))
    }

    /// A small grey flock in the zone, heading roughly as the lead does: near planes larger and darker, far ones small
    /// and faint. Each plane has a fixed place as a share of the zone, so resizing the window slides the flock rather
    /// than shuffling it; a plane that would sit on the lead, its trail or another plane stays out.
    private static func flock(in zone: CGRect, lead: Plane, trail: [CGPoint], seed: UInt64) -> [Plane] {
        var state = seed | 1
        func random() -> CGFloat {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((state >> 11) & 0xFFFFFF) / CGFloat(0xFFFFFF)
        }
        var planes: [Plane] = []
        for _ in 0..<9 {
            let near = random() < 0.45
            let size = near ? 17 + 3 * random() : 11 + 2 * random()
            let opacity = near ? 0.72 + 0.15 * random() : 0.42 + 0.1 * random()
            let angle = lead.angle + (random() - 0.5) * 0.5
            let across = random(), down = random()
            let margin = size * AirPlane.reach.width + 8
            guard zone.width > margin * 2, zone.height > margin * 2 else { continue }
            let at = CGPoint(x: zone.minX + margin + across * (zone.width - margin * 2),
                             y: zone.minY + margin + down * (zone.height - margin * 2))
            let clearOfLead = hypot(at.x - lead.at.x, at.y - lead.at.y) >= (lead.size + size) * AirPlane.reach.width + 10
            let clearOfTrail = trail.allSatisfy { hypot(at.x - $0.x, at.y - $0.y) >= size * AirPlane.reach.width + 8 }
            let clearOfFlock = planes.allSatisfy { hypot(at.x - $0.at.x, at.y - $0.at.y) >= (size + $0.size) * AirPlane.reach.width + 8 }
            if clearOfLead, clearOfTrail, clearOfFlock {
                planes.append(Plane(at: at, angle: angle, size: size, opacity: opacity, near: near))
            }
        }
        return planes
    }

    /// A stable seed from a name, so each drive keeps its own sky.
    static func seed(_ name: String) -> UInt64 {
        name.unicodeScalars.reduce(0xCBF29CE484222325 as UInt64) { ($0 ^ UInt64($1.value)) &* 0x100000001B3 }
    }
}

extension View {
    /// Marks the words the lead plane flew under: the sage line is drawn beneath them, and the planes fly beside them.
    func airUnderlined() -> some View {
        transformAnchorPreference(key: AirFlightKey.self, value: .bounds) { marks, anchor in marks.underline = anchor }
    }

    /// Marks open paper set aside for planes.
    func airSky() -> some View {
        transformAnchorPreference(key: AirFlightKey.self, value: .bounds) { marks, anchor in marks.sky = anchor }
    }

    /// Draws the planes over this view, beside the words inside it that are marked. With `entrance`, the lead plane
    /// flies in under the underlined words once when the view appears, drawing the line as it goes; without motion
    /// (Reduce Motion, or a snapshot) everything is where it rests from the start.
    func airFlight(_ style: AirFlightStyle, seed: String = "", entrance: Bool = false) -> some View {
        modifier(AirFlightModifier(style: style, seed: AirFlightLayout.seed(seed), entrance: entrance))
    }
}

private struct AirFlightModifier: ViewModifier {
    let style: AirFlightStyle
    let seed: UInt64
    let entrance: Bool
    @State private var departed: Date?
    @State private var landed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.airAmbientMotion) private var ambient

    /// Whether the entrance is still to come or under way. Its first frame is the start of the flight, never the
    /// resting sky, so nothing flashes before the plane sets off.
    private var flying: Bool { entrance && ambient && !reduceMotion && !landed }

    func body(content: Content) -> some View {
        content
            .overlayPreferenceValue(AirFlightKey.self) { marks in
                GeometryReader { proxy in
                    let layout = AirFlightLayout(style: style, words: marks.underline.map { proxy[$0] },
                                                 sky: marks.sky.map { proxy[$0] }, width: proxy.size.width, seed: seed)
                    TimelineView(.animation(minimumInterval: nil, paused: !flying || departed == nil)) { timeline in
                        let progress = flying ? departed.map { timeline.date.timeIntervalSince($0) / AirFlightLayout.duration } ?? 0 : 1
                        Canvas { context, _ in
                            var context = context
                            context.translateBy(x: 0, y: AirFlightLayout.headroom)
                            layout.draw(context, progress: progress)
                        }
                        .frame(width: proxy.size.width, height: proxy.size.height + AirFlightLayout.headroom)
                        .offset(y: -AirFlightLayout.headroom)
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .onAppear { if flying { departed = .now } else { landed = true } }
            // Turning Reduce Motion on mid-flight lands everything at once, for good.
            .onChange(of: reduceMotion) { if reduceMotion { landed = true } }
            // The flight lands by the clock, so the sky is whole even if no frame of it was ever drawn.
            .task(id: departed) {
                guard departed != nil else { return }
                do { try await Task.sleep(for: .seconds(AirFlightLayout.duration + 0.05)) } catch { return }
                landed = true
            }
    }
}

/// A slow ink band across quiet text while something is under way, as the website's launcher shimmers.
private struct AirShimmer: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.airAmbientMotion) private var ambient
    @State private var sweep: CGFloat = -1

    func body(content: Content) -> some View {
        content.overlay {
            if active, ambient, !reduceMotion {
                GeometryReader { proxy in
                    LinearGradient(stops: [.init(color: Air.ink.opacity(0), location: 0), .init(color: Air.ink.opacity(0.85), location: 0.5),
                                           .init(color: Air.ink.opacity(0), location: 1)],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: proxy.size.width * 0.5)
                        .offset(x: sweep * proxy.size.width)
                }
                .mask(content)
                .allowsHitTesting(false)
                .onAppear { withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) { sweep = 1.2 } }
            }
        }
    }
}

extension View {
    /// Sweeps an ink band across this text while `active`.
    func airShimmer(_ active: Bool) -> some View { modifier(AirShimmer(active: active)) }
}

// MARK: - Links and the mark

/// A web link in ink, underlined, with a tinted underline that turns ink on hover.
struct AirLink: View {
    let title: String
    let destination: URL
    @State private var hovering = false

    init(_ title: String, destination: URL) { self.title = title; self.destination = destination }

    var body: some View {
        Link(destination: destination) {
            Text(title).underline(color: hovering ? Air.ink : Air.quiet.opacity(0.6))
        }
        // A Link takes the surrounding button style; the window's outlined capsule would swallow it.
        .buttonStyle(.plain)
        .fixedSize()
        .pointerStyle(.link)
        .foregroundStyle(Air.ink)
        .tint(Air.ink)
        .onHover { inside in withAnimation(AirMotion.hover) { hovering = inside } }
        .help(destination.host ?? destination.absoluteString)
    }
}

/// ParaAir's mark from the shared polygon geometry. `badge` includes the charcoal square; without it the two flight
/// polygons render bare, in ink and the mark's green, or as one template shape.
struct ParaAirMark: View {
    var badge = true
    var template = false
    /// The bare mark in the flock's greys, for a stand-in that shouldn't compete with the lead plane.
    var quiet = false

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let origin = CGPoint(x: (size.width - side) / 2, y: (size.height - side) / 2)
            let polygons = badge ? [BrandIconGeometry.badge] + BrandIconGeometry.mark : BrandIconGeometry.mark
            let bounds = badge ? CGRect(x: 0, y: 0, width: 1024, height: 1024) : markBounds
            let scale = side / max(bounds.width, bounds.height)
            let inset = CGPoint(x: origin.x + (side - bounds.width * scale) / 2,
                                y: origin.y + (side - bounds.height * scale) / 2)
            for polygon in polygons {
                var path = Path()
                for (index, point) in polygon.points.enumerated() {
                    let mapped = CGPoint(x: inset.x + (point.x - bounds.minX) * scale,
                                         y: inset.y + (point.y - bounds.minY) * scale)
                    if index == 0 { path.move(to: mapped) } else { path.addLine(to: mapped) }
                }
                path.closeSubpath()
                let fill: Color
                if badge {
                    fill = [Self.brand(0), Self.brand(1), Self.brand(2)][polygon.color]
                } else if template {
                    fill = .primary
                } else {
                    fill = quiet ? (polygon.color == 1 ? Air.planeGrey : Air.planeFold) : polygon.color == 1 ? Air.ink : Air.markGreen
                }
                context.fill(path, with: .color(fill))
            }
        }
        .accessibilityHidden(true)
    }

    private static func brand(_ index: Int) -> Color {
        let rgb = BrandIconGeometry.palette[index]
        return Color(.sRGB, red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }

    private var markBounds: CGRect {
        let points = BrandIconGeometry.mark.flatMap(\.points)
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
}
