import AVFoundation
import Combine
import SwiftUI

// MARK: - State of the first-run tour

enum OnboardingStep: Int, CaseIterable {
    case welcome, permissions, engine, tryIt, done
}

/// State of the first-run tour.
///
/// The test dictation deliberately runs through the normal dictation flow in
/// the AppDelegate (same state machine, same overlay). While `captureActive` is
/// set, the result lands here in the window instead of in the target app and is
/// stored neither in the statistics nor in the history. It is only a test.
final class OnboardingModel: ObservableObject {
    enum Phase { case idle, recording, processing, done, failed }

    static let barCount = 26

    @Published var step: OnboardingStep = .welcome
    @Published var phase: Phase = .idle
    @Published var levels: [Float] = Array(repeating: 0, count: OnboardingModel.barCount)
    @Published var transcript = ""
    @Published var errorText = ""

    /// Set by the AppDelegate while the tour window is open.
    var captureActive = false

    func reset() {
        step = .welcome
        resetDictation()
    }

    func resetDictation() {
        phase = .idle
        transcript = ""
        errorText = ""
        levels = Array(repeating: 0, count: OnboardingModel.barCount)
    }

    func push(level: Float) {
        guard !levels.isEmpty else { return }
        levels.removeFirst()
        levels.append(level)
    }

    func begin() {
        transcript = ""
        errorText = ""
        withAnimation(.easeOut(duration: 0.2)) { phase = .recording }
    }

    func processing() {
        withAnimation(.easeOut(duration: 0.2)) { phase = .processing }
    }

    func cancelled() {
        withAnimation(.easeOut(duration: 0.2)) { resetDictation() }
    }

    func finish(text: String) {
        transcript = text
        errorText = ""
        withAnimation(.easeOut(duration: 0.25)) {
            phase = .done
            step = .tryIt
        }
    }

    func fail(_ message: String) {
        errorText = message
        withAnimation(.easeOut(duration: 0.25)) {
            phase = .failed
            step = .tryIt
        }
    }
}

// MARK: - Window

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    let onFinish: () -> Void

    /// Direction of the last move, the pages slide in to match.
    @State private var forward = true
    @State private var arrowKeys: Any?

    var body: some View {
        ZStack {
            NightSky()

            VStack(spacing: 0) {
                // Room for the traffic light buttons (the title bar is transparent).
                Color.clear.frame(height: 28)

                ZStack {
                    switch model.step {
                    case .welcome: WelcomeStep()
                    case .permissions: PermissionsStep()
                    case .engine: EngineStep()
                    case .tryIt: TryStep(model: model)
                    case .done: DoneStep()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 52)
                .id(model.step)
                // Cross-fade with a slight offset in the direction of travel: the
                // motion should suggest the change, not lead the eye.
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .offset(x: forward ? 22 : -22)),
                        removal: .opacity.combined(with: .offset(x: forward ? -22 : 22))
                    )
                )

                footer
            }
        }
        .frame(width: 940, height: 660)
        .preferredColorScheme(.dark)
        .onAppear { installArrowKeys() }
        .onDisappear { removeArrowKeys() }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 12) {
            ZStack {
                HStack(spacing: 0) {
                    if model.step != .welcome {
                        QuietButton(title: L10n.t("onboarding.back"), systemImage: "arrow.left") {
                            move(by: -1)
                        }
                    }
                    Spacer(minLength: 0)
                    PrimaryPillButton(
                        title: model.step == .done ? L10n.t("onboarding.finish") : L10n.t("onboarding.next"),
                        systemImage: model.step == .done ? "checkmark" : "arrow.right"
                    ) {
                        advance()
                    }
                    .keyboardShortcut(.defaultAction)
                }

                StepDots(count: OnboardingStep.allCases.count, index: model.step.rawValue)
                    .help(L10n.t("onboarding.step", model.step.rawValue + 1, OnboardingStep.allCases.count))
            }

            ZStack {
                Text(L10n.t("onboarding.keys"))
                    .font(.system(size: 12))
                    .foregroundStyle(OB.faint)

                HStack {
                    Spacer(minLength: 0)
                    if model.step != .done {
                        QuietButton(title: L10n.t("onboarding.skip"), size: 13) { onFinish() }
                    }
                }
            }
        }
        .padding(.horizontal, 44)
        .padding(.bottom, 22)
    }

    // MARK: Navigation

    private func advance() {
        if model.step == .done {
            onFinish()
        } else {
            move(by: 1)
        }
    }

    private func move(by delta: Int) {
        guard let next = OnboardingStep(rawValue: model.step.rawValue + delta) else { return }
        forward = delta > 0
        withAnimation(.easeInOut(duration: 0.32)) { model.step = next }
    }

    /// Arrow keys as in a presentation. The monitor is app-wide, so it only reacts
    /// to events from the tour window (identified by a tag from the AppDelegate).
    private func installArrowKeys() {
        guard arrowKeys == nil else { return }
        arrowKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window?.identifier?.rawValue == AppDelegate.onboardingWindowID else { return event }
            // When the cursor sits in a text field or in the selectable dictation
            // text, the arrow keys belong there and not to page navigation.
            if event.window?.firstResponder is NSTextView { return event }
            switch event.keyCode {
            case 123: move(by: -1); return nil
            case 124: advance(); return nil
            default: return event
            }
        }
    }

    private func removeArrowKeys() {
        if let arrowKeys { NSEvent.removeMonitor(arrowKeys) }
        arrowKeys = nil
    }
}

