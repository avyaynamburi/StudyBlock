import AppKit
import SwiftUI

// MARK: - Palette

/// StudyBlock's design system: matte neutral greys, flat fills, hairline
/// strokes. There are no gradients and no coloured glows anywhere — depth
/// comes from a surface stepping one shade off its background and a 1px
/// stroke, the way a well-behaved developer tool does it.
///
/// The greys are deliberately *neutral* (equal R/G/B). The palette this
/// replaced tinted every surface indigo, which is what made the app read as
/// decorated rather than built.
enum Theme {
    // Planes — four steps of neutral grey, each one shade off the last.
    static let bg = Color(light: 0xF4F4F5, dark: 0x131313)
    static let sidebar = Color(light: 0xEDEDEE, dark: 0x171717)
    static let surface = Color(light: 0xFFFFFF, dark: 0x1E1E1E)
    static let surfaceLow = Color(light: 0xEFEFF0, dark: 0x262626)
    static let stroke = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.10, darkAlpha: 0.10)

    /// One restrained steel blue, desaturated enough to sit inside a grey UI
    /// without shouting. It marks state — on, selected, due — and nothing
    /// else, so a screen has at most a few square centimetres of colour.
    static let accent = Color(light: 0x40607C, dark: 0x8CA9C4)
    /// Flat fill for a control that is switched on — a filled button, a live
    /// toggle track, a ticked checkbox. Named for what it does rather than how
    /// it's drawn, so it can never quietly become a gradient again.
    ///
    /// Deliberately *darker* than `accent` in dark mode rather than lighter.
    /// Everything drawn on this fill is white, and the lighter shade `accent`
    /// uses for text reached only 2.97:1 behind white — this one is 5.58:1.
    static let accentFill = Color(light: 0x40607C, dark: 0x4A6B8A)
    static let accentSoft = Color(light: 0x40607C, dark: 0x8CA9C4, lightAlpha: 0.12, darkAlpha: 0.16)

    // Semantic — muted to the same matte level as the accent.
    static let success = Color(light: 0x3D7048, dark: 0x7FAC89)
    static let successSoft = Color(light: 0x3D7048, dark: 0x7FAC89, lightAlpha: 0.12, darkAlpha: 0.15)
    static let amber = Color(light: 0x87652C, dark: 0xC2A165)
    static let amberSoft = Color(light: 0x87652C, dark: 0xC2A165, lightAlpha: 0.13, darkAlpha: 0.14)
    static let danger = Color(light: 0x9C4B4B, dark: 0xC08585)
    static let dangerSoft = Color(light: 0x9C4B4B, dark: 0xC08585, lightAlpha: 0.12, darkAlpha: 0.15)
    /// Kept for the confetti mix, muted to match the rest.
    static let violet = Color(light: 0x5E5470, dark: 0xA79CB8)

    /// Evenly spaced hues (0..<360) offered by the category color picker.
    /// Saturation is held low by `categoryPastel`/`categoryInk` so a category
    /// still reads as a distinct colour without breaking the matte surface.
    static let categoryHueSteps: [Double] = stride(from: 0, to: 360, by: 30).map { $0 }

    /// The `index`-th hue to hand a category that hasn't got one, walking the
    /// colour wheel so that categories created one after another come out as
    /// far apart as the wheel allows.
    ///
    /// The first twelve are exactly `categoryHueSteps`, in the order
    /// 0°, 150°, 300°, 90°, … — a 150° stride. Five steps at a time has one
    /// property worth the arithmetic: 150 and 360 share a factor of 30, so
    /// the walk lands on all twelve stops before it revisits any of them,
    /// while no two consecutive categories are neighbours on the wheel. A
    /// plain +30° walk would hand the first three courses three shades of
    /// red, which is the failure this exists to avoid.
    ///
    /// Past twelve it starts again, offset half a step (15°), then a quarter
    /// (7.5°), each round bisecting the gaps left by the last. Colours get
    /// closer together the further out you go — unavoidable on a wheel with
    /// no room left — but they never repeat, and a board would need a
    /// forty-ninth category before two were genuinely hard to tell apart.
    static func categoryHue(index: Int) -> Double {
        let n = max(0, index)
        let stops = categoryHueSteps.count
        let round = n / stops
        // Exactly representable in binary (30, 15, 7.5, 3.75 …), so a hue
        // handed out here compares equal to itself after a save and reload,
        // and `==` against the picker's stops is safe.
        let offset = round == 0 ? 0 : 30 / pow(2, Double(round))
        let base = Double(n % stops) * 150
        return (base + offset).truncatingRemainder(dividingBy: 360)
    }

    /// The swatch shown in the category color picker itself — desaturated to
    /// sit against grey rather than glow off it.
    static func categoryPastel(hue: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hue: hue / 360, saturation: 0.20, brightness: isDark ? 0.36 : 0.93, alpha: 1)
        })
    }

    /// The same hue, deepened for use as text/icon color (on top of its own
    /// `.opacity(0.14)` tint in `TagChip`) so category labels stay legible.
    /// The ink a category is written in — the tag chip's text, and the 13%
    /// wash behind it.
    ///
    /// Held a step dimmer than a category colour naturally wants to be. A
    /// board is mostly tag chips, and at full strength a dozen of them turn
    /// the surface into a colour chart. Dark mode still clears 5:1 against
    /// `surface`; light mode gets *more* contrast by going darker, not less.
    static func categoryInk(hue: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            // 0.70 in dark is the floor, not a taste call: below it the blue
            // hues drop under 4.5:1 against `surface` and the chip text stops
            // being readable.
            return NSColor(hue: hue / 360, saturation: isDark ? 0.28 : 0.38,
                           brightness: isDark ? 0.70 : 0.43, alpha: 1)
        })
    }

    /// The border on a task that is coming due: `t` of 0 is a week or more
    /// out, 1 is due now or already overdue.
    ///
    /// One hue the whole way — red — with only its strength moving, and not
    /// by much. A deadline you notice when you look for it, rather than a
    /// traffic light sitting on the board. This replaced a yellow → orange →
    /// red sweep at saturation 0.82 and brightness 0.92, which was both the
    /// last gradient in the app and the only thing on a task that glowed.
    static func urgency(_ t: Double) -> Color {
        let amount = min(1, max(0, t))
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            // Ends near `danger` so an overdue card and a danger control are
            // recognisably the same red.
            let saturation = isDark ? 0.20 + 0.14 * amount : 0.26 + 0.26 * amount
            let brightness = isDark ? 0.50 + 0.24 * amount : 0.72 - 0.11 * amount
            return NSColor(hue: 0, saturation: saturation, brightness: brightness, alpha: 1)
        })
    }

    // Typography
    // MARK: - Type

    /// The app's UI face. Helvetica Neue is a neutral grotesque — flatter and
    /// quieter at small sizes than the system font's humanist shapes — and
    /// it ships on every Mac. `Font.custom` falls back to the system font if
    /// it somehow isn't there, so this can't render nothing.
    ///
    /// Every size in the app goes through here, so swapping the face is a
    /// one-line change: put `.system(size:weight:)` in the body below.
    static let uiFace = "Helvetica Neue"

    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(uiFace, fixedSize: size).weight(weight)
    }

    /// Figures — monospaced digits so a counting timer doesn't jitter.
    static func number(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        ui(size, weight).monospacedDigit()
    }

    /// Code, CSV and the unlock challenge, where character shapes have to be
    /// unambiguous. Stays on the system monospace face.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension Color {
    /// Adaptive color from light/dark hex values via a dynamic NSColor.
    init(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

// MARK: - Sections

/// A page section. Deliberately *not* a box: sections share the page's own
/// background and are told apart by a heading and by space, so a screen reads
/// as one continuous surface rather than a stack of floating panels.
///
/// The bordered, filled, drop-shadowed card this replaced is what made every
/// page look like several small apps pinned to a board.
private struct SectionModifier: ViewModifier {
    var padding: CGFloat

    func body(content: Content) -> some View {
        content
            // No horizontal inset: that padding existed to hold content off a
            // card border, and there is no border now. What's kept is a little
            // vertical rhythm, scaled from whatever the section asked for.
            .padding(.vertical, padding == 0 ? 0 : max(6, padding * 0.4))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    func card(padding: CGFloat = 20) -> some View { modifier(SectionModifier(padding: padding)) }

    /// A hairline rule between sections — the only thing separating them now
    /// that they no longer sit in boxes.
    func sectionDivider() -> some View {
        VStack(spacing: 0) {
            self
            Divider().overlay(Theme.stroke).padding(.top, 16)
        }
    }
}

// MARK: - Page scaffolding

/// Big page header used at the top of every section (replaces navigationTitle).
struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Theme.ui(26, .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.ui(12))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            trailing
        }
        .padding(.top, 28)
        .padding(.horizontal, 28)
        .padding(.bottom, 14)
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    var message: String?

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(Theme.accentSoft).frame(width: 64, height: 64)
                Image(systemName: icon)
                    .font(Theme.ui(26, .medium))
                    .foregroundStyle(Theme.accent)
            }
            Text(title).font(Theme.ui(13, .semibold))
            if let message {
                Text(message)
                    .font(Theme.ui(12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

// MARK: - Chips

struct TagChip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(Theme.ui(10, .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
    }
}

// MARK: - Button styles

/// The one prominent action per screen: a flat accent fill, no glow, and a
/// press state carried by shade rather than by scale.
struct ProminentPillButtonStyle: ButtonStyle {
    var size: ControlSize = .regular

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 4, style: .continuous) }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(size == .large ? .body.weight(.semibold) : .callout.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, size == .large ? 18 : 13)
            .padding(.vertical, size == .large ? 9 : 6)
            .background(Theme.accentFill.opacity(configuration.isPressed ? 0.80 : 1), in: shape)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(shape)
    }
}

