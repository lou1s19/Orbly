import AppKit
import SwiftUI

enum OverlayPhase: Equatable {
    case recording
    case processing
    case error(String)
    /// Short "the app is running" greeting right after launch (check mark capsule).
    case ready
    /// A friendly note instead of an error, for example "please press again" after
    /// a wake-up press (see `WakeUpPress`).
    case hint(String, symbol: String)
}

enum OverlayStyle: String, CaseIterable {
    case pill        // small glass capsule
    case minimal     // 21st.dev "AI Voice Input": timer, fine bars, caption
    case orb         // 21st.dev "Voice Powered Orb": glowing sphere, reacts to the voice
    case orbMono     // the same orb, but monochrome (black and white)

    var size: CGSize {
        switch self {
        case .pill: return CGSize(width: 86, height: 28)
        case .minimal: return CGSize(width: 240, height: 78)
        case .orb, .orbMono: return CGSize(width: 76, height: 76)
        }
    }

    var barCount: Int {
        switch self {
        case .pill: return 10
        case .minimal: return 36
        case .orb, .orbMono: return 8
        }
    }
}

/// Where the overlay appears on screen.
enum OverlayPosition: String, CaseIterable {
    case bottomCenter
    case bottomLeft
    case bottomRight
    case topCenter
    case topRight

    var title: String {
        switch self {
        case .bottomCenter: return L10n.t("overlay.position.bottomCenter")
        case .bottomLeft: return L10n.t("overlay.position.bottomLeft")
        case .bottomRight: return L10n.t("overlay.position.bottomRight")
        case .topCenter: return L10n.t("overlay.position.topCenter")
        case .topRight: return L10n.t("overlay.position.topRight")
        }
    }
}

final class OverlayState: ObservableObject {
    @Published var levels: [Float] = []
    @Published var phase: OverlayPhase = .recording
    @Published var style: OverlayStyle = .pill
    @Published var startDate = Date()
    /// Among other things this controls pausing the Metal rendering when the panel is gone.
    @Published var overlayVisible = false
    /// The local server is loading the model right now (cold start after an idle
    /// shutdown), and the overlay pulses gently then.
    @Published var serverStarting = false

    func push(level: Float) {
        guard !levels.isEmpty else { return }
        levels.removeFirst()
        levels.append(level)
    }

    func reset(style: OverlayStyle) {
        self.style = style
        levels = Array(repeating: 0, count: style.barCount)
        phase = .recording
        startDate = Date()
    }
}

/// Remembers for this session that the orb style cannot be drawn (no Metal
/// device, the shader does not compile). In memory only, so the user's stored
/// choice stays untouched.
enum OverlayStyleFallback {
    static var orbUnavailable = false

    /// The style that can really be drawn.
    static func effective(_ style: OverlayStyle) -> OverlayStyle {
        guard orbUnavailable else { return style }
        return style == .orb || style == .orbMono ? .pill : style
    }
}

final class OverlayController {
    private let state = OverlayState()
    private var hideTimer: Timer?
    /// Invalidates running fade-outs when the overlay is shown again meanwhile.
    private var hideGeneration = 0

