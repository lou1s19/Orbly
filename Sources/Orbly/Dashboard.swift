import SwiftUI
import Charts

// MARK: - Hauptfenster: Glas-Look, Hover-Sidebar links, Inhalt rechts

enum MainTab: String, CaseIterable {
    case overview
    case history
    case settings

    var title: String {
        switch self {
        case .overview: return L10n.t("tab.overview.title")
        case .history: return L10n.t("tab.history.title")
        case .settings: return L10n.t("tab.settings.title")
        }
    }

    var subtitle: String {
        switch self {
        case .overview: return L10n.t("tab.overview.subtitle")
        case .history: return L10n.t("tab.history.subtitle")
        case .settings: return L10n.t("tab.settings.subtitle")
        }
    }

    var icon: String {
        switch self {
        case .overview: return "chart.xyaxis.line"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }
}

final class MainWindowState: ObservableObject {
    @Published var tab: MainTab = .overview
}

/// Echter Hinter-Fenster-Blur (Glassmorphism-Basis).
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
    }
}

struct MainWindowView: View {
    @ObservedObject var state: MainWindowState
    /// Liefert die PID des lokalen whisper-server, solange er läuft.
    let serverPid: () -> pid_t?

    /// Sidebar klappt bei Hover auf (wie die Aceternity-Vorlage).
    @State private var sidebarExpanded = false

    private let sidebarCollapsed: CGFloat = 64
    private let sidebarWide: CGFloat = 200

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            sidebar
            content
        }
        .frame(width: 800, height: 560)
        .background(VisualEffect(material: .sidebar).ignoresSafeArea())
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Platz für die Ampel-Buttons (Titelleiste ist transparent)
            Color.clear.frame(height: 44)

            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                if sidebarExpanded {
                    Text("Orbly")
                        .font(.headline)
                        .fixedSize()
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: sidebarExpanded ? .leading : .center)
            .padding(.horizontal, sidebarExpanded ? 22 : 0)

            VStack(spacing: 3) {
                ForEach(MainTab.allCases, id: \.self) { tab in
                    SidebarNavItem(
                        tab: tab,
                        selected: state.tab == tab,
                        expanded: sidebarExpanded
                    ) {
                        withAnimation(.easeOut(duration: 0.22)) {
                            state.tab = tab
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 24)

            Spacer()

            SidebarMemoryView(serverPid: serverPid, expanded: sidebarExpanded)
                .padding(.horizontal, 12)
                .padding(.bottom, 14)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .frame(width: sidebarExpanded ? sidebarWide : sidebarCollapsed, alignment: .leading)
        .clipped()
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                sidebarExpanded = hovering
            }
        }
    }

    // MARK: Inhalt

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(state.tab.title)
                    .font(.title2.bold())
                Text(state.tab.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 26)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)

            ZStack {
                switch state.tab {
                case .overview:
                    ScrollView(showsIndicators: false) {
                        DashboardView()
                            .padding(.horizontal, 24)
                            .padding(.bottom, 24)
                    }
                case .history:
                    HistoryView()
                case .settings:
                    ScrollView(showsIndicators: false) {
                        SettingsView()
                            .padding(.horizontal, 24)
                            .padding(.bottom, 24)
                    }
                }
            }
            .id(state.tab)
            .transition(.opacity.combined(with: .offset(y: 8)))
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 18, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.62))
                .overlay(
                    UnevenRoundedRectangle(topLeadingRadius: 18, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.22), Color.white.opacity(0.04)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                )
                .ignoresSafeArea()
        )
        .padding(.top, 10)
    }
}

// MARK: - Sidebar-Navigation mit Hover-Animation

