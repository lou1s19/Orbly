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
    /// Registration did not work. Then only the route through System Settings
    /// helps, and that has to be said instead of silently jumping back.
    @State private var launchFailed = false
    @State private var historyEnabled = AppSettings.shared.historyEnabled
    @State private var autoInsert = AppSettings.shared.autoInsert
    @State private var mediaMode = AppSettings.shared.mediaDuringDictation.rawValue
    @State private var serverIdleShutdown = AppSettings.shared.serverIdleShutdown
    @State private var dictationKey = AppSettings.shared.dictationKey.rawValue
    @State private var confirmDeleteAll = false

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    var body: some View {
        VStack(spacing: 12) {
            PermissionsCard()

            SettingsCard(title: L10n.t("settings.card.dictation"), icon: "text.cursor") {
                SettingsRow(label: L10n.t("settings.dictationKey")) {
                    GlassSegmented(
                        options: DictationKey.pickerOptions,
                        selection: $dictationKey,
                        compact: true
                    )
                    .onChange(of: dictationKey) { _, newValue in
                        AppSettings.shared.dictationKey = DictationKey(rawValue: newValue) ?? .default
                        // The menu title, the tour and the hint below all name the
                        // key, so they have to be redrawn right away.
                        AppSettings.shared.notifyChanged()
                    }
                }
                Text(L10n.t("settings.dictationKey.hint"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)

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
                        Text(L10n.t("settings.serverIdle.hint", AppSettings.shared.dictationKey.displayName))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if mode == "server" {
                    TextField(L10n.t("settings.serverURL"), text: $serverURL, prompt: Text("http://192.168.1.50:8643/inference"))
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: serverURL) { _, newValue in
                            // Store it trimmed: a space copied along at the end
                            // made the address invalid, and the mistake only
                            // showed up on the next dictation.
                            AppSettings.shared.serverURL = newValue
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    // With http:// to a remote host the recording goes over
                    // the network unencrypted. That has to be said, otherwise
                    // it contradicts the promise of the app.
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
                            // Strip line breaks: the value goes into a multipart body
                            // unchanged, and a \r\n could break it apart.
                            AppSettings.shared.serverModelName = newValue
                                .replacingOccurrences(of: "\r", with: "")
                                .replacingOccurrences(of: "\n", with: "")
                                .trimmingCharacters(in: .whitespaces)
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
                            ("auto", L10n.t("settings.language.auto")), ("en", "EN"), ("de", "DE"),
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

                // Make the right to erasure practical: a way to remove
                // everything the app has stored. Models deliberately stay,
                // so nobody accidentally downloads 1.6 GB again.
                //
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
                            // Without this signal the running whisper-server stays on
                            // the old model, and open windows keep showing the numbers
                            // that were just deleted.
                            AppSettings.shared.notifyChanged()
                        }
                        Button(L10n.t("settings.deleteAll.confirm.withModels"), role: .destructive) {
                            AppSettings.deleteAllData(includingModels: true)
                            reloadFromSettings()
                            AppSettings.shared.notifyChanged()
                        }
                    } message: {
                        Text(L10n.t("settings.deleteAll.confirm.message"))
                    }
                }
            }

            SupportCard()

            Text(.init(L10n.t("settings.hint", AppSettings.shared.dictationKey.displayName, AppSettings.shared.dictationKey.displayName)))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 2)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        // The login switch can be flipped elsewhere too (first-run tour, System
        // Settings). So read the real state again when appearing and on every
        // window change instead of guessing once.
        .onAppear(perform: reloadFromSettings)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            reloadFromSettings()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            reloadFromSettings()
        }
    }

    /// Read all values from the settings again. The window lives for the whole
    /// session (`isReleasedWhenClosed = false`), so the @States come from app
    /// start. Whoever changes the dictation language in the first-run tour would
    /// otherwise still see the old value here, and could not even correct it,
    /// because clicking the same value fires no onChange.
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
        dictationKey = s.dictationKey.rawValue
        refreshLoginItem()
    }

    /// A binding of our own instead of `onChange`: the setter only runs when the
    /// user flips the switch. Reading back the real state only writes the state
    /// and triggers no new registration.
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

// MARK: - Whisper models (selection + download)

private struct ModelListView: View {
    @ObservedObject private var manager = ModelManager.shared

    /// Collapsed while there is nothing to do: the list has grown long with the
    /// language packs, but in everyday use the model is almost never changed.
    @State private var expanded = false

    /// Always open during a download, otherwise the progress bar disappears under
    /// the collapsed header.
    private var isOpen: Bool { expanded || !manager.progress.isEmpty }

    private var activeModelName: String {
        if let active = ModelManager.all.first(where: { manager.isSelected($0) }) {
            return active.displayName
        }
        // A custom path (set manually, say): file name instead of display name.
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
            // When a download starts, the list stays open after it finishes too,
            // otherwise it collapses at exactly the moment you want to activate the
            // freshly downloaded model.
            .onChange(of: manager.progress.isEmpty) { _, empty in
                if !empty { expanded = true }
            }

            // Remove structurally instead of hiding: invisible rows would keep
            // inflating the layout box of the card (pitfall 5).
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

/// Small "?" next to the server choice: a popover with setup instructions.
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
        // The window lives for the whole session, so the @State initial value is
        // only read once. If a Sparkle dialog changes the setting, the switch kept
        // showing the state from app start forever after.
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            reload()
        }
    }

    private func reload() {
        guard let updater = (NSApp.delegate as? AppDelegate)?.updaterController.updater else { return }
        autoUpdate = updater.automaticallyChecksForUpdates
    }
}

// MARK: - Donations

/// The way to the donation page, even when the startup window was dismissed
/// long ago. Whoever confirmed already sees a thank you instead of the ask.
private struct SupportCard: View {
    @State private var hasDonated = AppSettings.shared.hasDonated

    var body: some View {
        SettingsCard(title: L10n.t("settings.card.support"), icon: "heart") {
            Text(hasDonated ? L10n.t("settings.support.donated") : L10n.t("settings.support.body"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(L10n.t("settings.support.button")) {
                    NSWorkspace.shared.open(Donation.pageURL)
                }
                .controlSize(.small)
            }
        }
        // The state may have changed in the donation window while the settings
        // sit in memory (the window is only hidden).
        .onAppear { hasDonated = AppSettings.shared.hasDonated }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            hasDonated = AppSettings.shared.hasDonated
        }
    }
}

// MARK: - Building blocks

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

/// Segmented control in the glass style of the sidebar/tabs (instead of the blue system picker).
struct GlassSegmented: View {
    let options: [(value: String, label: String)]
    @Binding var selection: String
    var compact = false
    /// For the first-run tour: bright contrast on a dark ground instead of the window color.
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
                // The selection only shows in the font weight and the capsule fill.
                // Without this trait VoiceOver does not say what is active.
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

/// Visual position picker: a mini screen with clickable dots.
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
            // "menu bar" of the mini screen
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
                    // Five dots that look the same: otherwise the state only shows in
                    // the color and 2 points of size difference.
                    .accessibilityLabel(OverlayPosition(rawValue: pos.value)?.title ?? "")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
        .frame(width: 128, height: 76)
    }
}

/// Shows missing permissions. Once everything is granted, the card disappears completely.
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
        // No permanent timer: permissions only change in System Settings, so
        // while the user is not in Orbly. A 2 second timer used to keep running
        // as long as the window was in memory, closed as well (it is only
        // hidden, not released).
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
