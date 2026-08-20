import SwiftUI

// MARK: - Look of the first-run tour
//
// The tour deliberately has its own, always dark look (independent of the
// system appearance): a calm night sky as the background, dark cards on top,
// large typography, a white capsule button as the only bright spot.
// The rest of the app stays with the light/dark glass look from Dashboard.swift.

enum OB {
    static let radius: CGFloat = 18
    static let cardFill = Color.black.opacity(0.28)
    static let title = Color.white
    static let text = Color.white.opacity(0.56)
    static let faint = Color.white.opacity(0.3)

    /// Bright gradient border like the glass cards of the app, tuned darker.
    static let stroke = LinearGradient(
        colors: [Color.white.opacity(0.13), Color.white.opacity(0.04)],
        startPoint: .top, endPoint: .bottom
    )
}

extension View {
    /// Dark card on the night sky.
    func obCard(padding: CGFloat = 20, radius: CGFloat = OB.radius) -> some View {
        self
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(OB.cardFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(OB.stroke, lineWidth: 1)
                    )
            )
    }
}

// MARK: - Background

/// Night sky: a dark gradient with three soft lights that drift very slowly.
/// Computed rather than shipped as an image on purpose: it scales to any
/// window size and stays a few kilobytes instead of a few megabytes.
struct NightSky: View {
    /// "Reduce motion" in the accessibility settings: the background stands still.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            // 15 frames per second is enough: the lights need 40 to 70 seconds for
            // one round, redrawing faster would be a pure waste of energy.
            TimelineView(.animation(minimumInterval: 1.0 / 15.0, paused: reduceMotion)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                ZStack {
                    LinearGradient(
                        colors: [
                            Color(red: 0.086, green: 0.102, blue: 0.145),
                            Color(red: 0.035, green: 0.043, blue: 0.063),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )

                    glow(Color.white.opacity(0.07), size: w * 1.3,
                         x: w * 0.52 + drift(t, 41, w * 0.05),
                         y: h * 0.00 + drift(t, 57, h * 0.06))
                    glow(Color.accentColor.opacity(0.20), size: w * 0.95,
                         x: w * 0.16 + drift(t, 63, w * 0.06),
                         y: h * 0.95 + drift(t, 47, h * 0.05))
                    glow(Color(red: 0.29, green: 0.36, blue: 0.55).opacity(0.28), size: w * 0.9,
                         x: w * 0.94 + drift(t, 71, w * 0.05),
                         y: h * 0.34 + drift(t, 53, h * 0.06))

                    RadialGradient(
                        colors: [Color.clear, Color.black.opacity(0.45)],
                        center: .center,
                        startRadius: min(w, h) * 0.3,
                        endRadius: max(w, h) * 0.75
                    )
                }
            }
        }
        .ignoresSafeArea()
    }

    private func glow(_ color: Color, size: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        RadialGradient(
            gradient: Gradient(stops: [
                .init(color: color, location: 0),
                .init(color: color.opacity(0.35), location: 0.45),
                .init(color: color.opacity(0), location: 1),
            ]),
            center: .center, startRadius: 0, endRadius: size / 2
        )
        .frame(width: size, height: size)
        .position(x: x, y: y)
        .blendMode(.plusLighter)
    }

    private func drift(_ t: Double, _ period: Double, _ amount: CGFloat) -> CGFloat {
        CGFloat(sin(t / period * 2 * .pi)) * amount
    }
}

// MARK: - Building blocks

/// Symbol in a rounded glass tile (the head of every page).
struct IconTile: View {
    let symbol: String
    var size: CGFloat = 58

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.4, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.95))
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.15), Color.white.opacity(0.05)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }
}

/// Head of a page: tile, title, one sentence of explanation, centered.
struct PageHeader: View {
    var icon: String?
    let title: String
    let subtitle: String
    var maxWidth: CGFloat = 540