private struct SidebarNavItem: View {
    let tab: MainTab
    let selected: Bool
    let expanded: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: tab.icon)
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                    .frame(width: 20)
                // Eingeklappt den Text ganz weglassen - unsichtbar überstehende
                // Labels ziehen sonst die Auswahl-Box bis an den Rand.
                if expanded {
                    Text(tab.title)
                        .font(.callout.weight(selected ? .semibold : .regular))
                        .lineLimit(1)
                        .fixedSize()
                        // Der kleine Versatz nach rechts beim Hovern ist das
                        // "group-hover:translate-x-1" der Vorlage.
                        .offset(x: hovered ? 3 : 0)
                        .transition(.opacity)
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: expanded ? .leading : .center)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected
                          ? Color.accentColor.opacity(0.16)
                          : hovered ? Color.primary.opacity(0.06) : .clear)
            )
            .foregroundStyle(selected ? Color.accentColor : Color.primary.opacity(0.75))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        // Eingeklappt ist das der Standardzustand und der Text fehlt strukturell -
        // ohne Label wären die drei Hauptknöpfe für VoiceOver namenlos.
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onHover { h in
            withAnimation(.easeOut(duration: 0.15)) { hovered = h }
        }
    }
}

// MARK: - RAM-Anzeige (Sidebar-Fuß)

private struct SidebarMemoryView: View {
    let serverPid: () -> pid_t?
    let expanded: Bool

    @State private var appMemory: UInt64?
    @State private var serverMemory: UInt64?
    private let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "memorychip")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                if expanded {
                    Text(L10n.t("dashboard.ram.title"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: expanded ? .leading : .center)
            // Eingeklappt bleibt nur das Icon - die Zeilen ganz weglassen,
            // sonst behält die Box ihre volle Höhe und sieht kaputt aus.
            if expanded {
                row(L10n.t("dashboard.ram.app"), appMemory)
                if AppSettings.shared.mode == .local {
                    row("Whisper", serverMemory)
                } else {
                    Text(L10n.t("dashboard.ram.whisperOnServer"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08))
        )
        .onAppear(perform: refresh)
        // Beim Aufklappen sofort aktualisieren: Eingeklappt wird nicht gepollt,
        // der Wert wäre sonst beliebig alt (z. B. ein Whisper-Wert für einen
        // Server, den die Idle-Abschaltung längst beendet hat).
        .onChange(of: expanded) { _, nowExpanded in
            if nowExpanded { refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            // Wie beim Timer unten: eingeklappt sind die Werte unsichtbar, und
            // jedes refresh() startet einen echten /bin/ps-Prozess.
            guard expanded else { return }
            refresh()
        }
        .onReceive(timer) { _ in
            // Nicht im Hintergrund pollen - nur solange das Fenster wirklich vorne ist.
            guard NSApp.keyWindow != nil else { return }
            // Eingeklappt sind die Werte gar nicht sichtbar. Jedes refresh()
            // startet einen echten /bin/ps-Prozess, das wären 20 pro Minute
            // für nichts.
            guard expanded else { return }
            refresh()
        }
    }

    private func row(_ label: String, _ bytes: UInt64?) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(bytes.map(MemoryUsage.format) ?? "...")
                .font(.caption.weight(.semibold).monospacedDigit())
                .contentTransition(.numericText())
        }
        .lineLimit(1)
    }

    private func refresh() {
        let appPid = pid_t(ProcessInfo.processInfo.processIdentifier)
        let server = serverPid()
        var pids = [appPid]
        if let server { pids.append(server) }
        MemoryUsage.residentBytes(pids: pids) { result in
            withAnimation(.easeOut(duration: 0.3)) {
                appMemory = result[appPid]
                serverMemory = server.flatMap { result[$0] }
            }
        }
    }
}

// MARK: - Glas-Karten-Optik (gemeinsam für alle Tabs)

extension View {
    func cardStyle() -> some View {
        self
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.18), Color.white.opacity(0.03)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
            )
    }
}

// MARK: - Übersicht (Statistik)