    private lazy var panel: NSPanel = {
        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: OverlayStyle.pill.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: OverlayRootView(state: state))
        return p
    }()

    func showRecording() {
        hideTimer?.invalidate()
        hideGeneration += 1
        state.reset(style: OverlayStyleFallback.effective(AppSettings.shared.overlayStyle))
        state.overlayVisible = true
        resizeAndPosition(state.style.size)
        // Fade in briefly instead of popping up hard (short enough to feel instant).
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func push(level: Float) {
        guard panel.isVisible, state.phase == .recording else { return }
        state.push(level: level)
    }

    func showProcessing() {
        state.phase = .processing
    }

    /// Gentle pulsing while the local server (the model) is still starting up.
    func setServerStarting(_ starting: Bool) {
        guard state.serverStarting != starting else { return }
        state.serverStarting = starting
    }

    /// A short note in the same capsule look as the startup greeting. Deliberately
    /// not shown as an error: nothing is broken, only a second press is missing.
    func showHint(_ message: String, symbol: String = "hand.tap.fill") {
        hideTimer?.invalidate()
        hideGeneration += 1
        state.phase = .hint(message, symbol: symbol)
        state.overlayVisible = true
        resizeAndPosition(CGSize(width: Self.hintWidth(for: message), height: 40))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        hideTimer = Timer.scheduledCommon(every: 2.6, repeats: false) { [weak self] _ in
            self?.hide()
        }
    }

    func showError(_ message: String) {
        state.phase = .error(message)
        state.overlayVisible = true
        hideGeneration += 1
        resizeAndPosition(CGSize(width: 300, height: 76))
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledCommon(every: 4.0, repeats: false) { [weak self] _ in
            self?.hide()
        }
    }

    /// Shows a check mark capsule ("Ready") briefly at app start, so it is visible
    /// that the app is running. Fades in, holds shortly, fades out again.
    func flashLaunched() {
        hideTimer?.invalidate()
        hideGeneration += 1
        state.phase = .ready
        state.overlayVisible = true
        resizeAndPosition(CGSize(width: 150, height: 36))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        hideTimer = Timer.scheduledCommon(every: 1.6, repeats: false) { [weak self] _ in
            self?.hide()
        }
    }

    func hide() {
        hideTimer?.invalidate()
        guard panel.isVisible else { return }
        hideGeneration += 1
        let gen = hideGeneration
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.hideGeneration == gen else { return }
            self.state.overlayVisible = false
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
        })
    }

    /// The capsule grows with the text, so the panel behind it has to grow along,
    /// otherwise `lineLimit(1)` cuts longer notes off.
    private static func hintWidth(for message: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let text = (message as NSString).size(withAttributes: [.font: font]).width
        // Symbol, the capsule's padding and a bit of air for the panel.
        return min(max(text + 90, 200), 620)
    }

    /// The screen the user is working on. Not `NSScreen.main`: that is "the screen
    /// with the key window", and a nonactivating panel never gets one. Without a
    /// key window macOS falls back to the menu bar screen, so on a second monitor
    /// the overlay appeared on the wrong one.
    private static var activeScreen: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func resizeAndPosition(_ size: CGSize) {
        guard let screen = Self.activeScreen else { return }
        let f = screen.visibleFrame
        let marginY: CGFloat = 28
        let marginX: CGFloat = 24

        let x: CGFloat
        let y: CGFloat
        switch AppSettings.shared.overlayPosition {
        case .bottomCenter:
            x = f.midX - size.width / 2
            y = f.minY + marginY
        case .bottomLeft:
            x = f.minX + marginX
            y = f.minY + marginY
        case .bottomRight:
            x = f.maxX - size.width - marginX
            y = f.minY + marginY
        case .topCenter:
            x = f.midX - size.width / 2
            y = f.maxY - size.height - marginY
        case .topRight:
            x = f.maxX - size.width - marginX
            y = f.maxY - size.height - marginY
        }
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }
}

// MARK: - Root view

struct OverlayRootView: View {
    @ObservedObject var state: OverlayState

    var body: some View {
        Group {
            // Draw nothing while the panel is gone. `orderOut` alone is not
            // enough: AppKit keeps serving a hidden window in the display
            // cycle, and `hide()` leaves `phase` at `.processing`. The dots
            // animation therefore kept running invisibly at 60 fps until the
            // app quit (measured: 13 % CPU while idle).
            if state.overlayVisible {
                if case .error(let msg) = state.phase {
                    ErrorView(message: msg)
                } else if case .hint(let msg, let symbol) = state.phase {
                    HintFlashView(message: msg, symbol: symbol)
                } else if state.phase == .ready {
                    ReadyFlashView()
                } else {
                    switch state.style {
                    case .pill: PillView(state: state)
                    case .minimal: MinimalView(state: state)
                    case .orb, .orbMono: OrbView(state: state)
                    }
                }
            }
        }
        .modifier(ServerStartingPulse(active: state.overlayVisible && state.serverStarting))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Soft fading in and out (breathing) while the local Whisper server starts up
/// again after an idle shutdown, so the user sees that something is starting.
private struct ServerStartingPulse: ViewModifier {
    let active: Bool
    @State private var dimmed = false

    func body(content: Content) -> some View {
        content
            .opacity(active && dimmed ? 0.45 : 1)
            .onChange(of: active) { _, on in
                if on {
                    withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                        dimmed = true
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.3)) { dimmed = false }
                }
            }
    }
}

// MARK: - Short messages (startup greeting, note)

/// Glass capsule with a symbol and one line of text. It grows with the text,
/// so the panel behind it may well be wider than the message.
struct CapsuleBadge: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(Color.white.opacity(0.92))
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background {
            ZStack {
                Capsule().fill(.ultraThinMaterial)
                Capsule().fill(Color.black.opacity(0.28))
                Capsule().strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.45), Color.white.opacity(0.08)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            }
        }
        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
    }
}

struct ReadyFlashView: View {
    var body: some View {
        CapsuleBadge(symbol: "checkmark.circle.fill", text: L10n.t("overlay.ready"))
    }
}

/// A short note, for example after a wake-up press or when the text could not
/// be pasted. Deliberately the same calm look as the startup greeting.
struct HintFlashView: View {
    let message: String
    var symbol: String = "hand.tap.fill"

    var body: some View {
        CapsuleBadge(symbol: symbol, text: message)
    }
}

// MARK: - Pill style (capsule with a border)

struct PillView: View {
    @ObservedObject var state: OverlayState

    private var processing: Bool { state.phase == .processing }

