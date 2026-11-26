import SwiftUI
import AppKit

// ParaAir's interface language, "Air": cool paper, ink type set tight, glass cards that cast their shadow downward,
// capsule controls, one sage accent from the mark, and an airflow field of fine dots behind the header. Motion uses
// two curves: a long ease-out (0.22, 1, 0.36, 1) for things that arrive or move, a short standard ease for hover and
// press. Under Reduce Motion nothing slides, scales, blurs or drifts; hover and press keep their colour fades.
// docs/app-design.md describes the system; this file is its only source of values.

// MARK: - Tokens

enum Air {
    // Surfaces and ink. Light: cool paper #F7F8FA and ink #0E0F12. Dark: near-black #0C0D10 and #F6F7F9.
    static let paper = adaptive(dark: 0x0C0D10, light: 0xF7F8FA)
    static let ink = adaptive(dark: 0xF6F7F9, light: 0x0E0F12)
    /// Supporting text: 5.2:1 on light paper, 4.8:1 on the muted fill; 7.0:1 on dark paper, 5.8:1 on dark cards.
    static let quiet = adaptive(dark: 0x969CA8, light: 0x646974)
    /// Tracks, hover fills and pressed controls.
    static let muted = adaptive(dark: 0x1A1C20, light: 0xEEF0F3)
    /// Hairlines between rows.
    static let rule = adaptive(dark: 0x24272C, light: 0xE6E8EC)
    /// The empty part of a meter: visible on cards in both appearances.
    static let track = adaptive(dark: (0xF6F7F9, 0.16), light: (0x0E0F12, 0.11))
    /// The edge of a control that must be found by its outline (a field, a checkbox, a switch that is off): 3:1 or
    /// more against cards and paper.
    static let controlEdge = adaptive(dark: (0xF6F7F9, 0.42), light: (0x0E0F12, 0.46))

    // Cards: a glass-white sheet that lightens toward the top, edged by its own tone, lit along the top lip.
    static let cardTop = adaptive(dark: 0x1F2127, light: 0xFDFDFE)
    static let cardBottom = adaptive(dark: 0x131418, light: 0xFBFBFC)
    static let cardEdge = adaptive(dark: (0xFFFFFF, 0.08), light: (0x0F172A, 0.08))
    static let cardLip = adaptive(dark: (0xFFFFFF, 0.07), light: (0xFFFFFF, 0.95))
    static let cardShadow = adaptive(dark: (0x000000, 0.55), light: (0x0F172A, 0.16))

    // Controls.
    static let glassFill = adaptive(dark: (0xFFFFFF, 0.06), light: (0xFFFFFF, 0.72))
    static let glassHover = adaptive(dark: (0xFFFFFF, 0.11), light: (0xFFFFFF, 0.96))
    static let glassEdge = adaptive(dark: (0xFFFFFF, 0.13), light: (0x0F172A, 0.10))
    static let glassEdgeHover = adaptive(dark: (0xFFFFFF, 0.19), light: (0x0F172A, 0.15))
    static let thumb = adaptive(dark: 0x2E3137, light: 0xFFFFFF)
    static let controlShadow = adaptive(dark: (0x000000, 0.45), light: (0x0F172A, 0.12))
    /// The prominent button: ink on light paper, the light ink on dark paper, with the paper as its label (18:1).
    static let inkFill = ink
    static let inkLabel = paper
    static let inkShadow = adaptive(dark: (0x000000, 0.6), light: (0x0F172A, 0.42))
    static let fieldFill = adaptive(dark: (0xFFFFFF, 0.05), light: (0xFFFFFF, 1))

    /// The one colour beside ink: the mark's sage, for switches that are on and things that are well.
    /// White on it: 6.1:1 (light) and 4.0:1 (dark); against the paper 5.7:1 and 4.9:1.
    static let accent = adaptive(dark: 0x588974, light: 0x3F6B5A)
    /// The mark's green itself (BrandIconGeometry.palette[2]).
    static let markGreen = adaptive(dark: 0x9AC7B4, light: 0x9AC7B4)

