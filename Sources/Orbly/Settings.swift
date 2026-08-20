import Foundation
import ServiceManagement

enum TranscriptionMode: String {
    case local
    case server
}

/// What happens to music playing (Music/Spotify) while dictating.
enum MediaDictationMode: String {
    case off    // do nothing
    case duck   // turn down, turn back up afterwards (default)
    case pause  // pause, resume afterwards
}

extension Timer {
    /// Like `scheduledTimer`, but in the `.common` mode of the run loop.
    ///
    /// `Timer.scheduledTimer` only attaches itself to `.default`. As soon as a
    /// menu is open or the user scrolls or drags, the run loop switches to
    /// `.eventTracking` and the timer stands still. For safety nets like the Fn
    /// watchdog or the recording time limit, that is exactly the wrong moment to
    /// pause.
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

/// Language choice for dictation, the same list in settings and first-run tour.
enum SupportedLanguages {
    /// "Auto" is a real word and gets translated, the language codes do not.
    static var dictationOptions: [(value: String, label: String)] {
        [
            ("auto", L10n.t("settings.language.auto")), ("de", "DE"), ("en", "EN"),
            ("es", "ES"), ("fr", "FR"), ("ru", "RU"),
        ]
    }
}

/// "Start at login", operable in two places (settings, tour).
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static var isEnabled: Bool { status == .enabled }

    /// Registration is done, but macOS is still waiting for the user to confirm
    /// it (System Settings > General > Login Items). Happens among other things
    /// when it was declined there once before.
    static var needsApproval: Bool { status == .requiresApproval }

    /// What the switch should show: registered is registered, even when the
    /// confirmation is still missing. Otherwise it jumps back for no visible reason.
    static var isOn: Bool { isEnabled || needsApproval }