    var body: some View {
        ZStack {
            // Glass capsule: blur + dark veil + bright gradient border
            Capsule()
                .fill(.ultraThinMaterial)
            Capsule()
                .fill(Color.black.opacity(0.28))
            Capsule()
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.42), Color.white.opacity(0.07)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1
                )

            // Both states lie on top of each other and cross-fade (the bars
            // collapse into the line, the dots grow out of it). Swapping the
            // views hard looked choppy in this spot.
            ZStack {
                waveform
                    .opacity(processing ? 0 : 1)
                    .scaleEffect(processing ? 0.86 : 1)
                    .blur(radius: processing ? 2.5 : 0)

                ProcessingDotsView(color: .white, dotSize: 4.5, spacing: 4, active: processing)
                    .opacity(processing ? 1 : 0)
                    .scaleEffect(processing ? 1 : 0.86)
                    .blur(radius: processing ? 0 : 2.5)
            }
            .animation(.smooth(duration: 0.34), value: processing)
        }
        .frame(width: state.style.size.width, height: state.style.size.height)
        .shadow(color: .black.opacity(0.28), radius: 7, y: 2)
    }

    private var waveform: some View {
        HStack(spacing: 2.5) {
            ForEach(Array(state.levels.enumerated()), id: \.offset) { _, l in
                Capsule()
                    .fill(Color.white.opacity(0.92))
                    .frame(width: 2, height: barHeight(l))
            }
        }
        .animation(.easeOut(duration: 0.09), value: state.levels)
    }

    private func barHeight(_ level: Float) -> CGFloat {
        guard !processing else { return 2 }
        return 2 + CGFloat(min(max(level, 0), 1)) * 11
    }
}

// MARK: - Minimal style (after 21st.dev "AI Voice Input")

struct MinimalView: View {
    @ObservedObject var state: OverlayState

    var body: some View {
        VStack(spacing: 5) {
            TimelineView(.periodic(from: state.startDate, by: 1)) { context in
                Text(elapsedString(until: context.date))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.7))
            }

            if state.phase == .processing {
                SpinningSquareView()
                    .frame(height: 18)
            } else {
                HStack(spacing: 2) {
                    ForEach(Array(state.levels.enumerated()), id: \.offset) { i, l in
                        Capsule()
                            .fill(Color.primary.opacity(0.55))
                            .frame(width: 2, height: barHeight(level: l, index: i))
                    }
                }
                .frame(height: 18)
                .animation(.easeOut(duration: 0.1), value: state.levels)
            }

            Text(state.phase == .processing ? L10n.t("overlay.processing") : L10n.t("overlay.listening"))
                .font(.system(size: 10))
                .foregroundStyle(.primary.opacity(0.7))
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .frame(width: state.style.size.width, height: state.style.size.height)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
    }

    private func barHeight(level: Float, index: Int) -> CGFloat {
        // slight pseudo-random variation per bar, as in the original.
        // The types are explicit on purpose: without the CGFloat conversion the
        // expression mixes Double and CGFloat, which some Swift versions reject
        // as "ambiguous use of operator '*'" (it showed up in CI).
        let jitter = CGFloat(0.6 + 0.4 * abs(sin(Double(index) * 1.7)))
        return 2.5 + CGFloat(min(max(level, 0), 1)) * 15 * jitter
    }

    private func elapsedString(until date: Date) -> String {
        let s = max(0, Int(date.timeIntervalSince(state.startDate)))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

struct SpinningSquareView: View {
    @State private var spinning = false

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.primary.opacity(0.8))
            .frame(width: 14, height: 14)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 3).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}

// MARK: - Orb style (after 21st.dev "Voice Powered Orb", original shader via Metal)

struct OrbView: View {
    @ObservedObject var state: OverlayState

    var body: some View {
        OrbMetalView(state: state)
            .frame(width: state.style.size.width, height: state.style.size.height)
    }
}

// MARK: - Shared

struct ErrorView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(width: 300, height: 76)
            .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
    }
}

/// Three dots as a travelling wave. The motion comes from screen time
/// (TimelineView), not from `repeatForever` with a delay, so there is no jump
/// when fading in and out and the wave keeps running evenly.
struct ProcessingDotsView: View {
    var color: Color = .white
    var dotSize: CGFloat = 5
    var spacing: CGFloat = 4
    /// Pauses the time loop while the dots are not visible.
    var active: Bool = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !active)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: spacing) {
                ForEach(0..<3, id: \.self) { i in
                    let wave = (sin(t * 3.2 - Double(i) * 0.7) + 1) / 2   // 0...1
                    Circle()
                        .fill(color.opacity(0.5 + 0.45 * wave))
                        .frame(width: dotSize, height: dotSize)
                        .scaleEffect(0.65 + 0.35 * wave)
                        .offset(y: -1.5 * wave)
                }
            }
        }
    }
}