// MARK: - 1. Welcome

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 30) {
            Spacer(minLength: 0)

            PageHeader(
                icon: "waveform",
                title: L10n.t("onboarding.welcome.title"),
                subtitle: L10n.t("onboarding.welcome.body")
            )

            HStack(alignment: .top, spacing: 16) {
                FeatureCard(
                    icon: "lock",
                    title: L10n.t("onboarding.welcome.point1"),
                    text: L10n.t("onboarding.welcome.point1.hint")
                )
                FeatureCard(
                    icon: "bolt",
                    title: L10n.t("onboarding.welcome.point2"),
                    text: L10n.t("onboarding.welcome.point2.hint")
                )
                FeatureCard(
                    icon: "menubar.arrow.up.rectangle",
                    title: L10n.t("onboarding.welcome.point3"),
                    text: L10n.t("onboarding.welcome.point3.hint")
                )
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 720)

            Text(L10n.t("onboarding.welcome.takes"))
                .font(.system(size: 12))
                .foregroundStyle(OB.faint)

            Spacer(minLength: 0)
        }
    }
}

// MARK: - 2. Permissions

private struct PermissionsStep: View {
    @State private var micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var axTrusted = AXIsProcessTrusted()

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 0)

            PageHeader(
                icon: "checkmark.shield",
                title: L10n.t("onboarding.permissions.title"),
                subtitle: L10n.t("onboarding.permissions.body")
            )

            VStack(spacing: 12) {
                permissionCard(
                    title: L10n.t("onboarding.permissions.mic"),
                    hint: L10n.t("onboarding.permissions.mic.hint"),
                    granted: micGranted,
                    action: requestMicrophone
                )

                permissionCard(
                    title: L10n.t("onboarding.permissions.ax"),
                    hint: L10n.t("onboarding.permissions.ax.hint"),
                    granted: axTrusted,
                    action: requestAccessibility
                ) {
                    if !axTrusted {
                        HStack(spacing: 8) {
                            Text(L10n.t("onboarding.permissions.axNote"))
                                .font(.system(size: 12))
                                .foregroundStyle(OB.faint)
                                .fixedSize(horizontal: false, vertical: true)
                            QuietButton(title: L10n.t("onboarding.permissions.open"), size: 12) {
                                openPane("Privacy_Accessibility")
                            }
                        }
                        .padding(.top, 12)
                    }
                }
            }
            .frame(maxWidth: 660)

            Spacer(minLength: 0)
        }
        // No permanent timer: permission is granted in System Settings, so while
        // Orbly is in the background. Reading it again on return is enough, and
        // this used to keep running forever after the tour was closed.
        // The microphone dialog refreshes through its own handler.
        .onAppear(perform: reloadPermissions)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            reloadPermissions()
        }
    }

    private func reloadPermissions() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        axTrusted = AXIsProcessTrusted()
    }

    private func permissionCard<Extra: View>(
        title: String,
        hint: String,
        granted: Bool,
        action: @escaping () -> Void,
        @ViewBuilder extra: () -> Extra = { EmptyView() }
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(OB.title)
                    Text(hint)
                        .font(.system(size: 13.5))
                        .foregroundStyle(OB.text)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                if granted {
                    GhostPillLabel(title: L10n.t("onboarding.permissions.granted"), systemImage: "checkmark")
                } else {
                    GhostPillButton(title: L10n.t("onboarding.permissions.allow"), action: action)
                }
            }
            extra()
        }
        .obCard()
    }

    private func requestMicrophone() {
        // macOS may only ask the first time. After that the path leads through
        // System Settings, otherwise visibly nothing happens on the click.
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else {
            openPane("Privacy_Microphone")
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { micGranted = granted }
        }
    }

    private func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        axTrusted = AXIsProcessTrustedWithOptions(options)
    }

    private func openPane(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - 3. Language and model

private struct EngineStep: View {
    @ObservedObject private var manager = ModelManager.shared
    @State private var language = AppSettings.shared.language
    /// The model currently being downloaded for the tour (activated afterwards).
    @State private var pendingID: String?
    @State private var copied = false

    private var isLocal: Bool { AppSettings.shared.mode == .local }
    private var engineMissing: Bool { LocalServerManager.findServerBinary() == nil }
    private static let installCommand = "brew install whisper-cpp"

    /// The active model, provided it really is on disk.
    private var activeModel: WhisperModel? {
        ModelManager.all.first { manager.isSelected($0) && manager.isInstalled($0) }
    }

    private var recommended: WhisperModel? {
        ModelManager.all.first { $0.id == ModelManager.recommendedID }
    }

    var body: some View {
        VStack(spacing: 26) {
            Spacer(minLength: 0)

            PageHeader(
                icon: "globe",
                title: L10n.t("onboarding.engine.title"),
                subtitle: L10n.t("onboarding.engine.body")
            )

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.t("onboarding.engine.language"))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(OB.title)
                    GlassSegmented(
                        options: SupportedLanguages.dictationOptions,
                        selection: $language,
                        onDark: true
                    )
                    .onChange(of: language) { _, newValue in
                        AppSettings.shared.language = newValue
                    }
                }

                OBDivider()

                if isLocal {
                    modelSection
                } else {
                    OBRow(
                        icon: "server.rack",
                        title: L10n.t("settings.mode.server"),
                        hint: L10n.t("onboarding.engine.serverMode"),
                        done: true
                    )
                }
            }
            .obCard()
            .frame(maxWidth: 660)

            if isLocal && engineMissing {
                engineMissingCard
                    .frame(maxWidth: 660)
            }

            Spacer(minLength: 0)
        }
        .onReceive(manager.$progress) { progress in
            // Activate automatically after the download: nobody wants to switch to
            // the settings afterwards during the tour.
            guard let id = pendingID, progress[id] == nil,
                  let model = ModelManager.all.first(where: { $0.id == id }),
                  manager.isInstalled(model) else { return }
            pendingID = nil
            manager.select(model)
        }
    }

    @ViewBuilder
    private var modelSection: some View {
        if let active = activeModel {
            OBRow(
                icon: "checkmark",
                title: L10n.t("onboarding.engine.ready"),
                hint: "\(active.displayName) · \(L10n.t(active.qualityKey))",
                done: true
            )
        } else if let model = recommended {
            VStack(alignment: .leading, spacing: 12) {
                OBRow(
                    icon: "arrow.down.circle",
                    title: model.displayName,
                    hint: "\(L10n.t(model.qualityKey)) · \(formattedSize(model))"
                ) {
                    if manager.progress[model.id] == nil {
                        GhostPillButton(title: L10n.t("onboarding.engine.download")) {
                            pendingID = model.id
                            manager.download(model)
                        }
                    }
                }

                if let value = manager.progress[model.id] {
                    HStack(spacing: 10) {
                        ProgressView(value: value)
                            .tint(Color.accentColor)
                        Text("\(Int(value * 100)) %")
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(OB.text)
                        Button {
                            pendingID = nil
                            manager.cancelDownload(model)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Color.white.opacity(0.45))
                        }
                        .buttonStyle(.plain)
                    }
                }

                if manager.failed.contains(model.id) {
                    Text(L10n.t("model.error"))
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var engineMissingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.t("onboarding.engine.missingEngine"), systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.orange)
            Text(L10n.t("onboarding.engine.missingEngine.hint"))
                .font(.system(size: 12.5))
                .foregroundStyle(OB.text)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(Self.installCommand)
                    .font(.system(size: 13.5, design: .monospaced))
                    .foregroundStyle(OB.title)
                    .textSelection(.enabled)
                Spacer()
                QuietButton(
                    title: copied ? L10n.t("onboarding.engine.copied") : L10n.t("history.copyHelp"),
                    systemImage: copied ? "checkmark" : "doc.on.doc",
                    size: 12
                ) {
                    TextInserter.copyToClipboard(Self.installCommand)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(0.3))
            )
        }
        .obCard()
    }

    private func formattedSize(_ model: WhisperModel) -> String {
        model.sizeMB >= 1000
            ? String(format: "%.1f GB", Double(model.sizeMB) / 1000)
            : "\(model.sizeMB) MB"
    }
}