    // Status tones, each at least 4.5:1 on the paper and on cards.
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
        static let card: CGFloat = 22, inset: CGFloat = 12, field: CGFloat = 9
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

/// The ambient motion (the airflow drift and the working shimmer). The snapshot harness turns it off so captures
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
    /// A section's name above its card.
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

/// A card's material: the glass sheet, its own-tone edge, the lit top lip, and a soft shadow that pools under the
/// bottom edge only. The shadow comes from a smaller copy tucked under the card, so it never rings the sides.
struct AirSurface: View {
    var radius: CGFloat = Air.Radius.card
    var raised = true

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            if raised {
                shape.fill(Air.cardBottom)
                    .padding(.horizontal, radius * 1.2).padding(.top, radius)
                    .shadow(color: Air.cardShadow, radius: 18, x: 0, y: 14)
            }
            shape.fill(LinearGradient(colors: [Air.cardTop, Air.cardBottom], startPoint: .top, endPoint: .bottom))
            shape.strokeBorder(Air.cardEdge, lineWidth: 1)
            GeometryReader { proxy in
                shape.inset(by: 0.5).stroke(LinearGradient(stops: [.init(color: Air.cardLip, location: 0),
                                                                    .init(color: Air.cardLip.opacity(0), location: min(1, 12 / max(proxy.size.height, 1)))],
                                                            startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
        }
        .accessibilityHidden(true)
    }
}

extension View {
    /// Paper and grain for a whole window, sheet or panel, with every button in it drawn as glass unless it asks for ink.
    func airSurface() -> some View {
        buttonStyle(.airGlass)
            .toggleStyle(.airSwitch)
            .disclosureGroupStyle(.air)
            .labeledContentStyle(.air)
            .foregroundStyle(Air.ink)
            .background { AirPaper() }
    }
}

/// A scrolling page of sections on the paper, with an optional airflow field behind its top.
struct AirPage<Content: View>: View {
    var field = false
    var padding: CGFloat = Air.Space.page
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Air.Space.section) { content }
                .padding(padding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .airFieldBackground(field ? 250 : nil)
        }
        .scrollContentBackground(.hidden)
    }
}

/// How far right the text that the airflow must stay clear of reaches, in the field's coordinate space.
struct AirClearanceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

extension View {
    /// Marks text the airflow behind it must not cross: the ribbons start a little to its right.
    func airClearsField() -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: AirClearanceKey.self, value: proxy.frame(in: .named(AirflowField.space)).maxX)
        })
    }

    /// The airflow behind the top of this view, `height` tall, kept to the right of whatever inside it asked to stay
    /// clear. Nil draws nothing.
    func airFieldBackground(_ height: CGFloat?) -> some View { modifier(AirFieldBackground(height: height)) }
}

private struct AirFieldBackground: ViewModifier {
    let height: CGFloat?
    @State private var clearance: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .coordinateSpace(.named(AirflowField.space))
            .onPreferenceChange(AirClearanceKey.self) { clearance = $0 }
            .background(alignment: .top) {
                if let height { AirflowField(height: height, clearX: clearance > 0 ? clearance + 28 : nil) }
            }
    }
}

/// A group of rows in one card, its name above it and a note below, like a section of a settings form. Rows are the
/// content's views, each separated by a hairline; with no rows the card is left out.
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
            header.airHeading().padding(.horizontal, 2)
            AirRows { content }
            footer.font(.callout).foregroundStyle(Air.quiet).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 2)
        }
        .accessibilityElement(children: .contain)
    }
}

/// A card of rows separated by hairlines.
struct AirRows<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder let content: Content

    var body: some View {
        Group(subviews: content) { rows in
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Rectangle().fill(Air.rule).frame(height: 1).accessibilityHidden(true) }
                        row.padding(.vertical, 11).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, padding).padding(.vertical, 3)
                .background(AirSurface())
            }
        }
    }
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

/// The one ink action per view: an ink capsule with the paper as its label, lit along its top edge, with a tight
/// shadow beneath it. Hover lifts the ink off by 14% opacity, press by 26%, over 0.2 s; it never moves (the label stays
/// 9:1 or more). A destructive role takes the problem tone and shades it instead, so its label keeps 4.5:1.
struct AirProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { AirProminentButton(configuration: configuration) }
}

/// A quiet capsule of glass: the website's secondary control. Hover brightens the glass and its edge.
struct AirGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { AirGlassButton(configuration: configuration) }
}

/// Text only, quiet until hovered: for small actions beside a heading.
struct AirTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { AirTextButton(configuration: configuration) }
}

