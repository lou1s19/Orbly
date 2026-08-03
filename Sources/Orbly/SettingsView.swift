import SwiftUI
import ServiceManagement
import AVFoundation
import Sparkle

struct SettingsView: View {
    @State private var mode = AppSettings.shared.mode.rawValue
    @State private var serverURL = AppSettings.shared.serverURL
    @State private var serverModelName = AppSettings.shared.serverModelName
    @State private var language = AppSettings.shared.language
    @State private var appLanguage = AppSettings.shared.appLanguage
    @State private var overlayStyle = AppSettings.shared.overlayStyle.rawValue
    @State private var overlayPosition = AppSettings.shared.overlayPosition.rawValue
    @State private var launchAtLogin = LoginItem.isOn
    @State private var launchNeedsApproval = LoginItem.needsApproval
    /// Registrierung hat nicht geklappt - dann hilft nur der Weg über die
    /// Systemeinstellungen, und das muss dastehen statt still zurückzuspringen.
    @State private var launchFailed = false
    @State private var historyEnabled = AppSettings.shared.historyEnabled
    @State private var autoInsert = AppSettings.shared.autoInsert
    @State private var mediaMode = AppSettings.shared.mediaDuringDictation.rawValue
    @State private var serverIdleShutdown = AppSettings.shared.serverIdleShutdown
    @State private var confirmDeleteAll = false

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    var body: some View {
        VStack(spacing: 12) {
            PermissionsCard()

            SettingsCard(title: L10n.t("settings.card.dictation"), icon: "text.cursor") {
                Toggle(L10n.t("settings.autoInsert"), isOn: $autoInsert)
                    .onChange(of: autoInsert) { _, enabled in
                        AppSettings.shared.autoInsert = enabled
                    }
                if !autoInsert {
                    Text(L10n.t("settings.autoInsert.hint"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                SettingsRow(label: L10n.t("settings.media")) {
                    GlassSegmented(
                        options: [
                            ("off", L10n.t("settings.media.off")),
                            ("duck", L10n.t("settings.media.duck")),
                            ("pause", L10n.t("settings.media.pause")),
                        ],
                        selection: $mediaMode,
                        compact: true
                    )
                    .onChange(of: mediaMode) { _, newValue in
                        AppSettings.shared.mediaDuringDictation = MediaDictationMode(rawValue: newValue) ?? .duck
                    }
                }
                if mediaMode != "off" {
                    Text(L10n.t("settings.media.hint"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Toggle(L10n.t("settings.saveHistory"), isOn: $historyEnabled)
                    .onChange(of: historyEnabled) { _, enabled in
                        AppSettings.shared.historyEnabled = enabled
                    }
                if historyEnabled {
                    Text(L10n.t("settings.saveHistory.hint"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                SettingsRow(label: L10n.t("settings.recognitionLanguage")) {
                    GlassSegmented(
                        options: SupportedLanguages.dictationOptions,
                        selection: $language,
                        compact: true
                    )
                    .onChange(of: language) { _, newValue in
                        AppSettings.shared.language = newValue
                    }
                }
            }

            SettingsCard(title: L10n.t("settings.card.overlay"), icon: "circle.dashed") {
                GlassSegmented(
                    options: [
                        ("orbMono", "Orb"), ("minimal", "Minimal"),
                        ("orb", L10n.t("settings.overlayStyle.orbColor")), ("pill", "Pill"),
                    ],
                    selection: $overlayStyle
                )
                .onChange(of: overlayStyle) { _, newValue in
                    AppSettings.shared.overlayStyle = OverlayStyle(rawValue: newValue) ?? .orbMono
                }

                SettingsRow(label: L10n.t("settings.overlayPosition")) {
                    PositionPicker(selection: $overlayPosition)
                        .onChange(of: overlayPosition) { _, newValue in
                            AppSettings.shared.overlayPosition = OverlayPosition(rawValue: newValue) ?? .bottomCenter
                        }
                }
            }

            SettingsCard(title: L10n.t("settings.card.transcription"), icon: "waveform") {
                HStack(spacing: 8) {
                    GlassSegmented(
                        options: [("local", L10n.t("settings.mode.local")), ("server", L10n.t("settings.mode.server"))],
                        selection: $mode
                    )
                    .onChange(of: mode) { _, newValue in
                        AppSettings.shared.mode = TranscriptionMode(rawValue: newValue) ?? .local
                        AppSettings.shared.notifyChanged()
                    }

                    ServerHelpButton()
                }

                if mode == "local" {
                    ModelListView()

                    Toggle(L10n.t("settings.serverIdle"), isOn: $serverIdleShutdown)
                        .onChange(of: serverIdleShutdown) { _, enabled in
                            AppSettings.shared.serverIdleShutdown = enabled
                        }
                    if serverIdleShutdown {
                        Text(L10n.t("settings.serverIdle.hint"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if mode == "server" {
                    TextField(L10n.t("settings.serverURL"), text: $serverURL, prompt: Text("http://192.168.1.50:8643/inference"))
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: serverURL) { _, newValue in
                            AppSettings.shared.serverURL = newValue
                        }
                    // Bei http:// auf einen entfernten Host geht die Aufnahme
                    // unverschlüsselt durchs Netz. Das muss dastehen, sonst
                    // widerspricht es dem Versprechen der App.
                    if AppSettings.isInsecureRemoteEndpoint(serverURL) {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.footnote)
                            Text(L10n.t("settings.serverURL.insecure"))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    TextField(L10n.t("settings.modelName"), text: $serverModelName)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: serverModelName) { _, newValue in
                            AppSettings.shared.serverModelName = newValue
                        }
                }
            }

            SettingsCard(title: L10n.t("settings.card.general"), icon: "gearshape") {
                Toggle(L10n.t("settings.launchAtLogin"), isOn: launchBinding)
                if launchNeedsApproval || launchFailed {
                    HStack(spacing: 8) {
                        Text(L10n.t("settings.launchAtLogin.approve"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(L10n.t("onboarding.permissions.open")) {
                            LoginItem.openSystemSettings()
                        }
                        .controlSize(.small)
                    }
                }

                SettingsRow(label: L10n.t("settings.appLanguage")) {
                    GlassSegmented(
                        options: [
                            ("auto", "Auto"), ("en", "EN"), ("de", "DE"),
                            ("es", "ES"), ("fr", "FR"), ("ru", "RU"),
                        ],
                        selection: $appLanguage,
                        compact: true
                    )
                    .onChange(of: appLanguage) { _, newValue in
                        AppSettings.shared.appLanguage = newValue
                        AppSettings.shared.notifyChanged()
                    }
                }

                SettingsRow(label: L10n.t("settings.showIntro")) {
                    Button(L10n.t("settings.showIntro.button")) {
                        (NSApp.delegate as? AppDelegate)?.showOnboarding()
                    }
                    .controlSize(.small)
                }

                UpdatesRow(appVersion: appVersion)

                // Betroffenenrechte praktisch möglich machen: Ein Weg, alles
                // zu entfernen, was die App gespeichert hat. Modelle bleiben
                // absichtlich stehen, damit niemand versehentlich 1,6 GB
                // erneut herunterlädt.
                SettingsRow(label: L10n.t("settings.deleteAll")) {
                    Button(L10n.t("settings.deleteAll.button"), role: .destructive) {
                        confirmDeleteAll = true
                    }
                    .controlSize(.small)
                    .confirmationDialog(
                        L10n.t("settings.deleteAll.confirm.title"),
                        isPresented: $confirmDeleteAll
                    ) {
                        Button(L10n.t("settings.deleteAll.confirm.keepModels"), role: .destructive) {
                            AppSettings.deleteAllData(includingModels: false)
                            reloadFromSettings()
                        }
                        Button(L10n.t("settings.deleteAll.confirm.withModels"), role: .destructive) {
                            AppSettings.deleteAllData(includingModels: true)
                            reloadFromSettings()
                        }
                    } message: {
                        Text(L10n.t("settings.deleteAll.confirm.message"))
                    }
                }
            }

            Text(.init(L10n.t("settings.hint")))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 2)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        // Der Anmelde-Schalter kann auch woanders umgelegt werden (Erst-Tour,
        // Systemeinstellungen). Deshalb beim Auftauchen und bei jedem
        // Fensterwechsel den echten Zustand nachlesen statt einmal zu raten.
        .onAppear(perform: reloadFromSettings)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            reloadFromSettings()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            reloadFromSettings()
        }
    }

    /// Alle Werte neu aus den Einstellungen lesen. Das Fenster lebt die ganze
    /// Sitzung (`isReleasedWhenClosed = false`), die @States stammen also vom
    /// App-Start. Wer in der Erst-Tour die Diktatsprache umstellt, sah hier
    /// sonst weiter den alten Wert - und konnte ihn nicht einmal korrigieren,
    /// weil ein Klick auf denselben Wert kein onChange auslöst.
    private func reloadFromSettings() {
        let s = AppSettings.shared
        mode = s.mode.rawValue
        serverURL = s.serverURL
        serverModelName = s.serverModelName
        language = s.language
        appLanguage = s.appLanguage
        overlayStyle = s.overlayStyle.rawValue
        overlayPosition = s.overlayPosition.rawValue
        historyEnabled = s.historyEnabled
        autoInsert = s.autoInsert
        mediaMode = s.mediaDuringDictation.rawValue
        serverIdleShutdown = s.serverIdleShutdown
        refreshLoginItem()
    }

    /// Eigene Bindung statt `onChange`: der Setter läuft nur, wenn der Nutzer
    /// den Schalter umlegt. Nachlesen des echten Zustands schreibt dagegen nur
    /// den State und löst keine neue Registrierung aus.
    private var launchBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { wanted in
                let actual = LoginItem.set(wanted)
                launchAtLogin = actual
                launchNeedsApproval = LoginItem.needsApproval
                launchFailed = wanted && !actual
            }
        )
    }

    private func refreshLoginItem() {
        launchAtLogin = LoginItem.isOn
        launchNeedsApproval = LoginItem.needsApproval
        if LoginItem.isEnabled { launchFailed = false }
    }
}

// MARK: - Whisper-Modelle (Auswahl + Download)

private struct ModelListView: View {
    @ObservedObject private var manager = ModelManager.shared

    /// Eingeklappt, solange nichts zu tun ist: Die Liste ist mit Sprachpaketen
    /// lang geworden, im Alltag ändert man das Modell aber fast nie.
    @State private var expanded = false

    /// Während eines Downloads immer offen - sonst verschwindet der
    /// Fortschrittsbalken unter dem zugeklappten Kopf.
    private var isOpen: Bool { expanded || !manager.progress.isEmpty }

    private var activeModelName: String {
        if let active = ModelManager.all.first(where: { manager.isSelected($0) }) {
            return active.displayName
        }
        // Eigener Pfad (z. B. manuell gesetzt): Dateiname statt Anzeigename.
        return URL(fileURLWithPath: AppSettings.shared.modelPath).lastPathComponent
    }

    private var availableCount: Int {
        manager.visibleGeneralModels.count + manager.visibleLanguageModels.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(L10n.t("settings.models.title"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(activeModelName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    if !isOpen {
                        Text(L10n.t("settings.models.available", availableCount))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!manager.progress.isEmpty)
            // Startet ein Download, bleibt die Liste auch nach dessen Ende offen -
            // sonst klappt sie genau in dem Moment zu, in dem man das frisch
            // geladene Modell aktivieren will.
            .onChange(of: manager.progress.isEmpty) { _, empty in
                if !empty { expanded = true }
            }

            // Strukturell entfernen statt ausblenden - unsichtbare Zeilen würden
            // die Layout-Box der Karte weiter aufblähen (Stolperfalle 5).
            if isOpen {
                ForEach(manager.visibleGeneralModels) { model in
                    ModelRow(model: model, manager: manager)
                }

                Text(L10n.t("settings.models.language"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 10)
                Text(L10n.t("settings.models.language.hint"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 2)
                ForEach(manager.visibleLanguageModels) { model in
                    ModelRow(model: model, manager: manager)
                }
            }
        }
    }
}

private struct ModelRow: View {
    let model: WhisperModel
    @ObservedObject var manager: ModelManager

    @State private var hovered = false

    private var installed: Bool { manager.isInstalled(model) }
    private var selected: Bool { manager.isSelected(model) }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 14))
                .foregroundStyle(selected ? Color.accentColor : Color.primary.opacity(0.25))

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(model.displayName)
                        .font(.callout.weight(selected ? .semibold : .regular))
                    if manager.isRecommended(model) {
                        Text(L10n.t("model.recommended"))
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text("\(L10n.t(model.qualityKey)) · \(model.sizeMB >= 1000 ? String(format: "%.1f GB", Double(model.sizeMB) / 1000) : "\(model.sizeMB) MB")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            trailing
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovered && installed && !selected ? Color.primary.opacity(0.05) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if installed { manager.select(model) }
        }
        .onHover { h in hovered = h }
    }

    @ViewBuilder
    private var trailing: some View {
        if let value = manager.progress[model.id] {
            HStack(spacing: 8) {
                Text("\(Int(value * 100)) %")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                ProgressView(value: value)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                Button {
                    manager.cancelDownload(model)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        } else if installed {
            if !selected && hovered {
                Button {
                    manager.delete(model)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L10n.t("model.delete"))
            }
        } else {
            HStack(spacing: 6) {
                if manager.failed.contains(model.id) {
                    Text(L10n.t("model.error"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Button {
                    manager.download(model)
                } label: {
                    Label(L10n.t("model.download"), systemImage: "arrow.down.circle")
                        .font(.caption.weight(.medium))
                }
                .controlSize(.small)
            }
        }
    }
}

/// Kleines "?" neben der Server-Auswahl: Popover mit Einrichtungs-Anleitung.
private struct ServerHelpButton: View {
    @State private var showHelp = false

    var body: some View {
        Button {
            showHelp.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showHelp, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Label(L10n.t("settings.serverHelp.title"), systemImage: "server.rack")
                    .font(.headline)
                Text(.init(L10n.t("settings.serverHelp.body")))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(width: 360)
        }
    }
}

// MARK: - Updates (Sparkle)

private struct UpdatesRow: View {
    let appVersion: String

    @State private var autoUpdate =
        (NSApp.delegate as? AppDelegate)?.updaterController.updater.automaticallyChecksForUpdates ?? true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(L10n.t("settings.autoUpdate"), isOn: $autoUpdate)
                .onChange(of: autoUpdate) { _, enabled in
                    (NSApp.delegate as? AppDelegate)?.updaterController.updater
                        .automaticallyChecksForUpdates = enabled
                }
            HStack {
                Text(L10n.t("settings.version", appVersion))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L10n.t("menu.checkUpdates")) {
                    (NSApp.delegate as? AppDelegate)?.updaterController.checkForUpdates(nil)
                }
                .controlSize(.small)
            }
        }
    }
}

// MARK: - Bausteine

private struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .cardStyle()
    }
}

private struct SettingsRow<Control: View>: View {
    let label: String
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center) {
            Text(label)
            Spacer(minLength: 12)
            control
        }
        .frame(minHeight: 26)
    }
}

/// Segmentregler im Glas-Stil der Sidebar/Tabs (statt des blauen System-Pickers).
struct GlassSegmented: View {
    let options: [(value: String, label: String)]
    @Binding var selection: String
    var compact = false
    /// Für die Erst-Tour: heller Kontrast auf dunklem Grund statt Fensterfarbe.
    var onDark = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let selected = selection == option.value
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { selection = option.value }
                } label: {
                    Text(option.label)
                        .font(compact
                              ? .caption.weight(selected ? .semibold : .regular)
                              : .callout.weight(selected ? .semibold : .regular))
                        .padding(.horizontal, compact ? 9 : 12)
                        .padding(.vertical, compact ? 4 : 5)
                        .background(
                            Capsule().fill(fill(selected: selected))
                        )
                        .overlay(
                            Capsule().strokeBorder(Color.white.opacity(selected ? 0.12 : 0))
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                // Die Auswahl steckt nur in Schriftgewicht und Kapselfüllung -
                // VoiceOver sagt ohne dieses Merkmal nicht, was aktiv ist.
                .accessibilityAddTraits(selected ? .isSelected : [])
                .foregroundStyle(
                    onDark
                        ? AnyShapeStyle(Color.white.opacity(selected ? 1 : 0.62))
                        : AnyShapeStyle(selected ? Color.primary : Color.secondary)
                )
            }
        }
        .padding(3)
        .background(Capsule().fill(onDark ? Color.black.opacity(0.3) : Color.primary.opacity(0.05)))
    }

    private func fill(selected: Bool) -> AnyShapeStyle {
        guard selected else { return AnyShapeStyle(.clear) }
        return onDark ? AnyShapeStyle(Color.white.opacity(0.17)) : AnyShapeStyle(.background)
    }
}

/// Visuelle Positions-Auswahl: Mini-Bildschirm mit klickbaren Punkten.
private struct PositionPicker: View {
    @Binding var selection: String

    private let positions: [(value: String, x: CGFloat, y: CGFloat)] = [
        ("topCenter", 0.5, 0.22),
        ("topRight", 0.85, 0.22),
        ("bottomLeft", 0.15, 0.78),
        ("bottomCenter", 0.5, 0.78),
        ("bottomRight", 0.85, 0.78),
    ]

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05))
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1))
            // "Menüleiste" des Mini-Bildschirms
            VStack {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 4)
                    .padding(.horizontal, 5)
                    .padding(.top, 5)
                Spacer()
            }

            GeometryReader { geo in
                ForEach(positions, id: \.value) { pos in
                    let selected = selection == pos.value
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { selection = pos.value }
                    } label: {
                        Circle()
                            .fill(selected ? Color.accentColor : Color.primary.opacity(0.25))
                            .frame(width: selected ? 10 : 8, height: selected ? 10 : 8)
                            .overlay(
                                Circle().strokeBorder(Color.white.opacity(selected ? 0.4 : 0))
                            )
                            .frame(width: 20, height: 20)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .position(x: geo.size.width * pos.x, y: geo.size.height * pos.y)
                    .help(OverlayPosition(rawValue: pos.value)?.title ?? "")
                    // Fünf gleich aussehende Punkte: Der Zustand steckt sonst nur
                    // in Farbe und 2 Punkt Größenunterschied.
                    .accessibilityLabel(OverlayPosition(rawValue: pos.value)?.title ?? "")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
        .frame(width: 128, height: 76)
    }
}

/// Zeigt fehlende Berechtigungen. Ist alles erteilt, verschwindet die Karte komplett.
private struct PermissionsCard: View {
    @State private var axTrusted = AXIsProcessTrusted()
    @State private var micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized

    var body: some View {
        Group {
            if !axTrusted || !micGranted {
                VStack(alignment: .leading, spacing: 10) {
                    Label(L10n.t("settings.permissionsMissing"), systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)

                    if !micGranted {
                        permissionRow(
                            L10n.t("settings.permission.microphone"),
                            hint: L10n.t("settings.permission.microphone.hint"),
                            pane: "Privacy_Microphone"
                        )
                    }
                    if !axTrusted {
                        permissionRow(
                            L10n.t("settings.permission.accessibility"),
                            hint: L10n.t("settings.permission.accessibility.hint"),
                            pane: "Privacy_Accessibility"
                        )
                    }
                }
                .cardStyle()
            }
        }
        // Kein Dauer-Timer: Berechtigungen ändern sich nur in den
        // Systemeinstellungen, also während der Nutzer nicht in Orbly ist. Ein
        // 2-Sekunden-Timer lief vorher weiter, solange das Fenster im Speicher
        // war, auch geschlossen (es wird nur versteckt, nicht freigegeben).
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            reload()
        }
    }

    private func reload() {
        axTrusted = AXIsProcessTrusted()
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    private func permissionRow(_ name: String, hint: String, pane: String) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.callout.weight(.medium))
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(L10n.t("settings.permission.open")) {
                let url = "x-apple.systempreferences:com.apple.preference.security?\(pane)"
                if let u = URL(string: url) { NSWorkspace.shared.open(u) }
            }
        }
    }
}