// MARK: - 4. Try it out (interactive test dictation)

private struct TryStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)

            HStack(alignment: .top, spacing: 36) {
                VStack(alignment: .leading, spacing: 18) {
                    IconTile(symbol: "mic.badge.plus", size: 52)

                    VStack(alignment: .leading, spacing: 10) {
                        Text(L10n.t("onboarding.try.title"))
                            .font(.system(size: 27, weight: .bold))
                            .tracking(-0.4)
                            .foregroundStyle(OB.title)
                        Text(.init(L10n.t("onboarding.try.body")))
                            .font(.system(size: 14.5))
                            .foregroundStyle(OB.text)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        CheckItem(text: L10n.t("onboarding.try.point1"))
                        CheckItem(text: L10n.t("onboarding.try.point2"))
                        CheckItem(text: L10n.t("onboarding.try.point3"))
                    }
                    .padding(.top, 2)
                }
                .frame(width: 300, alignment: .leading)

                // The stage switches between waiting, recording, processing and the
                // result. Cross-fade every time instead of swapping hard.
                ZStack {
                    stage
                        .id(model.phase)
                        .transition(
                            .asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.96)),
                                removal: .opacity
                            )
                        )
                }
                .frame(height: 322)
                .frame(maxWidth: .infinity)
                .obCard(padding: 24)
            }

            Text(L10n.t("onboarding.try.hintEsc"))
                .font(.system(size: 12))
                .foregroundStyle(OB.faint)
                .frame(maxWidth: .infinity, alignment: .center)

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var stage: some View {
        switch model.phase {
        case .idle:
            WaitingForFn()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .recording:
            VStack(spacing: 18) {
                LevelBars(levels: model.levels)
                Text(L10n.t("onboarding.try.recording"))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .processing:
            VStack(spacing: 18) {
                // The same dots as in the overlay: the tour shows exactly what the
                // user sees later while dictating.
                ProcessingDotsView(color: .white, dotSize: 8, spacing: 7, active: true)
                Text(L10n.t("onboarding.try.processing"))
                    .font(.system(size: 14))
                    .foregroundStyle(OB.text)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .done:
            result(
                icon: "checkmark.circle.fill",
                tint: Color.accentColor,
                text: model.transcript,
                note: L10n.t("onboarding.try.success")
            )
        case .failed:
            result(
                icon: "exclamationmark.triangle.fill",
                tint: .orange,
                text: model.errorText,
                note: nil
            )
        }
    }

    private func result(icon: String, tint: Color, text: String, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                Text(note == nil ? L10n.t("onboarding.try.failed") : L10n.t("onboarding.try.heard"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OB.text)
                Spacer()
                GhostPillButton(title: L10n.t("onboarding.try.again"), systemImage: "arrow.counterclockwise") {
                    model.resetDictation()
                }
            }

            // Scrollable instead of truncated: a long dictation should stay fully
            // readable and copyable. The card has a fixed minimum height anyway.
            ScrollView(showsIndicators: false) {
                Text(text)
                    .font(.system(size: 17))
                    .foregroundStyle(OB.title)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)

            if let note {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(OB.faint)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Resting state: a pulsing "fn" key as an invitation.
private struct WaitingForFn: View {
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 16) {
            OBKeyCap(label: "fn", wide: true)
                .scaleEffect(pulse ? 1.08 : 1)
                .shadow(color: Color.accentColor.opacity(pulse ? 0.45 : 0), radius: 16)
            Text(L10n.t("onboarding.try.idle"))
                .font(.system(size: 14))
                .foregroundStyle(OB.text)
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

/// Level bars as in the overlay, only larger.
private struct LevelBars: View {
    let levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(Color.accentColor.opacity(0.9))
                    .frame(width: 4, height: 5 + CGFloat(min(max(level, 0), 1)) * 62)
            }
        }
        .frame(height: 70)
        .animation(.easeOut(duration: 0.09), value: levels)
    }
}

// MARK: - 5. Done

private struct DoneStep: View {
    @State private var launchAtLogin = LoginItem.isOn
    @State private var needsApproval = LoginItem.needsApproval
    @State private var failed = false

    /// See SettingsView: setter only on real user input.
    private var launchBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { wanted in
                let actual = LoginItem.set(wanted)
                launchAtLogin = actual
                needsApproval = LoginItem.needsApproval
                failed = wanted && !actual
            }
        )
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)

            PageHeader(
                icon: "checkmark.circle",
                title: L10n.t("onboarding.done.title"),
                subtitle: L10n.t("onboarding.done.body")
            )

            VStack(spacing: 16) {
                gestureRow(key: "fn",
                           title: L10n.t("onboarding.done.hold"),
                           hint: L10n.t("onboarding.done.hold.hint"))
                OBDivider()
                gestureRow(key: "fn",
                           title: L10n.t("onboarding.done.tap"),
                           hint: L10n.t("onboarding.done.tap.hint"))
                OBDivider()
                gestureRow(key: "esc",
                           title: L10n.t("onboarding.done.esc"),
                           hint: L10n.t("onboarding.done.esc.hint"))
            }
            .obCard()
            .frame(maxWidth: 560)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(L10n.t("onboarding.done.launch"))
                        .font(.system(size: 15))
                        .foregroundStyle(OB.title)
                    Spacer(minLength: 12)
                    // The label is kept for VoiceOver, visibly it sits on the left.
                    Toggle(L10n.t("onboarding.done.launch"), isOn: launchBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                if needsApproval || failed {
                    HStack(spacing: 8) {
                        Text(L10n.t("settings.launchAtLogin.approve"))
                            .font(.system(size: 12))
                            .foregroundStyle(OB.faint)
                            .fixedSize(horizontal: false, vertical: true)
                        QuietButton(title: L10n.t("onboarding.permissions.open"), size: 12) {
                            LoginItem.openSystemSettings()
                        }
                    }
                }
            }
            .obCard(padding: 18)
            .frame(maxWidth: 560)

            Spacer(minLength: 0)
        }
        // Whoever confirms in System Settings and comes back should find the
        // switch in the right state, not only after changing page.
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    private func refresh() {
        launchAtLogin = LoginItem.isOn
        needsApproval = LoginItem.needsApproval
        if LoginItem.isEnabled { failed = false }
    }

    private func gestureRow(key: String, title: String, hint: String) -> some View {
        HStack(alignment: .center, spacing: 14) {
            OBKeyCap(label: key, wide: true)
                .frame(width: 52, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(OB.title)
                Text(hint)
                    .font(.system(size: 13))
                    .foregroundStyle(OB.text)
            }
            Spacer(minLength: 0)
        }
    }
}