    var body: some View {
        VStack(spacing: 16) {
            if let icon {
                IconTile(symbol: icon)
            }
            Text(title)
                .font(.system(size: 33, weight: .bold))
                .tracking(-0.5)
                .foregroundStyle(OB.title)
                .multilineTextAlignment(.center)
            Text(.init(subtitle))
                .font(.system(size: 16))
                .foregroundStyle(OB.text)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: maxWidth)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// White capsule, the only bright button of the tour, always bottom right.
struct PrimaryPillButton: View {
    let title: String
    var systemImage: String? = "arrow.right"
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 14, weight: .semibold))
                        .offset(x: hovering ? 3 : 0)
                }
            }
            .foregroundStyle(Color.black.opacity(0.88))
            .padding(.horizontal, 26)
            .frame(height: 48)
            .background(Capsule().fill(Color.white.opacity(hovering ? 1 : 0.93)))
            .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
    }
}

/// Outlined capsule for secondary actions ("Allow", "Download").
struct GhostPillButton: View {
    let title: String
    var systemImage: String?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            GhostPillLabel(title: title, systemImage: systemImage, strong: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
    }
}

/// Same capsule but without a click, showing a state reached ("Granted").
struct GhostPillLabel: View {
    let title: String
    var systemImage: String?
    var strong = false

    var body: some View {
        HStack(spacing: 7) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
            }
            Text(title)
                .font(.system(size: 14, weight: .medium))
        }
        .foregroundStyle(Color.white.opacity(strong ? 1 : 0.85))
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background(
            Capsule()
                .fill(Color.white.opacity(strong ? 0.12 : 0.06))
                .overlay(Capsule().strokeBorder(Color.white.opacity(strong ? 0.28 : 0.16), lineWidth: 1))
        )
    }
}

/// Back/skip: text only, very restrained.
struct QuietButton: View {
    let title: String
    var systemImage: String?
    var size: CGFloat = 14
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: size - 2, weight: .medium))
                }
                Text(title).font(.system(size: size))
            }
            .foregroundStyle(Color.white.opacity(hovering ? 0.9 : 0.45))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
    }
}

/// Progress as dots, the current step as a wider bar.
struct StepDots: View {
    let count: Int
    let index: Int

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(Color.white.opacity(i == index ? 0.9 : 0.22))
                    .frame(width: i == index ? 26 : 6, height: 6)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: index)
    }
}

/// Check mark in an accent circle with text (list of benefits).
struct CheckItem: View {
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor))
            Text(text)
                .font(.system(size: 14.5))
                .foregroundStyle(Color.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Card with tile, title and one line of explanation, centered, for rows of three.
struct FeatureCard: View {
    let icon: String
    let title: String
    let text: String

    var body: some View {
        VStack(spacing: 12) {
            IconTile(symbol: icon, size: 46)
            Text(title)
                .font(.system(size: 15.5, weight: .semibold))
                .foregroundStyle(OB.title)
                .multilineTextAlignment(.center)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(OB.text)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        // maxHeight together with fixedSize on the row makes all cards next to
        // each other equally tall, even with texts of different lengths.
        // langen Texten.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.vertical, 22)
        .padding(.horizontal, 14)
        .obCard(padding: 0)
    }
}

/// Row in a card: symbol, title, explanation, an action on the right.
struct OBRow<Trailing: View>: View {
    let icon: String
    let title: String
    let hint: String
    var done = false
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: done ? "checkmark" : icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(done ? Color.accentColor : Color.white.opacity(0.7))
                .frame(width: 30, height: 30)
                .background(
                    Circle().fill(done ? Color.accentColor.opacity(0.18) : Color.white.opacity(0.07))
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(OB.title)
                Text(.init(hint))
                    .font(.system(size: 13))
                    .foregroundStyle(OB.text)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 10)
            trailing
        }
    }
}

extension OBRow where Trailing == EmptyView {
    init(icon: String, title: String, hint: String, done: Bool = false) {
        self.init(icon: icon, title: title, hint: hint, done: done) { EmptyView() }
    }
}

/// Key cap ("fn", "esc") in the style of a real key.
struct OBKeyCap: View {
    let label: String
    var wide = false

    var body: some View {
        Text(label)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.95))
            .frame(minWidth: wide ? 44 : 32, minHeight: 30)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.16), Color.white.opacity(0.07)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                    )
            )
    }
}

/// Thin separator inside a card.
struct OBDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 1)
    }
}
