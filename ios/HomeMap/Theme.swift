import SwiftUI

/// The Home Map look, same as the dashboard card: dark frosted-glass panels over the picture, one orange accent
/// (Home Assistant's primary color), blue only for editing, and light spring animations instead of popping.
enum Theme {
    static let accent = Color(red: 1.0, green: 0.62, blue: 0.04)          // HA primary orange
    static let onAccent = Color(red: 0.08, green: 0.07, blue: 0.04)
    static let blue = Color(red: 0.31, green: 0.55, blue: 1.0)
    static let red = Color(red: 1.0, green: 0.42, blue: 0.42)
    static let green = Color(red: 0.44, green: 0.83, blue: 0.61)
    static let text = Color(red: 0.93, green: 0.93, blue: 0.95)
    static let muted = Color(red: 0.61, green: 0.62, blue: 0.67)
    static let line = Color.white.opacity(0.08)
    static let raise = Color.white.opacity(0.07)
    static let spring = Animation.spring(response: 0.38, dampingFraction: 0.86)

    /// the dashboard's background: a soft light from the top
    static var background: some View {
        RadialGradient(colors: [Color(red: 0.19, green: 0.19, blue: 0.24), Color(red: 0.11, green: 0.11, blue: 0.13), Color(red: 0.08, green: 0.07, blue: 0.09)],
                       center: UnitPoint(x: 0.5, y: 0.12), startRadius: 0, endRadius: 700)
            .ignoresSafeArea()
    }
}

/// a frosted panel like the map's sheets: dark glass, a hairline edge, rounded corners
struct Glass: ViewModifier {
    var radius: CGFloat = 18
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .background(Color(red: 0.09, green: 0.09, blue: 0.12).opacity(0.55), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.line))
            .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
    }
}

extension View {
    func glass(_ radius: CGFloat = 18) -> some View { modifier(Glass(radius: radius)) }
}

/// buttons: orange (the main thing to do), glass (everything else), red text (destructive), blue (edit / done)
struct HMButton: ButtonStyle {
    enum Kind { case primary, secondary, danger, blue }
    var kind: Kind = .secondary
    var full = true
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(kind == .primary || kind == .blue ? .semibold : .medium))
            .lineLimit(1).minimumScaleFactor(0.8)
            .frame(maxWidth: full ? .infinity : nil, minHeight: 46)
            .padding(.horizontal, 14)
            .foregroundStyle(fg)
            .background(bg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(kind == .secondary || kind == .danger ? Theme.line : .clear))
            .opacity(enabled ? 1 : 0.38)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }

    private var fg: Color {
        switch kind { case .primary: return Theme.onAccent; case .blue: return .white; case .danger: return Theme.red; case .secondary: return Theme.text }
    }
    private var bg: AnyShapeStyle {
        switch kind {
        case .primary: return AnyShapeStyle(Theme.accent)
        case .blue: return AnyShapeStyle(LinearGradient(colors: [Theme.blue, Color(red: 0.18, green: 0.39, blue: 0.84)], startPoint: .topLeading, endPoint: .bottomTrailing))
        case .danger: return AnyShapeStyle(Theme.red.opacity(0.12))
        case .secondary: return AnyShapeStyle(Color.white.opacity(0.10))
        }
    }
}

/// a small round glass button (close, more)
struct RoundButton: View {
    let icon: String
    var label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                .frame(width: 38, height: 38)
                .glass(19)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// a capsule message: tips (glass), news (orange)
struct Capsule2: View {
    let text: String
    var icon: String? = nil
    var accent = false
    var body: some View {
        HStack(spacing: 7) {
            if let icon { Image(systemName: icon).foregroundStyle(accent ? Theme.onAccent : Theme.accent) }
            Text(text).multilineTextAlignment(.center)
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(accent ? Theme.onAccent : Theme.text)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background {
            if accent { Capsule().fill(Theme.accent) } else { Capsule().fill(.ultraThinMaterial).overlay(Capsule().strokeBorder(Theme.line)) }
        }
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
    }
}

/// a number tile like the map's Home facts
struct FactTile: View {
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(.white).contentTransition(.numericText())
            Text(label).font(.caption).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 13).padding(.vertical, 11)
        .background(LinearGradient(colors: [.white.opacity(0.08), .white.opacity(0.03)], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line))
    }
}

/// slide + fade in, like the map's panels
extension AnyTransition {
    static var rise: AnyTransition { .move(edge: .bottom).combined(with: .opacity) }
    static var drop: AnyTransition { .move(edge: .top).combined(with: .opacity) }
}