struct DashboardView: View {
    @State private var summary = StatsSummary()
    /// Tag unter dem Mauszeiger im Chart (für Hover-Linie + Tooltip).
    @State private var hoveredDay: Date?

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                StatCard(
                    icon: "clock.badge.checkmark",
                    title: L10n.t("dashboard.stat.timeSaved.title"),
                    value: Stats.formatDuration(summary.savedSeconds),
                    subtitle: L10n.t("dashboard.stat.timeSaved.subtitle", Int(Stats.typingWordsPerMinute))
                )
                StatCard(
                    icon: "text.word.spacing",
                    title: L10n.t("dashboard.stat.wordsDictated.title"),
                    value: "\(summary.words)",
                    subtitle: L10n.t("dashboard.stat.wordsDictated.subtitle", summary.wordsPerDictation)
                )
                StatCard(
                    icon: "mic.fill",
                    title: L10n.t("dashboard.stat.dictations.title"),
                    value: "\(summary.dictations)",
                    subtitle: L10n.t("dashboard.stat.dictations.subtitle")
                )
                StatCard(
                    icon: "waveform",
                    title: L10n.t("dashboard.stat.speakingTime.title"),
                    value: Stats.formatDuration(summary.spokenSeconds),
                    subtitle: L10n.t("dashboard.stat.speakingTime.subtitle")
                )
            }

            chartCard
        }
        .onAppear { reloadSummary(animated: false) }
        // Das Fenster wird beim Schließen nur versteckt - beim Wiederöffnen
        // feuert onAppear nicht, deshalb hier zusätzlich aktualisieren.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            reloadSummary(animated: true)
        }
        // Diktiert der Nutzer, während dieses Fenster schon vorne ist, feuert
        // kein Fokuswechsel - dann blieben die Zahlen stehen.
        .onReceive(NotificationCenter.default.publisher(for: AppSettings.dictationRecordedNotification)) { _ in
            reloadSummary(animated: true)
        }
    }

    /// Auswertung läuft im Hintergrund - bei langer Nutzung hing das Fenster
    /// sonst beim Öffnen, weil die ganze Statistikdatei auf dem Main-Thread
    /// geparst wurde.
    private func reloadSummary(animated: Bool) {
        Stats.summaryAsync { fresh in
            if animated {
                withAnimation(.easeOut(duration: 0.4)) { summary = fresh }
            } else {
                summary = fresh
            }
        }
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("dashboard.chart.title"))
                    .font(.headline)
                Text(L10n.t("dashboard.chart.subtitle"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if summary.dictations == 0 {
                VStack(spacing: 6) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text(L10n.t("dashboard.chart.empty"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                Chart(summary.perDay) { day in
                    AreaMark(
                        x: .value(L10n.t("dashboard.chart.axisDay"), day.day, unit: .day),
                        y: .value(L10n.t("dashboard.chart.axisWords"), day.words)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.02)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )

                    LineMark(
                        x: .value(L10n.t("dashboard.chart.axisDay"), day.day, unit: .day),
                        y: .value(L10n.t("dashboard.chart.axisWords"), day.words)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))

                    if let hovered = hoveredDay,
                       let day = summary.perDay.first(where: { $0.day == hovered }) {
                        RuleMark(x: .value("Tag", day.day, unit: .day))
                            .foregroundStyle(Color.accentColor.opacity(0.3))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))

                        PointMark(
                            x: .value(L10n.t("dashboard.chart.axisDay"), day.day, unit: .day),
                            y: .value(L10n.t("dashboard.chart.axisWords"), day.words)
                        )
                        .symbolSize(70)
                        .foregroundStyle(Color.accentColor)
                        .annotation(
                            position: .top, spacing: 8,
                            overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                        ) {
                            VStack(spacing: 1) {
                                Text(L10n.t("dashboard.chart.tooltipWords", day.words))
                                    .font(.caption.weight(.semibold))
                                Text(day.day.formatted(.dateTime.weekday(.wide).day().month()))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.15))
                            )
                        }
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let point):
                                    // Kein Force-Unwrap: plotFrame ist nil, solange
                                    // das Diagramm keine Plot-Flaeche hat (erster
                                    // Layout-Durchlauf, Fenstergroesse 0).
                                    guard let plot = proxy.plotFrame else { return }
                                    let origin = geo[plot].origin
                                    if let date: Date = proxy.value(atX: point.x - origin.x) {
                                        // +12h = zum NÄCHSTEN Tag runden statt abschneiden
                                        let day = Calendar.current.startOfDay(for: date.addingTimeInterval(12 * 3600))
                                        if hoveredDay != day {
                                            withAnimation(.easeOut(duration: 0.12)) { hoveredDay = day }
                                        }
                                    }
                                case .ended:
                                    withAnimation(.easeOut(duration: 0.15)) { hoveredDay = nil }
                                }
                            }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 2)) { _ in
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.05))
                        AxisValueLabel(format: .dateTime.day().month(), centered: false)
                    }
                }
                .chartYAxis {
                    AxisMarks { _ in
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.05))
                        AxisValueLabel()
                    }
                }
                .frame(height: 220)
            }
        }
        .cardStyle()
    }
}