/// Quiet button on the low surface — secondary actions.
struct SoftPillButtonStyle: ButtonStyle {
    var tint: Color?

    @State private var hovering = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 4, style: .continuous) }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.ui(12, .medium))
            .foregroundStyle(tint ?? .primary)
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
            .background(background(pressed: configuration.isPressed), in: shape)
            .overlay(shape.strokeBorder(Theme.stroke, lineWidth: 1))
            .animation(.easeOut(duration: 0.12), value: hovering)
            .contentShape(shape)
            .onHover { hovering = $0 }
    }

    private func background(pressed: Bool) -> Color {
        if let tint { return tint.opacity(pressed ? 0.20 : (hovering ? 0.14 : 0.09)) }
        return Theme.surfaceLow.opacity(pressed ? 0.7 : (hovering ? 1 : 0.85))
    }
}

/// Bare icon button that gains a soft circle on hover.
struct IconButtonStyle: ButtonStyle {
    var tint: Color = .secondary

    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(hovering ? Color.primary : tint)
            .padding(5)
            .background(RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(hovering ? Theme.surfaceLow : .clear))
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .contentShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .onHover { hovering = $0 }
    }
}

// MARK: - Toggle styles

/// Flat switch: the track takes a solid accent fill when on. Named "Glow"
/// from when it had one; the name is kept only because it's used in a dozen
/// files, and there is nothing glowing about it now.
struct GlowToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack {
                configuration.label
                Spacer()
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(configuration.isOn ? Theme.accentFill : Theme.surfaceLow)
                        .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))
                        .frame(width: 42, height: 24)
                    Circle()
                        .fill(configuration.isOn ? .white : Color.secondary.opacity(0.75))
                        .frame(width: 18, height: 18)
                        .padding(3)
                }
                .animation(.spring(response: 0.25, dampingFraction: 0.75), value: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Custom checkbox: rounded square, gradient check when on.
struct CheckToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(configuration.isOn ? Theme.accentFill : Theme.surfaceLow)
                        .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(configuration.isOn ? .clear : Theme.stroke, lineWidth: 1))
                        .frame(width: 17, height: 17)
                    if configuration.isOn {
                        Image(systemName: "checkmark")
                            .font(Theme.ui(10, .semibold))
                            .foregroundStyle(.white)
                    }
                }
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isOn)
    }
}

// MARK: - Flow layout (for domain chips)

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (subview, position) in zip(subviews, result.positions) {
            subview.place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                          proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, totalWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            totalWidth = max(totalWidth, x - spacing)
        }
        return (CGSize(width: totalWidth, height: y + rowHeight), positions)
    }
}