    /// Sets the state and returns what really holds afterwards. If registration
    /// fails, the switch jumps back instead of lying.
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
            NSLog("Orbly: registering the login item failed: \(error)")
        }
        // Do not return the wish, look at what the system says.
        return isOn
    }

    /// Open System Settings in the right place (Login Items).
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
        Self.repairLegacyModelPathIfNeeded(into: d)
    }

    /// A pass of its own with a marker of its own, explicitly NOT in
    /// `migrateLegacyDefaultsIfNeeded`.
    ///
    /// Versions 1.0.0 and 1.1.0 set that marker BEFORE they did the work. Whoever
    /// migrated back then has the marker at true and still a `modelPath` pointing
    /// at `.../FlowWhisper/models/...`. Exactly those users see "model missing"
    /// permanently although the file moved along with the folder. If the repair
    /// sat behind the old marker, it would never reach them of all people.
    ///
    private static func repairLegacyModelPathIfNeeded(into d: UserDefaults) {
        let markerKey = "repairedLegacyModelPath"
        guard !d.bool(forKey: markerKey) else { return }
        if let old = d.string(forKey: "modelPath"), old.contains("/FlowWhisper/") {
            let neu = old.replacingOccurrences(of: "/FlowWhisper/", with: "/Orbly/")
            d.set(neu, forKey: "modelPath")
            NSLog("Orbly: repaired a model path from the FlowWhisper days")
        }
        d.set(true, forKey: markerKey)
    }

    /// One-time takeover of all settings from before the rename (defaults domain
    /// com.louis.flowwhisper -> com.louis.orbly).
    private static func migrateLegacyDefaultsIfNeeded(into d: UserDefaults) {
        let markerKey = "migratedFromFlowWhisper"
        guard !d.bool(forKey: markerKey) else { return }
        let legacyPlist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.louis.flowwhisper.plist")
        guard let legacy = NSDictionary(contentsOf: legacyPlist) as? [String: Any] else {
            // Nothing to take over. Set the marker anyway, otherwise the old plist is
            // looked up again on EVERY launch.
            d.set(true, forKey: markerKey)
            return
        }
        for (key, value) in legacy where d.object(forKey: key) == nil {
            d.set(value, forKey: key)
        }
        // Only set the marker AFTER the work is done: a one-off read error would
        // otherwise have prevented the takeover forever.
        d.set(true, forKey: markerKey)
        NSLog("Orbly: \(legacy.count) settings taken over from FlowWhisper")
    }

    var mode: TranscriptionMode {
        get { TranscriptionMode(rawValue: d.string(forKey: "mode") ?? "local") ?? .local }
        set { d.set(newValue.rawValue, forKey: "mode") }
    }

    /// Your own transcription server. The default is EMPTY: this used to hold the
    /// address from the developer's own setup (`http://ubuntu-server:8643`).
    /// "ubuntu-server" is the default host name of every Ubuntu Server install, so
    /// in server mode the recording would have gone in the clear to some machine
    /// on the same network.
    var serverURL: String {
        get {
            let stored = d.string(forKey: "serverURL")
            // Existing installations: the old default pointed at port 8642,
            // the installer uses 8643.
            if stored == "http://ubuntu-server:8642/inference" {
                return "http://ubuntu-server:8643/inference"
            }
            return stored ?? ""
        }
        set { d.set(newValue, forKey: "serverURL") }
    }

    /// Keep dictations in the history (plain text on disk).
    var historyEnabled: Bool {
        get { d.object(forKey: "historyEnabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "historyEnabled") }
    }

    /// Insert the text into the active window automatically after a dictation
    /// (simulated Cmd+V). Off = the text only goes to the clipboard.
    var autoInsert: Bool {
        get { d.object(forKey: "autoInsert") as? Bool ?? true }
        set { d.set(newValue, forKey: "autoInsert") }
    }

    /// Turn playing music (Music/Spotify) down while dictating, pause it, or leave it alone.
    var mediaDuringDictation: MediaDictationMode {
        get {
            if let raw = d.string(forKey: "mediaDuringDictation") {
                return MediaDictationMode(rawValue: raw) ?? .duck
            }
            // Migration from the short-lived boolean switch (was: pause on/off).
            if d.object(forKey: "pauseMediaDuringDictation") as? Bool == true { return .pause }
            return .duck
        }
        set { d.set(newValue.rawValue, forKey: "mediaDuringDictation") }
    }

    /// Stop the local whisper-server after 3 minutes without a dictation (frees
    /// about 650 MB). On the next Fn press it restarts automatically and loads the
    /// model while you are speaking. Default ON: at about 0.7 s the cold start is
    /// shorter than any dictation and therefore not noticeable.
    var serverIdleShutdown: Bool {
        get { d.object(forKey: "serverIdleShutdown") as? Bool ?? true }
        set { d.set(newValue, forKey: "serverIdleShutdown") }
    }

    /// Detection language for dictation: "auto" or an ISO code (de/en/es/fr/ru).
    ///
    /// The default is "auto", not "de". Before this every fresh installation
    /// worldwide got German: on an English Mac `language=de` went to whisper, and
    /// the model recommendation suggested the German fine-tune to everyone.
    var language: String {
        get { d.string(forKey: "language") ?? "auto" }
        set { d.set(newValue, forKey: "language") }
    }

    /// First-run tour already shown (or skipped).
    var onboardingCompleted: Bool {
        get { d.bool(forKey: "onboardingCompleted") }
        set { d.set(newValue, forKey: "onboardingCompleted") }
    }

    // MARK: - Donation prompt (the rules live in Donation.swift)

    /// Confirmed by the user: "I donated". After that the prompt never comes back.
    var hasDonated: Bool {
        get { d.bool(forKey: "hasDonated") }
        set { d.set(newValue, forKey: "hasDonated") }
    }

    /// "Do not ask again" in the donation window.
    var donationPromptDisabled: Bool {
        get { d.bool(forKey: "donationPromptDisabled") }
        set { d.set(newValue, forKey: "donationPromptDisabled") }
    }

    /// When the prompt was last seen.
    var donationPromptLastShown: Date? {
        get { d.object(forKey: "donationPromptLastShown") as? Date }
        set { d.set(newValue, forKey: "donationPromptLastShown") }
    }

    /// Number of finished dictations. Only a counter for the donation prompt,
    /// deliberately not read from the statistics: those live in a file that may be
    /// deleted, and evaluating them runs asynchronously.
    var dictationCount: Int {
        get { d.integer(forKey: "dictationCount") }
        set { d.set(newValue, forKey: "dictationCount") }
    }

    /// UI language of the app: "auto" (= system language) or an ISO code (en/de/es/fr/ru).
    var appLanguage: String {
        get { d.string(forKey: "appLanguage") ?? "auto" }
        set { d.set(newValue, forKey: "appLanguage") }
    }

    /// Resolved UI language (system language when "auto").
    var resolvedAppLanguage: String {
        appLanguage == "auto" ? AppSettings.systemLanguage : appLanguage
    }

    /// First supported language from the system language settings, English otherwise.
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
            // The default is the monochrome orb (design language: monochrome + 1 accent).
            let raw = d.string(forKey: "overlayStyle") ?? "orbMono"
            // Migration: "pillSmall" is called "pill" now, the old large pill is gone.
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

    /// Determined once and then remembered. Before this a folder check ran on
    /// EVERY access, and the getter sits in `WhisperModel.localPath` among other
    /// places, which SwiftUI calls constantly while drawing the model list. On top
    /// of that the migration ran from several queues at the same time.
    private static let resolvedAppSupportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let dir = base.appendingPathComponent("Orbly", isDirectory: true)
        // One-time migration from before the rename (FlowWhisper -> Orbly): simply
        // take models, history and statistics along instead of downloading again.
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

    /// Deletes everything Orbly stored on this Mac: history, statistics, log and
    /// all settings. Models stay (up to 1.6 GB of download) and are reported
    /// separately, so nobody accidentally re-downloads for hours.
    /// Returns how many bytes the models still occupy.
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

        // Settings including the old FlowWhisper domain.
        for domain in ["com.louis.orbly", "com.louis.flowwhisper"] {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        Stats.invalidateCache()
        // Set the marker again: it was just deleted along with the rest, and on the
        // next launch the migration would have pulled the settings we just deleted
        // back out of the old plist. "Delete all data" has to be final.
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

    /// True when the address is unencrypted http to ANOTHER machine. Loopback is
    /// harmless (it never leaves the Mac), everything else transmits the recording
    /// in the clear.
    static func isInsecureRemoteEndpoint(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespaces)),
              url.scheme?.lowercased() == "http",
              let host = url.host?.lowercased() else { return false }
        let lokal = ["127.0.0.1", "localhost", "::1", "0.0.0.0"]
        return !lokal.contains(host)
    }

    /// Everything that concerns the local whisper-server. If this does not change,
    /// it does not need to be restarted either.
    var transcriptionSettingsFingerprint: String {
        "\(mode.rawValue)|\(modelPath)|\(localPort)|\(serverURL)"
    }

    func notifyChanged() {
        NotificationCenter.default.post(name: AppSettings.changedNotification, object: nil)
    }

    /// Posted after every saved dictation, so open windows (overview, history)
    /// refresh immediately instead of only when the focus changes.
    static let dictationRecordedNotification = Notification.Name("OrblyDictationRecorded")
}