private struct StatCard: View {
    let icon: String
    let title: String
    let value: String
    let subtitle: String

    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.primary.opacity(0.07)))
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    // Russisch und Französisch sind deutlich länger als Englisch -
                    // ohne Skalierung stehen hier Auslassungspunkte.
                    .minimumScaleFactor(0.75)
            }
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .cardStyle()
        .scaleEffect(hovered ? 1.025 : 1)
        .shadow(color: .black.opacity(hovered ? 0.18 : 0), radius: 10, y: 4)
        .onHover { h in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { hovered = h }
        }
    }
}

// MARK: - Verlauf

struct HistoryView: View {
    /// Bewusst leer: Der Startwert eines @State wird bei JEDER Initialisierung
    /// der View-Struct ausgewertet, auch wenn SwiftUI das Ergebnis gleich wieder
    /// verwirft. Diese View wird bei jedem Überfahren der Seitenleiste neu
    /// gebaut, und History.load() liest die ganze Datei synchron auf dem
    /// Hauptthread. Gefüllt wird in onAppear.
    @State private var entries: [HistoryEntry] = []
    @State private var copiedID: UUID?
    @State private var confirmClear = false

    var body: some View {
        VStack(spacing: 0) {
            if entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 30))
                        .foregroundStyle(.tertiary)
                    Text(AppSettings.shared.historyEnabled
                         ? L10n.t("history.empty.enabled")
                         : L10n.t("history.empty.disabled"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 8) {
                        ForEach(entries) { entry in
                            HistoryRow(entry: entry, copied: copiedID == entry.id) {
                                TextInserter.copyToClipboard(entry.text)
                                copiedID = entry.id
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                    if copiedID == entry.id { copiedID = nil }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
                }

                HStack {
                    Text(L10n.t("history.count", entries.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.t("history.clear"), role: .destructive) {
                        confirmClear = true
                    }
                    .controlSize(.small)
                    .confirmationDialog(
                        L10n.t("history.clearConfirm.title"),
                        isPresented: $confirmClear
                    ) {
                        Button(L10n.t("history.clearConfirm.button", entries.count), role: .destructive) {
                            History.clear()
                            withAnimation(.easeOut(duration: 0.25)) { entries = [] }
                        }
                    } message: {
                        Text(L10n.t("history.clearConfirm.message"))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            }
        }
        .onAppear { entries = History.load() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            entries = History.load()
        }
        // Neues Diktat bei offenem Verlauf-Tab: sofort zeigen, nicht erst nach
        // einem Fensterwechsel.
        .onReceive(NotificationCenter.default.publisher(for: AppSettings.dictationRecordedNotification)) { _ in
            entries = History.load()
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let copied: Bool
    let onCopy: () -> Void

    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.date.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(entry.text)
                    .font(.callout)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(action: onCopy) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(copied ? .green : hovered ? .primary : .secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.t("history.copyHelp"))
            .accessibilityLabel(L10n.t("history.copyHelp"))
            .opacity(hovered || copied ? 1 : 0.35)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThinMaterial)
                .opacity(hovered ? 1 : 0.75)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(hovered ? 0.14 : 0.05))
        )
        .onHover { h in
            withAnimation(.easeOut(duration: 0.15)) { hovered = h }
        }
    }
}
