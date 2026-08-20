import AppKit
import SwiftUI
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    /// Sparkle auto updates (the feed and the signing key live in the Info.plist).
    let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
    )
    private enum DictationState: Equatable {
        case idle
        case recording
        case processing
    }

    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var ramMenuItem: NSMenuItem!
    private let recorder = AudioRecorder()
    private let fnMonitor = FnKeyMonitor()
    private let overlay = OverlayController()
    private let localServer = LocalServerManager()
    private let transcriber = Transcriber()
    private let mediaController = MediaController()
    private var mainWindow: NSWindow?
    private let mainWindowState = MainWindowState()
    /// First-run tour: its own window, catches the dictation result while it is open.
    let onboarding = OnboardingModel()
    private var onboardingWindow: NSWindow?
    /// Tag of the tour window, so the tour's arrow key monitor only reacts to
    /// events from exactly that window.
    static let onboardingWindowID = "orbly.onboarding"
    /// Prevents a second click from restarting the fade-out.
    private var onboardingClosing = false
    /// Donation prompt (see Donation.swift). Only open temporarily.
    private var donationWindow: NSWindow?

    /// The only place where the dictation state changes. `didSet` hangs the key
    /// monitoring off it, so it is guaranteed to match every path back to `.idle`.
    /// There are seven of them, and one would eventually have been forgotten.
    ///
    private var state: DictationState = .idle {
        didSet {
            guard state != oldValue else { return }
            let aktiv = state != .idle
            // Not synchronous: the change to .idle often happens INSIDE the handler
            // of the keyDown monitor (Esc aborts). An NSEvent.removeMonitor on the
            // block that is currently running would be undefined behaviour.
            DispatchQueue.main.async { [weak self] in
                guard let self, (self.state != .idle) == aktiv else { return }
                self.fnMonitor.setKeyMonitoringEnabled(aktiv)
            }
        }
    }
    private var fnPressStarted: Date?
    private var toggleSession = false
    /// The app the dictation was started in. Text is only inserted there.
    private var dictationTargetApp: NSRunningApplication?
    private var maxDurationTimer: Timer?
    /// Counts dictations. A cancelled dictation no longer lets its late answer
    /// through (otherwise text would still be inserted after the cancellation).
    private var dictationSession = 0
    /// Push-to-talk watchdog: with secure input active (a password field) the
    /// global monitor no longer sees Fn being released. Without this check the
    /// recording would run to the 10 minute limit and then be pasted.
    private var fnWatchdog: Timer?
    /// Upper limit for forgotten toggle recordings (RAM grows by about 230 MB/h).
    private let maxRecordingSeconds: TimeInterval = 600
    /// Show the system dialog for accessibility only once per session.
    private var axPromptShown = false

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        enableAutomaticUpdateChecksByDefault()
        let showTour = shouldShowOnboarding()
        // The tour asks for the permissions itself, with an explanation next to
        // them. Otherwise two system dialogs stand in the room on the very first
        // launch, before the user knows what this is about at all.
        if !showTour { requestPermissions() }
        localServer.reconcile()
        localServer.startIdleWatch()
        overlay.flashLaunched()
        // The history ages out: remove old dictations at startup (privacy + file size).
        History.pruneOldEntries()
        // Clear away recordings left behind by earlier crashes.
        AudioRecorder.sweepLeftoverRecordings()
        // Compact old individual statistics entries so the file does not grow
        // without bound (the totals stay exact).
        Stats.compactOldEntries()

        recorder.onLevel = { [weak self] level in
            guard let self else { return }
            self.overlay.push(level: level)
            if self.onboarding.captureActive { self.onboarding.push(level: level) }
            // While audio is coming in, the server is in use. Without this, only the
            // START of a recording counted as activity, and the idle shutdown ended
            // the server after 3 minutes in the middle of speaking. A longer
            // dictation was completely lost after that.
            self.localServer.noteActivity()
        }

        fnMonitor.onFnDown = { [weak self] in self?.handleFnDown() }
        fnMonitor.onFnUp = { [weak self] in self?.handleFnUp() }
        fnMonitor.onOtherKeyDown = { [weak self] keyCode in
            self?.handleOtherKeyDown(keyCode)
        }
        fnMonitor.start()

        NotificationCenter.default.addObserver(
            forName: AppSettings.changedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reconcileIfTranscriptionSettingsChanged()
            self?.pruneHistoryOnSettingsChange()
            self?.applyLanguageIfChanged()
            self?.updateStatus()
        }

        if showTour {
            showOnboarding()
        } else if Donation.shouldShowNow {
            // Wait a moment: when starting at login, a window should not stand in
            // front of the desktop right away.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.showDonationPrompt()
            }
        }
    }

    /// Automatic update checks are the default. Set it explicitly once, as long as
    /// the user has not chosen otherwise, so the switch is reliably on for
    /// existing installations too and not only "by default".
    private func enableAutomaticUpdateChecksByDefault() {
        guard UserDefaults.standard.object(forKey: "SUEnableAutomaticChecks") == nil else { return }
        updaterController.updater.automaticallyChecksForUpdates = true
    }

    /// Last seen state of the settings that concern the local server.
    private var lastServerSettings = AppSettings.shared.transcriptionSettingsFingerprint

    /// Only touch the server on changes that really matter. Before this, EVERY
    /// settings change (overlay style or position included) restarted a server
    /// that the idle shutdown had put to sleep, model of 650 MB and all.
    /// The history ages out after three days. That used to run only at startup and
    /// when appending a dictation. Whoever turns the history off would therefore
    /// have kept their old plain text dictations indefinitely in an app that runs
    /// for weeks.
    private func pruneHistoryOnSettingsChange() {
        guard !AppSettings.shared.historyEnabled else { return }
        History.pruneOldEntries()
    }

    private func reconcileIfTranscriptionSettingsChanged() {
        let current = AppSettings.shared.transcriptionSettingsFingerprint
        guard current != lastServerSettings else { return }
        lastServerSettings = current
        localServer.reconcile()
    }

    /// Rebuilds the menu and the window content when the app language was changed.
    private var appliedLanguage = AppSettings.shared.resolvedAppLanguage

    private func applyLanguageIfChanged() {
        let lang = AppSettings.shared.resolvedAppLanguage
        guard lang != appliedLanguage else { return }
        appliedLanguage = lang
        rebuildMenu()
        if let mainWindow {
            let root = MainWindowView(state: mainWindowState) { [weak localServer] in
                localServer?.pid
            }
            mainWindow.contentViewController = NSHostingController(rootView: root)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // If the app is quit mid-dictation, do not leave paused music hanging.
        mediaController.restorePlayersSync()
        localServer.stop()
    }

    // MARK: - First-run tour

    /// Show it on the very first launch. Existing installations are recognized by
    /// the statistics file: whoever has dictated does not need the tour any more.
    private func shouldShowOnboarding() -> Bool {
        guard !AppSettings.shared.onboardingCompleted else { return false }
        if FileManager.default.fileExists(atPath: Stats.url.path) {
            AppSettings.shared.onboardingCompleted = true
            return false
        }
        return true
    }

    func showOnboarding() {
        if onboardingWindow?.isVisible != true { onboarding.reset() }
        if onboardingWindow == nil {
            let root = OnboardingView(model: onboarding) { [weak self] in
                self?.finishOnboarding()
            }
            let window = NSWindow(contentViewController: NSHostingController(rootView: root))
            window.title = "Orbly"
            window.identifier = NSUserInterfaceItemIdentifier(Self.onboardingWindowID)
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isReleasedWhenClosed = false
            // The tour is always dark, which suits the traffic light buttons too.
            window.appearance = NSAppearance(named: .darkAqua)
            window.delegate = self
            window.center()
            onboardingWindow = window
        }
        // While the tour is open, a dictation lands in the window instead of the
        // target app, on the pages before the test as well.
        onboarding.captureActive = true
        onboardingClosing = false
        // Fade in gently instead of popping up (only when not already visible).
        if onboardingWindow?.isVisible != true {
            onboardingWindow?.alphaValue = 0
        }
        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.32
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            onboardingWindow?.animator().alphaValue = 1
        }
    }

    private func finishOnboarding() {
        fadeOutOnboarding()
    }

    /// Fade out and only close afterwards, both through "Done"/"Skip" and through
    /// the red window button (see `windowShouldClose`).
    private func fadeOutOnboarding() {
        guard let window = onboardingWindow, window.isVisible, !onboardingClosing else { return }
        onboardingClosing = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.26
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, let window = self.onboardingWindow else { return }
            // The flag stays set until after close(): `close()` does not ask the
            // delegate (only `performClose(_:)` does), but if it did,
            // windowShouldClose lets it through thanks to the flag instead of
            window.close() // fading again. Also clears the flags through windowWillClose.
            self.onboardingClosing = false
            window.alphaValue = 1
        })
    }

    /// The red button does not close immediately, it starts the same fade-out.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === onboardingWindow else { return true }
        guard !onboardingClosing else { return true } // the fade-out is running
        fadeOutOnboarding()
        return false // the actual close() comes at the end of the animation
    }

    func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        if closing === donationWindow {
            // Only let go after closing: this is the last strong reference, and
            // AppKit keeps working after windowWillClose.
            DispatchQueue.main.async { [weak self] in self?.donationWindow = nil }
            return
        }
        guard closing === onboardingWindow else { return }
        onboarding.captureActive = false
        AppSettings.shared.onboardingCompleted = true
        // Really let the window go. Otherwise the whole SwiftUI tree of the tour
        // survives the session, including a running background animation.
        DispatchQueue.main.async { [weak self] in self?.onboardingWindow = nil }
    }

    // MARK: - Donation prompt

    /// Shows the donation prompt. The time is recorded immediately, so the 14 day
    /// pause also runs when the window is dismissed through the red button or the
    /// app is quit before that.
    func showDonationPrompt() {
        // Two seconds pass between the check and showing it. The tour may have
        // been opened in that time, and two windows on top of each other would
        // only be in the way.
        guard onboardingWindow?.isVisible != true else { return }
        AppSettings.shared.donationPromptLastShown = Date()
        let count = AppSettings.shared.dictationCount
        let root = DonationView(dictations: count) { [weak self] in
            self?.closeDonationPrompt()
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.title = "Orbly"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        // Like the tour: always dark, so the traffic light buttons fit.
        window.appearance = NSAppearance(named: .darkAqua)
        // Without a delegate nobody notices when the red button closes the
        // window: the reference stayed, the SwiftUI tree lived on and its
        // background animation ran for the rest of the session.
        window.delegate = self
        window.center()
        donationWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeDonationPrompt() {
        donationWindow?.close()
        donationWindow = nil
    }

    // MARK: - Permissions

    private func requestPermissions() {
        // Accessibility is needed independently of auto-insertion: without it
        // the global Fn key monitor delivers no events.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            axPromptShown = true // The dialog was just shown, do not show it again when inserting
            NSLog("Orbly: accessibility permission is still missing")
        }
        recorder.requestPermission { granted in
            if !granted {
                NSLog("Orbly: Mikrofon-Berechtigung fehlt")
            }
        }
    }

    // MARK: - Fn key handling

    private func handleFnDown() {
        switch state {
        case .idle:
            fnPressStarted = Date()
            toggleSession = false
            startDictation()
        case .recording:
            // Second Fn press ends a toggle session
            if toggleSession {
                stopAndTranscribe()
            }
        case .processing:
            break
        }
    }

    private func handleFnUp() {
        guard state == .recording, !toggleSession else { return }
        let held = Date().timeIntervalSince(fnPressStarted ?? Date())
        if held < 0.35 {
            // Short tap: switch to toggle mode, keep recording until next Fn tap
            toggleSession = true
        } else {
            // Push-to-talk: released after holding -> done
            stopAndTranscribe()
        }
    }

    private func handleOtherKeyDown(_ keyCode: UInt16) {
        // Esc cancels the processing too. Otherwise the user is stuck with a
        // server that does not answer until the timeout, and Fn does nothing.
        if keyCode == 53, state == .processing {
            dictationSession += 1 // discard a late answer
            // Really cancel the work in flight, do not just throw the result
            // away: otherwise an upload connection holding the complete
            // recording sits in memory until the timeout.
            transcriber.cancelCurrent()
            localServer.cancelWait()
            state = .idle
            overlay.setServerStarting(false)
            overlay.hide()
            if onboarding.captureActive { onboarding.cancelled() }
            updateStatus()
            return
        }
        guard state == .recording else { return }
        // Esc cancels any session
        if keyCode == 53 {
            cancelDictation()
            return
        }
        // The app's own simulated ⌘V comes back through the global monitor.
        // It must not cancel the next dictation.
        if TextInserter.isPasting { return }
        // Any key while Fn is held down: user is using Fn as a modifier
        // (Fn+arrows etc.) -> this was not a dictation attempt.
        if !toggleSession && fnMonitor.fnIsDown {
            cancelDictation()
        }
    }

    // MARK: - Dictation flow

    private func startDictation() {
        // Without the local engine or the model the user would otherwise speak a
        // whole dictation and only learn on release that nothing could be
        // recorded.
        if AppSettings.shared.mode == .local, let missing = localServer.missingRequirement() {
            report(error: missing)
            return
        }
        recorder.requestPermission { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.report(error: L10n.t("overlay.error.noMic"))
                return
            }
            // If the permission arrived asynchronously (first launch, permission
            // dialog), Fn was released long ago. Do not secretly keep recording.
            guard self.fnMonitor.fnIsDown else { return }
            do {
                try self.recorder.start()
                self.state = .recording
                self.dictationTargetApp = NSWorkspace.shared.frontmostApplication
                self.mediaController.duckOrPausePlayers()
                self.overlay.showRecording()
                if self.onboarding.captureActive { self.onboarding.begin() }
                self.updateStatus()
                self.localServer.noteActivity()
                // Cold start after an idle shutdown: the model loads while the user is
                // speaking, and the overlay pulses gently in the meantime as a hint.
                let coldStart = AppSettings.shared.mode == .local && !self.localServer.isRunning
                self.localServer.startIfNeeded()
                if coldStart { self.overlay.setServerStarting(true) }
                self.maxDurationTimer?.invalidate()
                self.maxDurationTimer = Timer.scheduledCommon(
                    every: self.maxRecordingSeconds, repeats: false
                ) { [weak self] _ in
                    self?.stopAndTranscribe()
                }
                self.startFnWatchdog()
            } catch {
                self.report(error: L10n.t("overlay.error.recordingFailed"))
                NSLog("Orbly: recorder start failed: \(error)")
            }
        }
    }

    /// Checks the real state of the Fn key during push-to-talk. If the user clicks
    /// into a password field mid-dictation, macOS turns secure input on and the
    /// monitor no longer sees the release. Without this watchdog the recording
    /// would run to the 10 minute limit and then be pasted somewhere.
    ///
    private func startFnWatchdog() {
        fnWatchdog?.invalidate()
        // Deliberately fail-safe: it only stops once the watchdog has seen the Fn
        // key held down at least once ITSELF. If `NSEvent.modifierFlags` reports
        // no `.function` on some keyboard, it never fires, and the app behaves as
        // before instead of choking off every dictation after 0.4 s.
        var sawFnHeld = false
        fnWatchdog = Timer.scheduledCommon(every: 0.4, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.state == .recording, !self.toggleSession else { return }
            if NSEvent.modifierFlags.contains(.function) {
                sawFnHeld = true
                return
            }
            guard sawFnHeld else { return }
            NSLog("Orbly: Fn release not received (secure input?), ending the dictation")
            self.stopAndTranscribe()
        }
    }

    private func cancelDictation() {
        maxDurationTimer?.invalidate()
        fnWatchdog?.invalidate()
        overlay.setServerStarting(false)
        mediaController.restorePlayers()
        recorder.cancel()
        state = .idle
        toggleSession = false
        overlay.hide()
        if onboarding.captureActive { onboarding.cancelled() }
        updateStatus()
    }

    /// Report errors where the user is looking: into the window during the tour,
    /// into the overlay otherwise.
    private func report(error message: String) {
        if onboarding.captureActive {
            overlay.hide()
            onboarding.fail(message)
        } else {
            overlay.showError(message)
        }
    }

    private func stopAndTranscribe() {
        guard state == .recording else { return }
        // Update the target app when Fn is released: the user may pick the target
        // window WHILE speaking. Nil fallback: keep the app remembered at the start.
        //
        if let front = NSWorkspace.shared.frontmostApplication {
            dictationTargetApp = front
        }
        maxDurationTimer?.invalidate()
        fnWatchdog?.invalidate()
        // Resume the music right when Fn is released, not after transcription.
        mediaController.restorePlayers()
        toggleSession = false
        let wavURL: URL
        switch recorder.stop() {
        case .file(let url):
            wavURL = url
        case .tooShort:
            state = .idle
            // Reset it, otherwise the overlay pulses in the "server starting" state
            // for the rest of the session: the path through waitUntilReady, which
            // normally does this, is never reached here.
            overlay.setServerStarting(false)
            updateStatus()
            // Wake-up press: the audio hardware was asleep and waking it up ate the
            // press. Say that it works now instead of disappearing without a word.
            //
            let wakeUp = WakeUpPress.shouldHint(
                recordingWasTooShort: true,
                audioWarmup: recorder.lastStartWarmupSeconds
            )
            if onboarding.captureActive {
                overlay.hide()
                // During the tour the note belongs in the window, where the user is looking.
                if wakeUp { onboarding.fail(L10n.t("overlay.hint.pressAgain")) } else { onboarding.cancelled() }
            } else if wakeUp {
                overlay.showHint(L10n.t("overlay.hint.pressAgain"))
            } else {
                // Fn only brushed: discard silently as before.
                overlay.hide()
            }
            return
        case .failed:
            // Recording failed (device change, disk full): do not discard it
            // silently, the user has just been speaking.
            state = .idle
            overlay.setServerStarting(false)
            updateStatus()
            report(error: L10n.t("overlay.error.recordingFailed"))
            return
        }

        state = .processing
        overlay.showProcessing()
        if onboarding.captureActive { onboarding.processing() }
        updateStatus()

        // The result of a test dictation belongs in the tour window. The state is
        // captured NOW: if the tour is closed during transcription, the test
        // dictation would otherwise be pasted and stored as a real one.
        let isOnboardingCapture = onboarding.captureActive
        let wasTruncated = recorder.lastRecordingWasTruncated
        dictationSession += 1
        let session = dictationSession
        let recordedSeconds = recorder.lastDurationSeconds
        // After an idle shutdown the local server may still be loading the model.
        // Only send once the port is open (otherwise connection refused).
        localServer.waitUntilReady { [weak self] ready in
            guard let self else { return }
            // Cancelled (Esc) or a new dictation started long ago. The recording
            // still has to go, it is a raw speech file.
            // `setServerStarting` belongs AFTER this check: a straggler would
            // otherwise have switched off the pulsing of the new dictation.
            guard session == self.dictationSession else {
                try? FileManager.default.removeItem(at: wavURL)
                return
            }
            // Always reset it, on failure too: otherwise the overlay pulses in the
            // "server starting" state for the rest of the session.
            self.overlay.setServerStarting(false)
            guard ready else {
                // Otherwise the recording is only deleted in the Transcriber, which is
                // never reached here. Raw speech must not stay behind.
                try? FileManager.default.removeItem(at: wavURL)
                self.state = .idle
                self.updateStatus()
                self.report(error: L10n.t("overlay.error.serverNotReady"))
                return
            }
            self.runTranscription(
                wavURL: wavURL, recordedSeconds: recordedSeconds,
                session: session, isOnboardingCapture: isOnboardingCapture,
                wasTruncated: wasTruncated
            )
        }
    }

    private func runTranscription(
        wavURL: URL, recordedSeconds: Double, session: Int, isOnboardingCapture: Bool,
        wasTruncated: Bool
    ) {
        transcriber.transcribe(wavURL: wavURL) { [weak self] result in
            guard let self else { return }
            // The user cancelled: discard the result, insert nothing.
            guard session == self.dictationSession else { return }
            self.state = .idle
            self.updateStatus()
            switch result {
            case .success(let text):
                // Test dictation of the tour: only show the result. No insertion, no
                // statistics, no history, it is a test and not a real dictation.
                if isOnboardingCapture {
                    self.overlay.hide()
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.onboarding.fail(L10n.t("onboarding.try.empty"))
                    } else {
                        self.onboarding.finish(text: text)
                    }
                    return
                }
                // Do not swallow an empty result without a word: whoever speaks too
                // quietly or has a muted microphone would otherwise just see the
                // overlay disappear and not know why.
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.overlay.showHint(L10n.t("overlay.hint.nothingHeard"), symbol: "waveform.slash")
                    return
                }
                Stats.record(text: text, seconds: recordedSeconds)
                // Only counts towards the donation prompt (Donation.swift).
                AppSettings.shared.dictationCount += 1
                // Bring open windows up to date: if the user dictates while the Orbly
                // window is in front, no focus change fires and both history and
                // statistics would stand still. Only announce it once the entry really
                // is written.
                let notifyWindows = {
                    NotificationCenter.default.post(
                        name: AppSettings.dictationRecordedNotification, object: nil
                    )
                }
                if AppSettings.shared.historyEnabled {
                    History.append(text, completion: notifyWindows)
                } else {
                    notifyWindows()
                }
                self.overlay.hide()
                if AppSettings.shared.autoInsert {
                    // Without feedback the dictation seems lost: the text showed up
                    // nowhere and sits only hidden in the clipboard. But if a new
                    // dictation is already running, that spot belongs to its recording
                    // overlay, not to this straggler.
                    let showClipboardHint = { [weak self] in
                        guard let self, session == self.dictationSession else { return }
                        self.overlay.showHint(
                            L10n.t("overlay.hint.inClipboard"), symbol: "doc.on.clipboard"
                        )
                    }
                    // If the recording was cut short by a device change, the second part
                    // of the dictation is missing. That has to be said.
                    let showTruncatedHint = { [weak self] in
                        guard let self, session == self.dictationSession else { return }
                        self.overlay.showHint(
                            L10n.t("overlay.hint.deviceChanged"), symbol: "mic.badge.xmark"
                        )
                    }
                    TextInserter.insert(text, targetApp: self.dictationTargetApp) { outcome in
                        switch outcome {
                        case .inserted:
                            if wasTruncated { showTruncatedHint() }
                        case .appSwitched, .noTextField:
                            showClipboardHint()
                        case .noPermission:
                            NSLog("Orbly: auto-insertion blocked, accessibility permission is missing")
                            showClipboardHint()
                            self.promptAccessibilityOnce()
                        }
                    }
                } else {
                    TextInserter.copyToClipboard(text)
                    if wasTruncated {
                        self.overlay.showHint(
                            L10n.t("overlay.hint.deviceChanged"), symbol: "mic.badge.xmark"
                        )
                    }
                }
            case .failure(let error):
                self.report(error: error.localizedDescription)
            }
        }
    }

    /// Shows the macOS dialog "Orbly wants to control this computer" when
    /// auto-insertion fails on the missing permission (after rebuilding or
    /// re-signing the app, for example). No popup of our own any more.
    private func promptAccessibilityOnce() {
        guard !axPromptShown else { return }
        axPromptShown = true
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Status item / menu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "waveform.circle",
                accessibilityDescription: "Orbly"
            )
        }
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let settingsItem = NSMenuItem(title: L10n.t("menu.settings"), action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settingsItem)
        let historyItem = NSMenuItem(title: L10n.t("tab.history.title"), action: #selector(openHistory), keyEquivalent: "")
        historyItem.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
        menu.addItem(historyItem)
        menu.addItem(.separator())
        statusMenuItem = NSMenuItem(title: L10n.t("menu.ready"), action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        ramMenuItem = NSMenuItem(title: L10n.t("menu.ram", "..."), action: nil, keyEquivalent: "")
        ramMenuItem.isEnabled = false
        menu.addItem(ramMenuItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L10n.t("menu.quit"), action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items where item.action != nil { item.target = self }
        menu.delegate = self
        statusItem.menu = menu
    }

    /// Updates the RAM line every time the menu opens (app plus the local server, if any).
    func menuWillOpen(_ menu: NSMenu) {
        guard menu == statusItem.menu else { return }
        let appPid = ProcessInfo.processInfo.processIdentifier
        let serverPid = localServer.pid
        var pids: [pid_t] = [appPid]
        if let serverPid { pids.append(serverPid) }
        MemoryUsage.residentBytes(pids: pids) { [weak self] result in
            guard let self, let appBytes = result[appPid] else { return }
            if let serverPid, let serverBytes = result[serverPid] {
                self.ramMenuItem.title = L10n.t(
                    "menu.ram.withServer",
                    MemoryUsage.format(appBytes),
                    MemoryUsage.format(serverBytes)
                )
            } else {
                self.ramMenuItem.title = L10n.t("menu.ram", MemoryUsage.format(appBytes))
            }
        }
    }

    private func updateStatus() {
        let modeText = AppSettings.shared.mode == .local ? L10n.t("mode.local") : L10n.t("mode.server")
        let symbol: String
        switch state {
        case .idle:
            // Without accessibility the Fn monitor delivers no events: Fn does
            // nothing at all. "Ready" would be a lie, and that has to be visible
            // here without opening the settings first.
            if !AXIsProcessTrusted() {
                statusMenuItem.title = L10n.t("menu.status.axMissing")
                symbol = "exclamationmark.triangle"
            } else {
                statusMenuItem.title = L10n.t("menu.status.idle", modeText)
                symbol = "waveform.circle"
            }
        case .recording:
            statusMenuItem.title = L10n.t("menu.status.recording")
            symbol = "record.circle"
        case .processing:
            statusMenuItem.title = L10n.t("menu.status.processing")
            symbol = "ellipsis.circle"
        }
        // Pass accessibilityDescription along: before this only the very first
        // image had a name, and every updateStatus() replaced it with nil.
        statusItem.button?.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: L10n.t("menu.accessibility.status", statusMenuItem.title)
        )
    }

    // MARK: - Menu actions

    @objc private func openSettings() {
        showMainWindow(tab: .settings)
    }

    private func showMainWindow(tab: MainTab) {
        mainWindowState.tab = tab
        if mainWindow == nil {
            let root = MainWindowView(state: mainWindowState) { [weak localServer] in
                localServer?.pid
            }
            let hosting = NSHostingController(rootView: root)
            let window = NSWindow(contentViewController: hosting)
            window.title = "Orbly"
            // Sidebar layout: the content runs up under the (invisible) title bar,
            // only the traffic light buttons stay visible.
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            // For the behind-window blur (the glass look) the window itself has to
            // be transparent. The content is drawn by the NSVisualEffectView.
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isReleasedWhenClosed = false
            window.center()
            mainWindow = window
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openHistory() {
        showMainWindow(tab: .history)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
