import Foundation
import ServiceManagement

enum TranscriptionMode: String {
    case local
    case server
}

/// Was mit laufender Musik (Music/Spotify) beim Diktieren passiert.
enum MediaDictationMode: String {
    case off    // nichts tun
    case duck   // leiser machen, danach zurückdrehen (Standard)
    case pause  // pausieren, danach weiterspielen
}

extension Timer {
    /// Wie `scheduledTimer`, aber im `.common`-Modus der Ereignisschleife.
    ///
    /// `Timer.scheduledTimer` hängt sich nur in `.default`. Sobald ein Menü offen
    /// ist oder der Nutzer scrollt oder zieht, wechselt der RunLoop nach
    /// `.eventTracking` und der Timer steht still. Für Sicherheitsnetze wie den
    /// Fn-Wächter oder das Aufnahme-Zeitlimit ist genau das der falsche Moment
    /// zum Pausieren.
    static func scheduledCommon(
        every interval: TimeInterval, repeats: Bool,
        tolerance: TimeInterval = 0,
        _ block: @escaping (Timer) -> Void
    ) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: repeats, block: block)
        timer.tolerance = tolerance
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}

/// Sprachauswahl fürs Diktat - dieselbe Liste in Einstellungen und Erst-Tour.
enum SupportedLanguages {
    /// „Auto" ist ein echtes Wort und wird übersetzt, die Sprachkürzel nicht.
    static var dictationOptions: [(value: String, label: String)] {
        [
            ("auto", L10n.t("settings.language.auto")), ("de", "DE"), ("en", "EN"),
            ("es", "ES"), ("fr", "FR"), ("ru", "RU"),
        ]
    }
}

/// „Beim Anmelden starten" - an zwei Stellen bedienbar (Einstellungen, Tour).
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static var isEnabled: Bool { status == .enabled }

    /// Registrierung steht, aber macOS wartet noch auf die Bestätigung des
    /// Nutzers (Systemeinstellungen → Allgemein → Anmeldeobjekte). Passiert
    /// u. a., wenn dort früher einmal abgelehnt wurde.
    static var needsApproval: Bool { status == .requiresApproval }

    /// Was der Schalter zeigen soll: registriert ist registriert, auch wenn die
    /// Bestätigung noch fehlt. Sonst springt er scheinbar grundlos zurück.
    static var isOn: Bool { isEnabled || needsApproval }

    /// Setzt den Zustand und liefert zurück, was danach wirklich gilt - schlägt
    /// die Registrierung fehl, springt der Schalter zurück statt zu lügen.
    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        guard enabled != isOn else { return isOn }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Orbly: Login-Item fehlgeschlagen: \(error)")
        }
        // Nicht den Wunsch zurückgeben, sondern nachsehen, was das System sagt.
        return isOn
    }

    /// Systemeinstellungen an der richtigen Stelle öffnen (Anmeldeobjekte).
    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

final class AppSettings {
    static let shared = AppSettings()
    static let changedNotification = Notification.Name("OrblySettingsChanged")

    private let d = UserDefaults.standard

    private init() {
        Self.migrateLegacyDefaultsIfNeeded(into: d)
    }

    /// Einmalige Übernahme aller Einstellungen aus der Zeit vor der Umbenennung
    /// (Defaults-Domain com.louis.flowwhisper -> com.louis.orbly).
    private static func migrateLegacyDefaultsIfNeeded(into d: UserDefaults) {
        let markerKey = "migratedFromFlowWhisper"
        guard !d.bool(forKey: markerKey) else { return }
        let legacyPlist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.louis.flowwhisper.plist")
        guard let legacy = NSDictionary(contentsOf: legacyPlist) as? [String: Any] else { return }
        for (key, value) in legacy where d.object(forKey: key) == nil {
            d.set(value, forKey: key)
        }
        // Der Ordner heißt jetzt Orbly (siehe appSupportDir). Ein übernommener
        // modelPath zeigte sonst weiter auf .../FlowWhisper/models/... und der
        // Nutzer sah „Modell fehlt", obwohl die Datei mitgewandert ist.
        if let old = d.string(forKey: "modelPath"), old.contains("/FlowWhisper/") {
            d.set(old.replacingOccurrences(of: "/FlowWhisper/", with: "/Orbly/"), forKey: "modelPath")
        }
        // Marker erst NACH getaner Arbeit setzen: Ein einmaliger Lesefehler hätte
        // die Übernahme sonst für immer verhindert.
        d.set(true, forKey: markerKey)
        NSLog("Orbly: \(legacy.count) Einstellungen von FlowWhisper übernommen")
    }

