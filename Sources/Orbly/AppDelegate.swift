import AppKit
import SwiftUI
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    /// Sparkle-Auto-Updates (Feed & Signatur-Schlüssel stehen in der Info.plist).
    let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
    )
    private enum DictationState {
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
    /// Erst-Tour: eigenes Fenster, fängt währenddessen das Diktat-Ergebnis ab.
    let onboarding = OnboardingModel()
    private var onboardingWindow: NSWindow?
    /// Kennung des Tour-Fensters, damit der Pfeiltasten-Monitor der Tour nur auf
    /// Events aus genau diesem Fenster reagiert.
    static let onboardingWindowID = "orbly.onboarding"
    /// Verhindert, dass ein zweiter Klick das Ausblenden neu startet.
    private var onboardingClosing = false
    /// Spendenhinweis (siehe Donation.swift). Nur zeitweise offen.
    private var donationWindow: NSWindow?

    private var state: DictationState = .idle
    private var fnPressStarted: Date?
    private var toggleSession = false
    /// App, in der das Diktat gestartet wurde - nur dort wird eingefügt.
    private var dictationTargetApp: NSRunningApplication?
    private var maxDurationTimer: Timer?
    /// Zählt Diktate mit. Ein abgebrochenes Diktat lässt seine späte Antwort
    /// nicht mehr durch (sonst würde Text nach dem Abbruch noch eingefügt).
    private var dictationSession = 0
    /// Push-to-talk-Wache: Bei aktivem Secure Input (Passwortfeld) bekommt der
    /// globale Monitor das Loslassen von Fn nicht mehr - ohne diese Prüfung
    /// liefe die Aufnahme bis zum 10-Minuten-Limit und würde dann eingefügt.
    private var fnWatchdog: Timer?
    /// Obergrenze für vergessene Toggle-Aufnahmen (RAM wächst ~230 MB/h).
    private let maxRecordingSeconds: TimeInterval = 600
    /// System-Dialog für Bedienungshilfen nur einmal pro Sitzung zeigen.
    private var axPromptShown = false
    /// Für dieses Diktat musste der lokale Server erst hochfahren (Idle-Abschaltung).
    private var serverColdStartThisPress = false

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        enableAutomaticUpdateChecksByDefault()
        let showTour = shouldShowOnboarding()
        // Die Tour fragt die Berechtigungen selbst ab, mit Erklärung daneben -
        // sonst stehen beim allerersten Start zwei System-Dialoge im Raum,
        // bevor der Nutzer weiß, worum es überhaupt geht.
        if !showTour { requestPermissions() }
        localServer.reconcile()
        localServer.startIdleWatch()
        overlay.flashLaunched()
        // Verlauf altert aus: alte Diktate beim Start entfernen (Privatsphäre + Dateigröße).
        History.pruneOldEntries()
        // Liegengebliebene Aufnahmen früherer Abstürze wegräumen.
        AudioRecorder.sweepLeftoverRecordings()
        // Alte Einzeleinträge der Statistik verdichten, damit die Datei nicht
        // unbegrenzt wächst (Gesamtsummen bleiben exakt).
        Stats.compactOldEntries()

        recorder.onLevel = { [weak self] level in
            guard let self else { return }
            self.overlay.push(level: level)
            if self.onboarding.captureActive { self.onboarding.push(level: level) }
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
            self?.applyLanguageIfChanged()
            self?.updateStatus()
        }

        if showTour {
            showOnboarding()
        } else if Donation.shouldShowNow {
            // Kurz warten: Beim Start mit der Anmeldung soll nicht sofort ein
            // Fenster vor dem Schreibtisch stehen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.showDonationPrompt()
            }
        }
    }

    /// Automatische Update-Suche ist der Standard. Einmalig explizit setzen,
    /// solange der Nutzer nichts anderes gewählt hat - damit der Schalter auch
    /// bei Bestandsinstallationen sicher an steht und nicht nur „per Default".
    private func enableAutomaticUpdateChecksByDefault() {
        guard UserDefaults.standard.object(forKey: "SUEnableAutomaticChecks") == nil else { return }
        updaterController.updater.automaticallyChecksForUpdates = true
    }

    /// Zuletzt gesehener Stand der Einstellungen, die den lokalen Server betreffen.
    private var lastServerSettings = AppSettings.shared.transcriptionSettingsFingerprint

    /// Nur bei wirklich relevanten Änderungen den Server anfassen. Vorher startete
    /// JEDE Einstellungsänderung (auch Overlay-Stil oder Position) einen per
    /// Idle-Abschaltung schlafend gelegten Server samt 650 MB Modell neu.
    private func reconcileIfTranscriptionSettingsChanged() {
        let current = AppSettings.shared.transcriptionSettingsFingerprint
        guard current != lastServerSettings else { return }
        lastServerSettings = current
        localServer.reconcile()
    }

    /// Baut Menü und Fensterinhalt neu auf, wenn die App-Sprache gewechselt wurde.
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
        // Wird die App mitten im Diktat beendet, pausierte Musik nicht hängen lassen.
        mediaController.restorePlayersSync()
        localServer.stop()
    }

    // MARK: - Erst-Tour

    /// Beim allerersten Start zeigen. Bestandsinstallationen erkennen wir an der
    /// Statistik-Datei: Wer schon diktiert hat, braucht die Tour nicht mehr.
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
            // Die Tour ist immer dunkel - damit passen auch die Ampel-Buttons.
            window.appearance = NSAppearance(named: .darkAqua)
            window.delegate = self
            window.center()
            onboardingWindow = window
        }
        // Solange die Tour offen ist, landet ein Diktat im Fenster statt in der
        // Ziel-App - auch auf den Seiten vor dem Test.
        onboarding.captureActive = true
        onboardingClosing = false
        // Sanft einblenden statt aufpoppen (nur, wenn es nicht schon sichtbar ist).
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

    /// Ausblenden und erst danach schließen - sowohl über „Fertig"/„Überspringen"
    /// als auch über den roten Fensterknopf (siehe `windowShouldClose`).
    private func fadeOutOnboarding() {
        guard let window = onboardingWindow, window.isVisible, !onboardingClosing else { return }
        onboardingClosing = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.26
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, let window = self.onboardingWindow else { return }
            // Flag bleibt bis nach close() stehen: `close()` fragt den Delegate
            // zwar nicht (nur `performClose(_:)` tut das), aber falls doch,
            // lässt windowShouldClose dank des Flags durch statt neu zu faden.
            window.close() // setzt über windowWillClose auch die Flags
            self.onboardingClosing = false
            window.alphaValue = 1
        })
    }

    /// Der rote Knopf schließt nicht sofort, sondern startet dasselbe Ausblenden.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === onboardingWindow else { return true }
        guard !onboardingClosing else { return true } // Ausblenden ist durch
        fadeOutOnboarding()
        return false // das eigentliche close() kommt am Ende der Animation
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === onboardingWindow else { return }
        onboarding.captureActive = false
        AppSettings.shared.onboardingCompleted = true
    }

    // MARK: - Spendenhinweis

    /// Zeigt den Spendenhinweis. Der Zeitpunkt wird sofort festgehalten, damit
    /// die 14-Tage-Pause auch dann läuft, wenn das Fenster über den roten Knopf
    /// verschwindet oder die App vorher beendet wird.
    func showDonationPrompt() {
        // Zwischen Prüfung und Anzeige liegen zwei Sekunden: In der Zeit kann
        // die Tour geöffnet worden sein, und zwei Fenster übereinander wären nur
        // im Weg.
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
        // Wie die Tour: immer dunkel, damit die Ampel-Buttons passen.
        window.appearance = NSAppearance(named: .darkAqua)
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
        // Bedienungshilfen werden unabhängig vom Auto-Einfügen gebraucht:
        // ohne sie liefert der globale Fn-Tasten-Monitor keine Events.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            axPromptShown = true // Dialog kam gerade schon - nicht erneut beim Einfügen
            NSLog("Orbly: Bedienungshilfen-Berechtigung fehlt noch")
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
        // Esc bricht auch die Verarbeitung ab. Sonst hängt der Nutzer bei einem
        // nicht antwortenden Server bis zum Timeout fest und Fn tut nichts.
        if keyCode == 53, state == .processing {
            dictationSession += 1 // spätere Antwort verwerfen
            // Laufende Arbeit wirklich abbrechen, nicht nur das Ergebnis
            // wegwerfen: Sonst hängt eine Upload-Verbindung mit der kompletten
            // Aufnahme im Speicher bis zum Timeout.
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
        // Das simulierte ⌘V der App selbst kommt über den globalen Monitor
        // zurück - es darf das nächste Diktat nicht abbrechen.
        if TextInserter.isPasting { return }
        // Any key while Fn is held down: user is using Fn as a modifier
        // (Fn+arrows etc.) -> this was not a dictation attempt.
        if !toggleSession && fnMonitor.fnIsDown {
            cancelDictation()
        }
    }

    // MARK: - Dictation flow

    private func startDictation() {
        // Fehlt die lokale Engine oder das Modell, würde der Nutzer sonst ein
        // ganzes Diktat sprechen und erst beim Loslassen erfahren, dass nichts
        // aufgenommen werden konnte.
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
            // Kam die Freigabe asynchron (erster Start, Berechtigungsdialog),
            // ist Fn längst losgelassen - dann nicht heimlich weiter aufnehmen.
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
                // Kaltstart nach Idle-Abschaltung: Modell lädt, während der Nutzer
                // spricht - das Overlay pulsiert derweil sanft als Hinweis.
                let coldStart = AppSettings.shared.mode == .local && !self.localServer.isRunning
                self.serverColdStartThisPress = coldStart
                self.localServer.startIfNeeded()
                if coldStart { self.overlay.setServerStarting(true) }
                self.maxDurationTimer?.invalidate()
                self.maxDurationTimer = Timer.scheduledTimer(
                    withTimeInterval: self.maxRecordingSeconds, repeats: false
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

    /// Prüft während Push-to-talk den echten Zustand der Fn-Taste. Klickt der
    /// Nutzer mitten im Diktat in ein Passwortfeld, schaltet macOS Secure Input
    /// ein und der Monitor sieht das Loslassen nicht mehr. Ohne diese Wache
    /// liefe die Aufnahme bis zum 10-Minuten-Limit und würde dann irgendwo
    /// eingefügt.
    private func startFnWatchdog() {
        fnWatchdog?.invalidate()
        // Absichtlich fail-safe: Beendet wird erst, wenn die Wache die gedrückte
        // Fn-Taste vorher mindestens einmal SELBST gesehen hat. Meldet
        // `NSEvent.modifierFlags` auf einer Tastatur kein `.function`, feuert sie
        // nie - dann verhält sich die App wie vorher, statt jedes Diktat nach
        // 0,4 s abzuwürgen.
        var sawFnHeld = false
        fnWatchdog = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.state == .recording, !self.toggleSession else { return }
            if NSEvent.modifierFlags.contains(.function) {
                sawFnHeld = true
                return
            }
            guard sawFnHeld else { return }
            NSLog("Orbly: Fn-Loslassen nicht empfangen (Secure Input?) - Diktat wird beendet")
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

    /// Fehler dorthin melden, wo der Nutzer gerade hinschaut: während der Tour
    /// ins Fenster, sonst ins Overlay.
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
        // Ziel-App beim Loslassen von Fn aktualisieren: Der Nutzer darf das
        // Zielfenster auch erst WÄHREND des Sprechens auswählen. Nil-Fallback:
        // die beim Start gemerkte App behalten.
        if let front = NSWorkspace.shared.frontmostApplication {
            dictationTargetApp = front
        }
        maxDurationTimer?.invalidate()
        fnWatchdog?.invalidate()
        // Musik direkt beim Fn-Loslassen fortsetzen, nicht erst nach der Transkription.
        mediaController.restorePlayers()
        toggleSession = false
        let wavURL: URL
        switch recorder.stop() {
        case .file(let url):
            wavURL = url
        case .tooShort:
            state = .idle
            // Zurücksetzen, sonst pulsiert das Overlay den Rest der Sitzung im
            // „Server startet"-Zustand: Der Weg über waitUntilReady, der das sonst
            // erledigt, wird hier nie erreicht.
            overlay.setServerStarting(false)
            updateStatus()
            // Aufwachdruck: Die Audio-Hardware (und ggf. der lokale Server) lag im
            // Schlaf, das Aufwecken hat den Druck aufgefressen. Sagen, dass es
            // jetzt geht, statt kommentarlos zu verschwinden.
            let wakeUp = WakeUpPress.shouldHint(
                recordingWasTooShort: true,
                audioWarmup: recorder.lastStartWarmupSeconds,
                serverColdStart: serverColdStartThisPress
            )
            if onboarding.captureActive {
                overlay.hide()
                // In der Tour gehört der Hinweis ins Fenster, wo der Nutzer hinschaut.
                if wakeUp { onboarding.fail(L10n.t("overlay.hint.pressAgain")) } else { onboarding.cancelled() }
            } else if wakeUp {
                overlay.showHint(L10n.t("overlay.hint.pressAgain"))
            } else {
                // Fn nur gestreift: still verwerfen wie bisher.
                overlay.hide()
            }
            return
        case .failed:
            // Aufnahme fehlgeschlagen (Gerätewechsel, Platte voll): nicht
            // stillschweigend verwerfen - der Nutzer hat gerade gesprochen.
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

        // Ergebnis eines Testdiktats gehört ins Tour-Fenster. Der Zustand wird
        // JETZT festgehalten: Wird die Tour während der Transkription geschlossen,
        // würde das Testdiktat sonst als echtes Diktat eingefügt und gespeichert.
        let isOnboardingCapture = onboarding.captureActive
        dictationSession += 1
        let session = dictationSession
        let recordedSeconds = recorder.lastDurationSeconds
        // Nach einer Idle-Abschaltung lädt der lokale Server evtl. noch das
        // Modell - erst senden, wenn der Port offen ist (sonst Connection refused).
        localServer.waitUntilReady { [weak self] ready in
            guard let self else { return }
            // Immer zurücksetzen, auch beim Abbruch: Sonst pulsiert das Overlay
            // den Rest der Sitzung im „Server startet"-Zustand.
            self.overlay.setServerStarting(false)
            // Abgebrochen (Esc) oder längst ein neues Diktat gestartet.
            guard session == self.dictationSession else {
                try? FileManager.default.removeItem(at: wavURL)
                return
            }
            guard ready else {
                // Die Aufnahme wird sonst erst im Transcriber gelöscht - der hier
                // nie dran kommt. Rohe Sprachaufnahme darf nicht liegen bleiben.
                try? FileManager.default.removeItem(at: wavURL)
                self.state = .idle
                self.updateStatus()
                self.report(error: L10n.t("overlay.error.serverNotReady"))
                return
            }
            self.runTranscription(
                wavURL: wavURL, recordedSeconds: recordedSeconds,
                session: session, isOnboardingCapture: isOnboardingCapture
            )
        }
    }

    private func runTranscription(
        wavURL: URL, recordedSeconds: Double, session: Int, isOnboardingCapture: Bool
    ) {
        transcriber.transcribe(wavURL: wavURL) { [weak self] result in
            guard let self else { return }
            // Der Nutzer hat abgebrochen - Ergebnis verwerfen, nichts einfügen.
            guard session == self.dictationSession else { return }
            self.state = .idle
            self.updateStatus()
            switch result {
            case .success(let text):
                // Testdiktat der Tour: Ergebnis nur zeigen. Kein Einfügen, keine
                // Statistik, kein Verlauf - es ist ein Test, kein echtes Diktat.
                if isOnboardingCapture {
                    self.overlay.hide()
                    if text.isEmpty {
                        self.onboarding.fail(L10n.t("onboarding.try.empty"))
                    } else {
                        self.onboarding.finish(text: text)
                    }
                    return
                }
                if text.isEmpty {
                    self.overlay.hide()
                    return
                }
                Stats.record(text: text, seconds: recordedSeconds)
                // Zählt nur für den Spendenhinweis mit (Donation.swift).
                AppSettings.shared.dictationCount += 1
                // Offene Fenster nachziehen: Diktiert der Nutzer, während das
                // Orbly-Fenster vorne ist, feuert kein Fokuswechsel und Verlauf
                // wie Statistik blieben stehen. Erst melden, wenn der Eintrag
                // wirklich geschrieben ist.
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
                    switch TextInserter.insert(text, targetApp: self.dictationTargetApp) {
                    case .inserted, .appSwitched:
                        break // appSwitched: Text liegt in der Zwischenablage
                    case .noPermission:
                        NSLog("Orbly: Auto-Einfügen blockiert - Bedienungshilfen fehlen")
                        self.promptAccessibilityOnce()
                    }
                } else {
                    TextInserter.copyToClipboard(text)
                }
            case .failure(let error):
                self.report(error: error.localizedDescription)
            }
        }
    }

    /// Zeigt den macOS-Dialog "Orbly möchte diesen Computer steuern",
    /// wenn Auto-Einfügen an der fehlenden Berechtigung scheitert (z. B. nach
    /// Neubau/Neusignierung der App). Kein eigenes Popup mehr.
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
        ramMenuItem = NSMenuItem(title: L10n.t("menu.ram", "–"), action: nil, keyEquivalent: "")
        ramMenuItem.isEnabled = false
        menu.addItem(ramMenuItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L10n.t("menu.quit"), action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items where item.action != nil { item.target = self }
        menu.delegate = self
        statusItem.menu = menu
    }

    /// Aktualisiert die RAM-Zeile bei jedem Öffnen des Menüs (App + ggf. lokaler Server).
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
            // Ohne Bedienungshilfen liefert der Fn-Monitor keine Events: Fn tut
            // gar nichts. „Bereit" wäre dann eine Lüge - das muss man hier sehen,
            // ohne erst die Einstellungen zu öffnen.
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
        // accessibilityDescription mitgeben: Vorher stand nur beim allerersten
        // Bild ein Name, jedes updateStatus() ersetzte ihn durch nil.
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
            // Sidebar-Layout: Inhalt läuft bis unter die (unsichtbare) Titelleiste,
            // nur die Ampel-Buttons bleiben sichtbar.
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            // Für den Hinter-Fenster-Blur (Glassmorphism) muss das Fenster
            // selbst durchsichtig sein - den Inhalt malt die NSVisualEffectView.
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