extension ButtonStyle where Self == AirProminentButtonStyle { static var airProminent: AirProminentButtonStyle { .init() } }
extension ButtonStyle where Self == AirGlassButtonStyle { static var airGlass: AirGlassButtonStyle { .init() } }
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
            .background {
                ZStack {
                    if isEnabled {
                        Capsule(style: .circular).fill(fill)
                            .padding(.horizontal, metrics.height * 0.4).padding(.top, metrics.height * 0.45)
                            .shadow(color: Air.inkShadow, radius: metrics.height * 0.22, y: metrics.height * 0.2)
                    }
                    Capsule(style: .circular).fill(isEnabled ? fill : Air.muted)
                    if isEnabled {
                        Capsule(style: .circular).strokeBorder(LinearGradient(stops: [.init(color: .white.opacity(0.18), location: 0),
                                                                      .init(color: .white.opacity(0), location: 0.35)],
                                                              startPoint: .top, endPoint: .bottom), lineWidth: 1)
                    }
                }
            }
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

private struct AirGlassButton: View {
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
                ZStack {
                    Capsule(style: .circular).fill(configuration.isPressed && isEnabled ? Air.muted : lit ? Air.glassHover : Air.glassFill)
                    Capsule(style: .circular).strokeBorder(lit ? Air.glassEdgeHover : Air.glassEdge, lineWidth: 1)
                    Capsule(style: .circular).inset(by: 1).stroke(LinearGradient(stops: [.init(color: Air.cardLip, location: 0),
                                                                         .init(color: Air.cardLip.opacity(0), location: 0.3)],
                                                                 startPoint: .top, endPoint: .bottom), lineWidth: 1)
                }
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
                                Capsule(style: .circular).fill(Air.thumb)
                                    .shadow(color: Air.controlShadow, radius: 1.5, y: 1)
                                    .overlay(Capsule(style: .circular).inset(by: 0.5).stroke(Air.cardLip, lineWidth: 0.5))
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

/// A pop-up choice drawn as a glass capsule: the chosen value and a small chevron. The menu lists the options with a
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
        .buttonStyle(.airGlass)
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

// MARK: - Airflow

/// The signature behind headers: two twisted ribbons of fine dots, one slate and one in the mark's sage, like air
/// read over a wing. Drawn once per appearance; it drifts sideways in a slow seamless loop unless Reduce Motion is on.
enum Airflow {
    /// The pattern repeats every `period` points, so two copies side by side loop without a seam.
    static let period: CGFloat = 720
    static let height: CGFloat = 260

    static let light = draw(dark: false)
    static let dark = draw(dark: true)

    private static func draw(dark: Bool) -> NSImage {
        let scale: CGFloat = 2
        let width = Int(period * scale), height = Int(Self.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return NSImage(size: NSSize(width: period, height: Self.height))
        }
        context.scaleBy(x: scale, y: scale)
        // From left to right: slate, then the mark's sage.
        let slate: (CGFloat, CGFloat, CGFloat) = dark ? (0.72, 0.78, 0.94) : (0.34, 0.41, 0.60)
        let sage: (CGFloat, CGFloat, CGFloat) = dark ? (0.60, 0.86, 0.74) : (0.24, 0.53, 0.42)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func random() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((seed >> 11) & 0xFFFFFF) / CGFloat(0xFFFFFF)
        }
        // Two twisted ribbons. Each has a centre line, a width that swells and pinches as it turns (|sin| repeats
        // twice per period, so the loop stays seamless) and a dot count; pinches read denser, like a ribbon edge-on.
        struct Ribbon { let base, amplitude, phase, width, swell, twist: CGFloat; let dots: Int; let tone: (CGFloat, CGFloat, CGFloat) }
        // Centre lines 70 and 86 points from the top (Core Graphics counts from the bottom), in the band beside a header.
        let ribbons = [Ribbon(base: Self.height - 70, amplitude: 26, phase: 0.2, width: 10, swell: 44, twist: 1.1, dots: 22000, tone: slate),
                       Ribbon(base: Self.height - 86, amplitude: 22, phase: 2.1, width: 7, swell: 32, twist: 2.7, dots: 20000, tone: sage)]
        for ribbon in ribbons {
            for _ in 0..<ribbon.dots {
                let x = random() * period
                let angle = 2 * .pi * x / period
                let center = ribbon.base + ribbon.amplitude * sin(angle + ribbon.phase)
                let half = (ribbon.width + ribbon.swell * abs(sin(angle + ribbon.twist))) / 2
                let across = random() * 2 - 1
                let y = center + across * half
                // Denser and brighter toward the ribbon's two edges, as a turned surface catches light.
                let edge = 0.45 + 0.55 * pow(abs(across), 2)
                let mix = 0.5 - 0.5 * cos(angle)
                let other = ribbon.tone == slate ? sage : slate
                let r = ribbon.tone.0 + (other.0 - ribbon.tone.0) * mix * 0.15
                let g = ribbon.tone.1 + (other.1 - ribbon.tone.1) * mix * 0.15
                let b = ribbon.tone.2 + (other.2 - ribbon.tone.2) * mix * 0.15
                let alpha = ((dark ? 0.26 : 0.2) + 0.62 * random()) * edge
                let radius = 0.28 + 0.3 * random()
                context.setFillColor(red: r * alpha, green: g * alpha, blue: b * alpha, alpha: alpha)
                for dx in [x, x - period, x + period] where dx > -2 && dx < period + 2 {
                    context.fillEllipse(in: CGRect(x: dx - radius, y: y - radius, width: radius * 2, height: radius * 2))
                }
            }
        }
        guard let image = context.makeImage() else { return NSImage(size: NSSize(width: period, height: Self.height)) }
        return NSImage(cgImage: image, size: NSSize(width: period, height: Self.height))
    }
}

