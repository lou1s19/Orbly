import Foundation

/// Launches and supervises a local whisper-server (whisper.cpp) so the model
/// stays loaded between dictations. Only used in `.local` mode.
final class LocalServerManager {
    private var process: Process?
    var isRunning: Bool { process?.isRunning ?? false }
    /// PID of the running whisper-server (for the RAM display in the dashboard).
    var pid: pid_t? { isRunning ? process?.processIdentifier : nil }

    /// The engine bundled in the app. It is the normal case: an ordinary Mac user
    /// has no Homebrew, and without an engine the app cannot transcribe anything.
    ///
    static var bundledServerBinary: String? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/whisper-server")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url.path : nil
    }

    static func findServerBinary() -> String? {
        // The order is deliberate: our own co-signed engine first, then a
        // Homebrew binary the user installed themselves (developer setups and
        // installations from before the engine was bundled).
        if let bundled = bundledServerBinary { return bundled }
        let candidates = [
            "/opt/homebrew/bin/whisper-server",
            "/usr/local/bin/whisper-server",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Path of the model the running server was started with.
    private var runningModelPath: String?

    // MARK: Idle shutdown (optional, setting serverIdleShutdown)

    private var lastActivity = Date()
    private var idleTimer: Timer?
    /// 3 minutes: short enough that the memory really is freed in everyday use,
    /// long enough that the server does not keep reloading between two paragraphs
    /// while writing an email. The cold start after that costs about 0.7 s and
    /// begins on the Fn press, so while the user is still speaking.
    private static let idleLimit: TimeInterval = 180

    /// Call on every dictation, keeps the server "warm".
    func noteActivity() { lastActivity = Date() }

    /// Checks regularly whether the server may go to sleep for lack of dictations.
    func startIdleWatch() {
        idleTimer?.invalidate()
        // Tolerance so macOS can coalesce the watchdog with other timers: it is
        // never in a hurry, and a menu bar program runs along for weeks.
        idleTimer = Timer.scheduledCommon(every: 30, repeats: true, tolerance: 10) { [weak self] _ in
            guard let self, AppSettings.shared.serverIdleShutdown, self.isRunning,
                  Date().timeIntervalSince(self.lastActivity) > Self.idleLimit else { return }
            NSLog("Orbly: whisper-server stopped after \(Int(Self.idleLimit / 60)) min of inactivity (memory released)")
            self.stop()
        }
    }

    // MARK: Clean up orphans

    /// Terminates whisper-server processes from earlier sessions.
    ///
    /// `applicationWillTerminate` does not fire on a crash, a force quit or an
    /// abort from Xcode. The server then survives as an orphan (PPID 1), holds its
    /// memory and occupies our port, so the new server silently cannot start.
    /// Only what is unambiguously ours gets cleaned up: a whisper-server on
    /// exactly our port.
    ///
    /// Runs ONCE per program run: orphans always come from an earlier session, and
    /// a server belonging to this app hangs off it and is cleaned up on quit (see
    /// `stop()`). Before this the search ran on every Fn press, including a wait of
    /// up to 1 s for the port to free up, and it did so on the main thread while
    /// the overlay was supposed to appear.
    private var didReapOrphans = false

    private func reapOrphanServers() {
        guard !didReapOrphans else { return }
        didReapOrphans = true
        let port = AppSettings.shared.localPort
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", "whisper-server.*--port \(port)"]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        pgrep.standardError = FileHandle.nullDevice
        guard (try? pgrep.run()) != nil else { return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        pgrep.waitUntilExit()

        let ownServer = process?.processIdentifier
        let ownPid = ProcessInfo.processInfo.processIdentifier
        var killed = 0
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let pid = pid_t(line.trimmingCharacters(in: .whitespaces)),
                  pid != ownServer, pid != ownPid else { continue }
            // Only clean up genuine orphans: after a crash or force quit the server
            // hangs off launchd (PPID 1). If someone deliberately starts their own
            // whisper-server on this port, it does not get killed, and our start
            // then fails visibly with an error message.
            let parent = Self.parentPid(of: pid)
            guard parent == 1 || parent == ownPid else {
                NSLog("Orbly: fremder whisper-server auf Port \(port) (PID \(pid)) bleibt unangetastet")
                continue
            }
            kill(pid, SIGTERM)
            killed += 1
            NSLog("Orbly: verwaisten whisper-server beendet (PID \(pid))")
        }
        // The port only frees up once the process really is gone, otherwise our
        // bind fails silently. Only wait in the (rare) orphan case: in normal
        // operation nothing is found here and nothing is waited for.
        guard killed > 0 else { return }
        for _ in 0..<50 where portIsBusy(port) {
            usleep(20_000) // 1 s at most
        }
    }

    /// Error message when something needed for transcribing is missing in local
    /// mode, nil otherwise. Checked BEFORE recording, so no dictation is lost.
    func missingRequirement() -> String? {
        if Self.findServerBinary() == nil { return L10n.t("overlay.error.engineMissing") }
        if !FileManager.default.fileExists(atPath: AppSettings.shared.modelPath) {
            return L10n.t("overlay.error.modelMissing")
        }
        return nil
    }

    /// Parent PID of a process, or nil when it cannot be determined.
    private static func parentPid(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// Checks whether somebody is still listening on the port.
    private func portIsBusy(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return connected == 0
    }

    /// Waits until the local server is reachable (port open = model loaded,
    /// whisper-server only listens AFTER loading the model). For the cold start
    /// after an idle shutdown. completion runs on the main thread.
    /// Cancels a running `waitUntilReady` (Esc while processing), otherwise it
    /// keeps polling for up to 90 s only to throw the result away.
    func cancelWait() { waitGeneration += 1 }

    /// A counter instead of a yes/no flag: a flag was set back to "not cancelled"
    /// by the next dictation, and a long since cancelled wait then carried on with
    /// its old completion.
    private var waitGeneration = 0

    func waitUntilReady(timeout: TimeInterval = 90, completion: @escaping (Bool) -> Void) {
        waitGeneration += 1
        let generation = waitGeneration
        guard AppSettings.shared.mode == .local else {
            completion(true)
            return
        }
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            // The cancellation MUST call the completion too. Deleting the WAV file
            // happens in there; returning silently here left the raw speech
            // recording behind in the temp folder.
            guard generation == waitGeneration else {
                completion(false)
                return
            }
            guard isRunning else {
                completion(false) // start failed (binary or model missing)
                return
            }
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(AppSettings.shared.localPort)/")!)
            request.timeoutInterval = 2
            URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
                DispatchQueue.main.async {
                    guard let self, generation == self.waitGeneration else {
                        completion(false)
                        return
                    }
                    if response != nil {
                        completion(true) // any HTTP response = port open = ready
                    } else if Date() > deadline {
                        completion(false)
                    } else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { poll() }
                    }
                }
            }.resume()
        }
        poll()
    }

    func reconcile() {
        if AppSettings.shared.mode == .local {
            // Model change: stop the old server, start it again with the new model.
            if isRunning, runningModelPath != AppSettings.shared.modelPath {
                stop()
            }
            startIfNeeded()
        } else {
            stop()
        }
    }

    func startIfNeeded() {
        guard AppSettings.shared.mode == .local, !isRunning else { return }
        guard let binary = Self.findServerBinary() else {
            NSLog("Orbly: whisper-server not found (brew install whisper-cpp)")
            return
        }
        let modelPath = AppSettings.shared.modelPath
        guard FileManager.default.fileExists(atPath: modelPath) else {
            NSLog("Orbly: model is missing: \(modelPath)")
            return
        }
        // Clean up orphans from earlier sessions first, otherwise a zombie holds
        // the port and the new server starts into the void.
        reapOrphanServers()

        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Orbly", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logPath = logDir.appendingPathComponent("whisper-server.log").path
        FileManager.default.createFile(atPath: logPath, contents: nil)
        let logHandle = FileHandle(forWritingAtPath: logPath)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = [
            "-m", modelPath,
            "--host", "127.0.0.1",
            "--port", String(AppSettings.shared.localPort),
            "--inference-path", "/inference",
            "-t", "4",
        ]
        if let logHandle {
            p.standardOutput = logHandle
            p.standardError = logHandle
        }
        p.terminationHandler = { [weak self] proc in
            NSLog("Orbly: whisper-server beendet (Code \(proc.terminationStatus))")
            DispatchQueue.main.async {
                // Only clear our own reference: if the server dies unexpectedly and a new
                // one starts in the meantime, this handler would otherwise take away the
                // new one's reference and it could no longer be controlled.
                guard self?.process === proc else { return }
                self?.process = nil
            }
        }
        do {
            try p.run()
            process = p
            runningModelPath = modelPath
            NSLog("Orbly: whisper-server gestartet (PID \(p.processIdentifier))")
        } catch {
            NSLog("Orbly: whisper-server failed to start: \(error)")
        }
    }

    /// Stops the server and waits until it really is gone.
    ///
    /// The waiting is necessary: if the server is in the middle of an inference it
    /// does not react to SIGTERM immediately. Without following up it survives
    /// quitting the app as an orphan and holds its ~650 MB until the next start of
    /// Orbly. It also has to be synchronous, because this path is used from
    /// `applicationWillTerminate` too, after which nothing runs any more.
    ///
    /// `process` is only released at the end. Before the wait, `isRunning` would
    /// report false during that window although the process is still alive and
    /// holding the port. `reconcile()` (stop, immediately followed by
    /// startIfNeeded) would then have failed silently at the bind.
    func stop() {
        guard let p = process, p.isRunning else {
            process = nil
            return
        }
        p.terminationHandler = nil
        p.terminate() // SIGTERM
        // A server that is being shut down is normally idle and gone at once, so
        // the loop costs nothing then.
        for _ in 0..<30 where p.isRunning { usleep(10_000) } // 0.3 s at most
        if p.isRunning {
            NSLog("Orbly: whisper-server does not react to SIGTERM, killing it")
            kill(p.processIdentifier, SIGKILL)
            for _ in 0..<20 where p.isRunning { usleep(10_000) } // 0.2 s at most
        }
        process = nil
    }
}
