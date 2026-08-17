import AppKit
import SwiftUI

enum OverlayPhase: Equatable {
    case recording
    case processing
    case error(String)
    /// Kurzer "App läuft"-Gruß direkt nach dem Start (Häkchen-Kapsel).
    case ready
    /// Freundlicher Hinweis statt Fehler, z. B. "bitte noch einmal drücken"
    /// nach einem Aufwachdruck (siehe `WakeUpPress`).
    case hint(String, symbol: String)
}

enum OverlayStyle: String, CaseIterable {
    case pill        // kleine Glas-Kapsel
    case minimal     // 21st.dev "AI Voice Input": Timer, feine Balken, Caption
    case orb         // 21st.dev "Voice Powered Orb": leuchtende Kugel, reagiert auf Stimme
    case orbMono     // derselbe Orb, aber monochrom (schwarz-weiß)

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

/// Wo das Overlay auf dem Bildschirm erscheint.
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
    /// Steuert u. a. das Pausieren des Metal-Renderings, wenn das Panel weg ist.
    @Published var overlayVisible = false
    /// Lokaler Server lädt gerade das Modell (Kaltstart nach Idle-Abschaltung) -
    /// das Overlay pulsiert dann sanft.
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

/// Merkt sich für diese Sitzung, dass der Orb-Stil nicht darstellbar ist (kein
/// Metal-Gerät, Shader lässt sich nicht kompilieren). Nur im Speicher, damit die
/// gespeicherte Wahl des Nutzers unangetastet bleibt.
enum OverlayStyleFallback {
    static var orbUnavailable = false

    /// Der Stil, der wirklich gezeichnet werden kann.
    static func effective(_ style: OverlayStyle) -> OverlayStyle {
        guard orbUnavailable else { return style }
        return style == .orb || style == .orbMono ? .pill : style
    }
}

final class OverlayController {
    private let state = OverlayState()
    private var hideTimer: Timer?
    /// Entwertet laufende Fade-outs, wenn das Overlay währenddessen neu gezeigt wird.
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
        // Kurz einblenden statt hart aufpoppen (kurz genug, um sofort zu wirken).
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

    /// Sanftes Pulsieren, solange der lokale Server (Modell) noch hochfährt.
    func setServerStarting(_ starting: Bool) {
        guard state.serverStarting != starting else { return }
        state.serverStarting = starting
    }

    /// Kurzer Hinweis in derselben Kapsel-Optik wie der Start-Gruß. Bewusst nicht
    /// als Fehler dargestellt: Es ist nichts kaputt, es fehlt nur ein zweiter Druck.
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

    /// Zeigt beim App-Start kurz eine Häkchen-Kapsel ("Bereit"), damit sichtbar
    /// ist, dass die App läuft - blendet ein, hält kurz, blendet wieder aus.
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

    /// Die Kapsel wächst mit dem Text, das Panel dahinter muss mitwachsen -
    /// sonst schneidet `lineLimit(1)` längere Hinweise ab.
    private static func hintWidth(for message: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let text = (message as NSString).size(withAttributes: [.font: font]).width
        // Symbol, Innenabstände der Kapsel und etwas Luft fürs Panel.
        return min(max(text + 90, 200), 620)
    }

    /// Der Bildschirm, auf dem der Nutzer gerade arbeitet. Nicht `NSScreen.main`:
    /// das ist "der Bildschirm mit dem Key-Window", und ein nonactivating panel
    /// bekommt nie eins. Ohne Key-Window fällt macOS auf den Menüleisten-Bildschirm
    /// zurück, das Overlay erschien dann am Zweitmonitor auf dem falschen Schirm.
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
            // Nichts zeichnen, solange das Panel weg ist. `orderOut` allein
            // genügt nicht: AppKit bedient ein verstecktes Fenster weiter im
            // Display-Zyklus, und `hide()` lässt `phase` auf `.processing`
            // stehen. Die Punkte-Animation lief dadurch unsichtbar mit 60 fps
            // bis zum Beenden der App weiter (gemessen: 13 % CPU im Leerlauf).
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

/// Weiches Ein-/Aus-Faden (Atmen), solange der lokale Whisper-Server nach einer
/// Idle-Abschaltung neu hochfährt - der Nutzer sieht so: "da startet gerade was".
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

// MARK: - Kurzmeldungen (Start-Gruß, Hinweis)

/// Glas-Kapsel mit Symbol und einer Zeile Text. Wächst mit dem Text, deshalb
/// darf das Panel dahinter ruhig breiter sein als die Meldung.
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

/// Kurzer Hinweis, z. B. nach einem Aufwachdruck oder wenn der Text nicht
/// eingefügt werden konnte. Absichtlich dieselbe ruhige Optik wie der Start-Gruß.
struct HintFlashView: View {
    let message: String
    var symbol: String = "hand.tap.fill"

    var body: some View {
        CapsuleBadge(symbol: symbol, text: message)
    }
}

// MARK: - Pill style (Kapsel mit Rahmen)

struct PillView: View {
    @ObservedObject var state: OverlayState

    private var processing: Bool { state.phase == .processing }

    var body: some View {
        ZStack {
            // Glas-Kapsel: Blur + dunkler Schleier + heller Verlaufs-Rand
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

            // Beide Zustände liegen übereinander und werden ineinander geblendet
            // (Balken sacken zur Linie zusammen, Punkte wachsen heraus). Ein
            // hartes Austauschen der Views wirkte an dieser Stelle abgehackt.
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

// MARK: - Minimal style (nach 21st.dev "AI Voice Input")

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
        // leichte Pseudo-Zufalls-Variation pro Balken wie in der Vorlage.
        // Typen bewusst explizit: Ohne CGFloat-Umwandlung mischt der Ausdruck
        // Double und CGFloat, was manche Swift-Versionen als "ambiguous use of
        // operator '*'" ablehnen (in der CI aufgefallen).
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

// MARK: - Orb style (nach 21st.dev "Voice Powered Orb", Original-Shader via Metal)

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

/// Drei Punkte als laufende Welle. Die Bewegung kommt aus der Bildschirmzeit
/// (TimelineView), nicht aus `repeatForever` mit Delay - dadurch gibt es beim
/// Ein- und Ausblenden keinen Sprung, und die Welle läuft gleichmäßig weiter.
struct ProcessingDotsView: View {
    var color: Color = .white
    var dotSize: CGFloat = 5
    var spacing: CGFloat = 4
    /// Pausiert die Zeitschleife, solange die Punkte nicht sichtbar sind.
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