/// The airflow behind a header. It is fully drawn at rest; motion only slides what is already there.
struct AirflowField: View {
    static let space = "airflow"

    var height: CGFloat = Airflow.height
    /// Where the ribbons start to show, as a fraction of the width: the text column to its left stays clear paper.
    var clearLeading: CGFloat = 0.5
    /// A fade at the trailing edge too, as a fraction of the width; zero runs the ribbons off the edge.
    var clearTrailing: CGFloat = 0
    /// Where the ribbons start, in points, when the text beside them measured itself; it overrides `clearLeading`.
    var clearX: CGFloat?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.airAmbientMotion) private var ambient
    @State private var drift: CGFloat = 0

    private func horizontalFade(width: CGFloat) -> [Gradient.Stop] {
        let start = clearX.map { min(0.9, $0 / max(width, 1)) } ?? clearLeading
        let solid = min(0.96, start + (clearX == nil ? 0.28 : min(0.3, 110 / max(width, 1))))
        var stops: [Gradient.Stop] = [.init(color: .clear, location: 0), .init(color: .clear, location: start),
                                      .init(color: .black, location: solid)]
        if clearTrailing > 0 {
            stops += [.init(color: .black, location: max(solid, 1 - clearTrailing)), .init(color: .clear, location: 1)]
        } else {
            stops.append(.init(color: .black, location: 1))
        }
        return stops
    }

    var body: some View {
        GeometryReader { proxy in
            let copies = Int((proxy.size.width / Airflow.period).rounded(.up)) + 1
            HStack(spacing: 0) {
                ForEach(0..<copies, id: \.self) { _ in
                    Image(nsImage: scheme == .dark ? Airflow.dark : Airflow.light)
                        .resizable()
                        .frame(width: Airflow.period, height: Airflow.height)
                }
            }
            .offset(x: -drift * Airflow.period)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .clipped()
            .mask(LinearGradient(stops: horizontalFade(width: proxy.size.width), startPoint: .leading, endPoint: .trailing))
            // Text that reaches far across leaves too little room for a ribbon to read; then there is none.
            .opacity(clearX.map { proxy.size.width - $0 >= 180 } ?? true ? 1 : 0)
        }
        .frame(height: height)
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.08),
                                     .init(color: .black, location: 0.36), .init(color: .clear, location: 0.48)],
                             startPoint: .top, endPoint: .bottom))
        .opacity(scheme == .dark ? 1 : 0.85)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear(perform: syncDrift)
        .onChange(of: reduceMotion) { syncDrift() }
    }

    /// Drifts while motion is allowed; turning Reduce Motion on stops it where it is.
    private func syncDrift() {
        if ambient, !reduceMotion {
            withAnimation(.linear(duration: 60).repeatForever(autoreverses: false)) { drift = 1 }
        } else {
            var still = Transaction(animation: nil)
            still.disablesAnimations = true
            withTransaction(still) { drift = 0 }
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
        // A Link takes the surrounding button style; the window's glass capsule would swallow it.
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
                    fill = polygon.color == 1 ? Air.ink : Air.markGreen
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
