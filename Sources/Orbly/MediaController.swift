import AppKit

/// Turns running music apps down when a dictation starts (ducking) or pauses
/// them, depending on the `mediaDuringDictation` setting, and restores
/// everything afterwards.
///
/// Controlled through Apple events via `osascript` as a child process:
/// NSAppleScript is not thread safe, and the one-time macOS permission dialog
/// ("Orbly wants to control Music") must not block the main thread.
final class MediaController {
    private struct Player {
        let bundleID: String
        /// Name used in the AppleScript `tell` (not the display name).
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

    /// Only what WE changed gets restored.
    private var actions: [(player: Player, action: Action)] = []
    /// Serial: restore therefore waits automatically until ducking is done.
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
                    // Only remember it on a SUCCESSFUL command, otherwise we would
                    // wrongly restart an app the user paused themselves later.
                    if Self.runScript("\(base) to pause") != nil {
                        self.actions.append((player, .paused))
                    }
                case .duck:
                    guard let volText = Self.runScript("\(base) to sound volume"),
                          let volume = Int(volText),
                          volume > 10 else { continue } // already quiet -> do nothing
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

    /// Blocking variant for applicationWillTerminate: queue.async would not get
    /// its turn before the process ends.
    func restorePlayersSync() {
        queue.sync { self.restoreLocked() }
    }

    /// Only call this on `queue`.
    private func restoreLocked() {
        for (player, action) in actions where Self.isRunning(player.bundleID) {
            let base = "tell application \"\(player.scriptName)\""
            switch action {
            case .paused:
                // Only resume when still paused. If the user has intervened in the
                // meantime (deliberately stopped it), do not overrule them.
                if Self.runScript("\(base) to player state as string") == "paused" {
                    Self.runScript("\(base) to play")
                }
            case .ducked(let original, let ducked):
                // Only turn it back up when the volume still is (roughly) our duck
                // value. Spotify rounds values it is given slightly, and we do not
                // overrule manual changes by the user.
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

    /// Runs AppleScript and returns stdout (trimmed), nil on error.
    @discardableResult
    private static func runScript(_ source: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let pipe = Pipe()
        process.standardOutput = pipe
        // nullDevice instead of Pipe(): a pipe nobody reads from fills up and
        // then blocks the child process on writing.
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            // Read first, then wait. The other way round is the classic deadlock
            // order: if the child writes more than the pipe buffer, it waits for
            // the buffer to drain while we wait for it to exit. This serial queue
            // would then stall for good, the music would never come back and
            // quitting the app would hang.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            NSLog("Orbly: MediaController osascript failed: \(error)")
            return nil
        }
    }
}