    var mode: TranscriptionMode {
        get { TranscriptionMode(rawValue: d.string(forKey: "mode") ?? "local") ?? .local }
        set { d.set(newValue.rawValue, forKey: "mode") }
    }

    /// Eigener Transkriptions-Server. Standard ist LEER: Vorher stand hier die
    /// Adresse aus dem Setup des Entwicklers (`http://ubuntu-server:8643`).
    /// „ubuntu-server" ist der Standard-Rechnername jeder Ubuntu-Server-Installation,
    /// im Servermodus wäre die Aufnahme also im Klartext an irgendeinen Rechner im
    /// selben Netz gegangen.
    var serverURL: String {
        get {
            let stored = d.string(forKey: "serverURL")
            // Bestandsinstallationen: alter Default zeigte auf Port 8642,
            // der Installer nutzt 8643.
            if stored == "http://ubuntu-server:8642/inference" {
                return "http://ubuntu-server:8643/inference"
            }
            return stored ?? ""
        }
        set { d.set(newValue, forKey: "serverURL") }
    }

    /// Diktate in Verlauf.md mitschreiben (Klartext auf der Platte).
    var historyEnabled: Bool {
        get { d.object(forKey: "historyEnabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "historyEnabled") }
    }

    /// Text nach dem Diktat automatisch ins aktive Fenster einfügen (simuliertes Cmd+V).
    /// Aus = Text landet nur in der Zwischenablage.
    var autoInsert: Bool {
        get { d.object(forKey: "autoInsert") as? Bool ?? true }
        set { d.set(newValue, forKey: "autoInsert") }
    }

    /// Laufende Musik (Music/Spotify) beim Diktieren leiser machen, pausieren oder in Ruhe lassen.
    var mediaDuringDictation: MediaDictationMode {
        get {
            if let raw = d.string(forKey: "mediaDuringDictation") {
                return MediaDictationMode(rawValue: raw) ?? .duck
            }
            // Migration vom kurzlebigen Bool-Schalter (war: Pausieren an/aus).
            if d.object(forKey: "pauseMediaDuringDictation") as? Bool == true { return .pause }
            return .duck
        }
        set { d.set(newValue.rawValue, forKey: "mediaDuringDictation") }
    }

    /// Lokalen whisper-server nach 3 min ohne Diktat beenden (gibt ~650 MB
    /// frei); beim nächsten Fn-Druck startet er automatisch neu und lädt das
    /// Modell, während gesprochen wird. Standard AN - der Kaltstart ist mit
    /// ~0,7 s kürzer als jedes Diktat und dadurch nicht spürbar.
    var serverIdleShutdown: Bool {
        get { d.object(forKey: "serverIdleShutdown") as? Bool ?? true }
        set { d.set(newValue, forKey: "serverIdleShutdown") }
    }

    /// Erkennungssprache fürs Diktat: "auto" oder ISO-Code (de/en/es/fr/ru).
    ///
    /// Standard ist "auto", nicht "de". Vorher bekam jede frische Installation
    /// weltweit Deutsch: Auf einem englischen Mac ging `language=de` an whisper,
    /// und die Modell-Empfehlung schlug allen das deutsche Fine-Tune vor.
    var language: String {
        get { d.string(forKey: "language") ?? "auto" }
        set { d.set(newValue, forKey: "language") }
    }

    /// Erst-Tour bereits gezeigt (oder übersprungen).
    var onboardingCompleted: Bool {
        get { d.bool(forKey: "onboardingCompleted") }
        set { d.set(newValue, forKey: "onboardingCompleted") }
    }

    // MARK: - Spendenhinweis (Regeln stehen in Donation.swift)

    /// Selbst bestätigt: „Ich habe gespendet". Danach kommt der Hinweis nie wieder.
    var hasDonated: Bool {
        get { d.bool(forKey: "hasDonated") }
        set { d.set(newValue, forKey: "hasDonated") }
    }

    /// „Nicht mehr fragen" im Spendenfenster.
    var donationPromptDisabled: Bool {
        get { d.bool(forKey: "donationPromptDisabled") }
        set { d.set(newValue, forKey: "donationPromptDisabled") }
    }

    /// Wann der Hinweis zuletzt zu sehen war.
    var donationPromptLastShown: Date? {
        get { d.object(forKey: "donationPromptLastShown") as? Date }
        set { d.set(newValue, forKey: "donationPromptLastShown") }
    }

    /// Zahl der abgeschlossenen Diktate. Nur ein Zähler für den Spendenhinweis,
    /// bewusst nicht aus der Statistik gelesen: die liegt in einer Datei, die
    /// gelöscht werden darf, und ihre Auswertung läuft asynchron.
    var dictationCount: Int {
        get { d.integer(forKey: "dictationCount") }
        set { d.set(newValue, forKey: "dictationCount") }
    }

    /// UI-Sprache der App: "auto" (= Systemsprache) oder ISO-Code (en/de/es/fr/ru).
    var appLanguage: String {
        get { d.string(forKey: "appLanguage") ?? "auto" }
        set { d.set(newValue, forKey: "appLanguage") }
    }

    /// Aufgelöste UI-Sprache (Systemsprache, wenn "auto").
    var resolvedAppLanguage: String {
        appLanguage == "auto" ? AppSettings.systemLanguage : appLanguage
    }

    /// Erste unterstützte Sprache aus den System-Spracheinstellungen, sonst Englisch.
    static var systemLanguage: String {
        let supported = ["en", "de", "es", "fr", "ru"]
        for lang in Locale.preferredLanguages {
            let code = String(lang.prefix(2)).lowercased()
            if supported.contains(code) { return code }
        }
        return "en"
    }

    /// Optional model name for OpenAI-compatible servers (speaches etc.).
    /// Empty = not sent (whisper.cpp servers don't need it).
    var serverModelName: String {
        get { d.string(forKey: "serverModelName") ?? "" }
        set { d.set(newValue, forKey: "serverModelName") }
    }

    var overlayStyle: OverlayStyle {
        get {
            // Standard ist der monochrome Orb (Design-Sprache: monochrom + 1 Akzent).
            let raw = d.string(forKey: "overlayStyle") ?? "orbMono"
            // Migration: "pillSmall" heißt jetzt "pill", die alte große Pill entfällt.
            return OverlayStyle(rawValue: raw == "pillSmall" ? "pill" : raw) ?? .orbMono
        }
        set { d.set(newValue.rawValue, forKey: "overlayStyle") }
    }

    var overlayPosition: OverlayPosition {
        get { OverlayPosition(rawValue: d.string(forKey: "overlayPosition") ?? "bottomCenter") ?? .bottomCenter }
        set { d.set(newValue.rawValue, forKey: "overlayPosition") }
    }

    var modelPath: String {
        get { d.string(forKey: "modelPath") ?? AppSettings.defaultModelPath }
        set { d.set(newValue, forKey: "modelPath") }
    }

    /// Einmal ermittelt und dann gemerkt. Vorher lief bei JEDEM Zugriff eine
    /// Ordnerprüfung, und der Getter steckt u. a. in `WhisperModel.localPath`,
    /// das SwiftUI beim Zeichnen der Modell-Liste laufend aufruft. Dazu kam die
    /// Migration von mehreren Queues gleichzeitig.
    private static let resolvedAppSupportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let dir = base.appendingPathComponent("Orbly", isDirectory: true)
        // Einmalige Migration von der Zeit vor der Umbenennung (FlowWhisper -> Orbly):
        // Modelle, Verlauf und Statistik einfach mitnehmen statt neu herunterladen.
        let legacy = base.appendingPathComponent("FlowWhisper", isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path), fm.fileExists(atPath: legacy.path) {
            try? fm.moveItem(at: legacy, to: dir)
        }
        return dir
    }()

    static var appSupportDir: URL { resolvedAppSupportDir }

    static var defaultModelPath: String {
        appSupportDir.appendingPathComponent("models/ggml-large-v3-turbo-q5_0.bin").path
    }

    let localPort = 8642
    var localURL: String { "http://127.0.0.1:\(localPort)/inference" }
    var activeEndpoint: String { mode == .local ? localURL : serverURL }

    /// Löscht alles, was Orbly auf diesem Mac gespeichert hat: Verlauf,
    /// Statistik, Log und alle Einstellungen. Modelle bleiben (bis 1,6 GB
    /// Download) und werden separat gemeldet, damit niemand versehentlich
    /// stundenlang neu herunterlädt.
    /// Liefert zurück, wie viele Bytes die Modelle noch belegen.
    @discardableResult
    static func deleteAllData(includingModels: Bool) -> UInt64 {
        let fm = FileManager.default
        let dir = appSupportDir
        let modelsDir = dir.appendingPathComponent("models", isDirectory: true)
        let modelBytes = directorySize(modelsDir)

        for name in ["history.jsonl", "stats.jsonl", "stats-archive.json", "Verlauf.md"] {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
        if includingModels {
            try? fm.removeItem(at: modelsDir)
        }
        let log = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Orbly", isDirectory: true)
        try? fm.removeItem(at: log)

        // Einstellungen inklusive der alten FlowWhisper-Domain.
        for domain in ["com.louis.orbly", "com.louis.flowwhisper"] {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        Stats.invalidateCache()
        // Marker neu setzen: Er wurde gerade mitgelöscht, und beim nächsten Start
        // hätte die Migration die eben gelöschten Einstellungen aus der alten
        // Plist zurückgeholt. „Alle Daten löschen" muss endgültig sein.
        UserDefaults.standard.set(true, forKey: "migratedFromFlowWhisper")
        UserDefaults.standard.synchronize()
        return includingModels ? 0 : modelBytes
    }

    private static func directorySize(_ url: URL) -> UInt64 {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        var total: UInt64 = 0
        for file in files {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey])
            guard let size = values?.fileSize, size > 0 else { continue }
            total += UInt64(size)
        }
        return total
    }

    /// True, wenn die Adresse unverschlüsseltes http auf einen ANDEREN Rechner
    /// ist. Loopback ist unkritisch (verlässt den Mac nicht), alles andere
    /// überträgt die Aufnahme im Klartext.
    static func isInsecureRemoteEndpoint(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespaces)),
              url.scheme?.lowercased() == "http",
              let host = url.host?.lowercased() else { return false }
        let lokal = ["127.0.0.1", "localhost", "::1", "0.0.0.0"]
        return !lokal.contains(host)
    }

    /// Alles, was den lokalen whisper-server betrifft. Ändert sich das nicht,
    /// muss er auch nicht neu gestartet werden.
    var transcriptionSettingsFingerprint: String {
        "\(mode.rawValue)|\(modelPath)|\(localPort)|\(serverURL)"
    }

    func notifyChanged() {
        NotificationCenter.default.post(name: AppSettings.changedNotification, object: nil)
    }

    /// Wird nach jedem gespeicherten Diktat gepostet, damit offene Fenster
    /// (Übersicht, Verlauf) sich sofort aktualisieren statt erst beim Fokuswechsel.
    static let dictationRecordedNotification = Notification.Name("OrblyDictationRecorded")
}
