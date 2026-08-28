import AppKit
import SwiftUI

// MARK: - Palette

/// StudyBlock's design system. One signature indigo→violet gradient, deep
/// indigo-tinted dark surfaces, warm paper light mode, hairline strokes.
/// Chart/accent hues validated for contrast on both card surfaces
/// (light #5B5BD6 on #FFFFFF, dark #7C7CF0 on #1C1C2A).
enum Theme {
    // Planes
    static let bg = Color(light: 0xF2F1F7, dark: 0x0E0E16)
    static let sidebar = Color(light: 0xEAE9F2, dark: 0x12121C)
    static let surface = Color(light: 0xFFFFFF, dark: 0x1C1C2A)
    static let surfaceLow = Color(light: 0xF3F2F8, dark: 0x242436)
    static let stroke = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.07, darkAlpha: 0.08)

    // Signature accent
    static let accent = Color(light: 0x5B5BD6, dark: 0x7C7CF0)
    static let violet = Color(light: 0x8B5CF6, dark: 0xA78BFA)
    static let accentSoft = Color(light: 0x5B5BD6, dark: 0x7C7CF0, lightAlpha: 0.12, darkAlpha: 0.18)

    // Semantic
    static let success = Color(light: 0x1F9D55, dark: 0x3DCB82)
    static let successSoft = Color(light: 0x1F9D55, dark: 0x3DCB82, lightAlpha: 0.13, darkAlpha: 0.16)
    static let amber = Color(light: 0xA16207, dark: 0xF0B33C)
    static let amberSoft = Color(light: 0xD9A425, dark: 0xF0B33C, lightAlpha: 0.16, darkAlpha: 0.14)
    static let danger = Color(light: 0xCE4444, dark: 0xF07070)
    static let dangerSoft = Color(light: 0xCE4444, dark: 0xF07070, lightAlpha: 0.12, darkAlpha: 0.15)

    static var accentGradient: LinearGradient {
        LinearGradient(colors: [accent, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Evenly spaced hues (0..<360) offered by the category color picker.
    /// Saturation/brightness are fixed by `categoryPastel`/`categoryInk`, so
    /// every swatch reads as a soft pastel — never neon, never dark.
    static let categoryHueSteps: [Double] = stride(from: 0, to: 360, by: 30).map { $0 }

    /// The swatch shown in the category color picker itself — pale and
    /// gentle, so nothing selectable there can read as "too bright."
    static func categoryPastel(hue: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hue: hue / 360, saturation: isDark ? 0.30 : 0.30, brightness: isDark ? 0.34 : 0.95, alpha: 1)
        })
    }

    /// The same hue, deepened for use as text/icon color (on top of its own
    /// `.opacity(0.14)` tint in `TagChip`) so category labels stay legible.
    static func categoryInk(hue: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hue: hue / 360, saturation: isDark ? 0.45 : 0.62, brightness: isDark ? 0.80 : 0.52, alpha: 1)
        })
    }

    // Typography
    static func number(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
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

// MARK: - Card

private struct CardModifier: ViewModifier {
    var padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
            .shadow(color: .black.opacity(0.10), radius: 16, y: 6)
    }
}

extension View {
    func card(padding: CGFloat = 20) -> some View { modifier(CardModifier(padding: padding)) }
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
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
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
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            Text(title).font(.headline)
            if let message {
                Text(message)
                    .font(.callout)
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
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
    }
}

// MARK: - Button styles

/// Filled gradient pill — the one prominent action per screen.
struct ProminentPillButtonStyle: ButtonStyle {
    var size: ControlSize = .regular

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(size == .large ? .body.weight(.semibold) : .callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, size == .large ? 20 : 14)
            .padding(.vertical, size == .large ? 10 : 7)
            .background(Theme.accentGradient, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
            .shadow(color: Theme.accent.opacity(configuration.isPressed ? 0.1 : 0.35),
                    radius: configuration.isPressed ? 4 : 10, y: 3)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// Quiet pill on the low surface — secondary actions.
struct SoftPillButtonStyle: ButtonStyle {
    var tint: Color?

    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(tint ?? .primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background((tint?.opacity(hovering ? 0.18 : 0.12) ?? Theme.surfaceLow.opacity(hovering ? 1 : 0.8)), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
            .contentShape(Capsule())
            .onHover { hovering = $0 }
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
            .background(Circle().fill(hovering ? Theme.surfaceLow : .clear))
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .contentShape(Circle())
            .onHover { hovering = $0 }
    }
}

// MARK: - Toggle styles

/// Custom switch: capsule with gradient fill when on.
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
                        .fill(configuration.isOn ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.surfaceLow))
                        .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))
                        .frame(width: 46, height: 27)
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                        .frame(width: 21, height: 21)
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
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(configuration.isOn ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.surfaceLow))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(configuration.isOn ? .clear : Theme.stroke, lineWidth: 1))
                        .frame(width: 17, height: 17)
                    if configuration.isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
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
