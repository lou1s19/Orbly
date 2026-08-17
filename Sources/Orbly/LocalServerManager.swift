import Foundation

/// Launches and supervises a local whisper-server (whisper.cpp) so the model
/// stays loaded between dictations. Only used in `.local` mode.
final class LocalServerManager {
    private var process: Process?
    var isRunning: Bool { process?.isRunning ?? false }
    /// PID des laufenden whisper-server (für die RAM-Anzeige im Dashboard).
    var pid: pid_t? { isRunning ? process?.processIdentifier : nil }

    /// Die mitgelieferte Engine im App-Bundle. Sie ist der Normalfall: Ein
    /// normaler Mac-Nutzer hat kein Homebrew, und ohne Engine kann die App
    /// nichts transkribieren.
    static var bundledServerBinary: String? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/whisper-server")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url.path : nil
    }

    static func findServerBinary() -> String? {
        // Reihenfolge ist Absicht: Erst die eigene, mitsignierte Engine, dann
        // ein selbst installiertes Homebrew-Binary (Entwickler-Setups und
        // Bestandsinstallationen von vor dem Mitliefern).
        if let bundled = bundledServerBinary { return bundled }
        let candidates = [
            "/opt/homebrew/bin/whisper-server",
            "/usr/local/bin/whisper-server",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Pfad des Modells, mit dem der laufende Server gestartet wurde.
    private var runningModelPath: String?

    // MARK: Idle-Abschaltung (optional, Setting serverIdleShutdown)

    private var lastActivity = Date()
    private var idleTimer: Timer?
    /// 3 Minuten: kurz genug, dass der Speicher im Alltag wirklich frei wird,
    /// lang genug, dass der Server beim Schreiben einer Mail nicht zwischen
    /// zwei Absätzen ständig neu lädt. Der Kaltstart danach kostet ~0,7 s und
    /// beginnt beim Fn-Druck, also während der Nutzer noch spricht.
    private static let idleLimit: TimeInterval = 180

    /// Bei jedem Diktat aufrufen - hält den Server "warm".
    func noteActivity() { lastActivity = Date() }

    /// Prüft regelmäßig, ob der Server mangels Diktaten schlafen gehen darf.
    func startIdleWatch() {
        idleTimer?.invalidate()
        // Toleranz, damit macOS den Wächter mit anderen Timern bündeln kann: Er
        // ist nie eilig, und ein Menüleisten-Programm läuft wochenlang mit.
        idleTimer = Timer.scheduledCommon(every: 30, repeats: true, tolerance: 10) { [weak self] _ in
            guard let self, AppSettings.shared.serverIdleShutdown, self.isRunning,
                  Date().timeIntervalSince(self.lastActivity) > Self.idleLimit else { return }
            NSLog("Orbly: whisper-server nach \(Int(Self.idleLimit / 60)) min Inaktivität beendet (RAM freigegeben)")
            self.stop()
        }
    }

    // MARK: Waisen aufräumen

    /// Beendet whisper-server-Prozesse aus früheren Sitzungen.
    ///
    /// `applicationWillTerminate` greift nicht bei Absturz, Force-Quit oder
    /// Abbruch aus Xcode - dann überlebt der Server als Waise (PPID 1), hält
    /// seinen Speicher und belegt unseren Port, sodass der neue Server
    /// stillschweigend nicht starten kann. Abgeräumt wird nur, was eindeutig
    /// unseres ist: ein whisper-server auf genau unserem Port.
    /// Waisen stammen immer aus einer FRÜHEREN Sitzung: Ein Server, den diese
    /// App gestartet hat, hängt an ihr und wird beim Beenden mit abgeräumt.
    /// Einmal pro Programmlauf zu suchen genügt deshalb. Vorher lief die Suche
    /// bei jedem Fn-Druck mit, samt einer bis zu 1 s langen Wartezeit auf den
    /// freien Port, und zwar auf dem Hauptthread, während das Overlay erscheinen
    /// sollte.
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
            // Nur echte Waisen abräumen: Nach Absturz/Force-Quit hängt der Server
            // an launchd (PPID 1). Startet jemand bewusst selbst einen
            // whisper-server auf diesem Port, wird er nicht abgeschossen - dann
            // scheitert unser Start sichtbar mit einer Fehlermeldung.
            let parent = Self.parentPid(of: pid)
            guard parent == 1 || parent == ownPid else {
                NSLog("Orbly: fremder whisper-server auf Port \(port) (PID \(pid)) bleibt unangetastet")
                continue
            }
            kill(pid, SIGTERM)
            killed += 1
            NSLog("Orbly: verwaisten whisper-server beendet (PID \(pid))")
        }
        // Der Port wird erst frei, wenn der Prozess wirklich weg ist - sonst
        // scheitert unser Bind still. Nur im (seltenen) Waisen-Fall warten,
        // im Normalbetrieb wird hier nichts gefunden und nichts gewartet.
        guard killed > 0 else { return }
        for _ in 0..<50 where portIsBusy(port) {
            usleep(20_000) // max. 1 s
        }
    }

    /// Fehlermeldung, wenn im lokalen Modus etwas zum Transkribieren fehlt -
    /// sonst nil. Wird VOR dem Aufnehmen geprüft, damit kein Diktat verloren geht.
    func missingRequirement() -> String? {
        if Self.findServerBinary() == nil { return L10n.t("overlay.error.engineMissing") }
        if !FileManager.default.fileExists(atPath: AppSettings.shared.modelPath) {
            return L10n.t("overlay.error.modelMissing")
        }
        return nil
    }

    /// Eltern-PID eines Prozesses, oder nil wenn nicht ermittelbar.
    private static func parentPid(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// Prüft, ob auf dem Port noch jemand lauscht.
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

    /// Wartet, bis der lokale Server erreichbar ist (Port offen = Modell geladen,
    /// whisper-server lauscht erst NACH dem Modell-Laden). Für den Kaltstart nach
    /// einer Idle-Abschaltung. completion läuft auf dem Main-Thread.
    /// Bricht ein laufendes `waitUntilReady` ab (Esc während der Verarbeitung) -
    /// sonst pollt es bis zu 90 s weiter, nur um das Ergebnis wegzuwerfen.
    func cancelWait() { waitGeneration += 1 }

    /// Zähler statt Ja/Nein-Schalter: Ein Schalter wurde vom nächsten Diktat
    /// wieder auf "nicht abgebrochen" gestellt, und eine längst abgebrochene
    /// Warteschleife lief dann mit ihrer alten Completion weiter.
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
            // Auch der Abbruch MUSS die Completion aufrufen. Dort steht das
            // Löschen der WAV-Datei; kehrte man hier still zurück, blieb die rohe
            // Sprachaufnahme im Temp-Ordner liegen.
            guard generation == waitGeneration else {
                completion(false)
                return
            }
            guard isRunning else {
                completion(false) // Start fehlgeschlagen (Binary/Modell fehlt)
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
                        completion(true) // irgendeine HTTP-Antwort = Port offen = bereit
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
            // Modellwechsel: alten Server stoppen, gleich mit neuem Modell starten.
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
            NSLog("Orbly: whisper-server nicht gefunden (brew install whisper-cpp)")
            return
        }
        let modelPath = AppSettings.shared.modelPath
        guard FileManager.default.fileExists(atPath: modelPath) else {
            NSLog("Orbly: Modell fehlt: \(modelPath)")
            return
        }
        // Erst Waisen früherer Sitzungen abräumen - sonst hält ein Zombie den
        // Port und der neue Server startet ins Leere.
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
                // Nur die eigene Referenz löschen: Stirbt der Server unerwartet und
                // startet inzwischen ein neuer, würde dieser Handler sonst dessen
                // Referenz wegnehmen - der neue Server wäre nicht mehr steuerbar.
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
            NSLog("Orbly: whisper-server Start fehlgeschlagen: \(error)")
        }
    }

    func stop() {
        guard let p = process, p.isRunning else { return }
        p.terminationHandler = nil
        p.terminate() // SIGTERM
        process = nil
        // Nicht einfach loslassen: Steckt der Server mitten in einer Inferenz,
        // reagiert er nicht sofort auf SIGTERM. Ohne Nachfassen überlebt er das
        // Beenden der App als Waise und hält seine ~650 MB, bis Orbly das nächste
        // Mal startet. Das Warten muss synchron sein, weil dieser Weg auch aus
        // `applicationWillTerminate` kommt - danach läuft nichts mehr.
        // Ein Server, der abgeschaltet wird, ist im Normalfall untätig und sofort
        // weg; die Schleife kostet dann nichts.
        for _ in 0..<30 where p.isRunning { usleep(10_000) } // max. 0,3 s
        guard p.isRunning else { return }
        NSLog("Orbly: whisper-server reagiert nicht auf SIGTERM, wird hart beendet")
        kill(p.processIdentifier, SIGKILL)
    }
}
