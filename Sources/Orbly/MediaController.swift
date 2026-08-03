import AppKit

/// Macht laufende Musik-Apps beim Diktatstart leiser (Ducking) oder pausiert
/// sie - je nach Setting `mediaDuringDictation` - und stellt danach alles
/// wieder her.
///
/// Steuerung per Apple Events über `osascript` als Kindprozess - NSAppleScript
/// ist nicht threadsicher, und der einmalige macOS-Berechtigungsdialog
/// ("Orbly möchte Musik steuern") darf den Main-Thread nicht blockieren.
final class MediaController {
    private struct Player {
        let bundleID: String
        /// Name im AppleScript-`tell` (nicht der Anzeigename).
        let scriptName: String
    }

    private enum Action {
        case paused
        case ducked(original: Int, ducked: Int)
    }

    private static let players = [
        Player(bundleID: "com.apple.Music", scriptName: "Music"),
        Player(bundleID: "com.spotify.client", scriptName: "Spotify"),
    ]

    /// Nur was WIR verändert haben, wird wiederhergestellt.
    private var actions: [(player: Player, action: Action)] = []
    /// Seriell: restore wartet damit automatisch, bis das Ducking fertig ist.
    private let queue = DispatchQueue(label: "Orbly.MediaController")

    func duckOrPausePlayers() {
        let mode = AppSettings.shared.mediaDuringDictation
        guard mode != .off else { return }
        queue.async {
            for player in Self.players where Self.isRunning(player.bundleID) {
                let base = "tell application \"\(player.scriptName)\""
                guard Self.runScript("\(base) to player state as string") == "playing" else { continue }
                switch mode {
                case .pause:
                    // Nur bei ERFOLGREICHEM Befehl merken - sonst würden wir eine
                    // später vom Nutzer selbst pausierte App fälschlich wieder starten.
                    if Self.runScript("\(base) to pause") != nil {
                        self.actions.append((player, .paused))
                    }
                case .duck:
                    guard let volText = Self.runScript("\(base) to sound volume"),
                          let volume = Int(volText),
                          volume > 10 else { continue } // schon leise -> nichts tun
                    let target = max(5, volume / 2)
                    if Self.runScript("\(base) to set sound volume to \(target)") != nil {
                        self.actions.append((player, .ducked(original: volume, ducked: target)))
                    }
                case .off:
                    break
                }
            }
        }
    }

    func restorePlayers() {
        queue.async { self.restoreLocked() }
    }

    /// Blockierende Variante für applicationWillTerminate - queue.async käme
    /// vor dem Prozessende nicht mehr zum Zug.
    func restorePlayersSync() {
        queue.sync { self.restoreLocked() }
    }

    /// Nur auf `queue` aufrufen.
    private func restoreLocked() {
        for (player, action) in actions where Self.isRunning(player.bundleID) {
            let base = "tell application \"\(player.scriptName)\""
            switch action {
            case .paused:
                // Nur fortsetzen, wenn noch pausiert - hat der Nutzer inzwischen
                // selbst eingegriffen (z. B. bewusst gestoppt), nicht überstimmen.
                if Self.runScript("\(base) to player state as string") == "paused" {
                    Self.runScript("\(base) to play")
                }
            case .ducked(let original, let ducked):
                // Nur zurückdrehen, wenn die Lautstärke noch (ungefähr) unser
                // Duck-Wert ist - Spotify rundet gesetzte Werte leicht, und
                // manuelle Änderungen des Nutzers überstimmen wir nicht.
                if let volText = Self.runScript("\(base) to sound volume"),
                   let volume = Int(volText),
                   abs(volume - ducked) <= 5 {
                    Self.runScript("\(base) to set sound volume to \(original)")
                }
            }
        }
        actions.removeAll()
    }

    private static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Führt AppleScript aus und liefert stdout (getrimmt), nil bei Fehler.
    @discardableResult
    private static func runScript(_ source: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            NSLog("Orbly: MediaController osascript failed: \(error)")
            return nil
        }
    }
}
