import Foundation

struct HistoryEntry: Codable, Identifiable {
    let id: UUID
    let date: Date
    let text: String

    init(date: Date, text: String) {
        self.id = UUID()
        self.date = date
        self.text = text
    }
}

/// Persistenter Diktat-Verlauf als JSON-Lines-Datei, angezeigt im Verlauf-Tab
/// der App. Ersetzt die frühere Verlauf.md (bestehende Einträge werden einmalig
/// migriert, die alte Datei wird danach gelöscht).
///
/// Alle Dateizugriffe laufen über `queue`. Ohne das konnten sich der Aufräumlauf
/// beim App-Start und ein gleichzeitig fertig werdendes Diktat überschreiben:
/// Lesen - Anhängen - alten Stand zurückschreiben verliert das neue Diktat.
enum History {
    private static let queue = DispatchQueue(label: "orbly.history")
    /// Merkt sich, dass die Verlauf.md-Migration gelaufen ist. Vorher galt
    /// „history.jsonl existiert nicht" als Merkmal - dadurch blieb die alte
    /// Datei für immer liegen und überlebte „Verlauf löschen".
    private static let migratedKey = "historyMigratedFromMarkdown"

    static var url: URL {
        AppSettings.appSupportDir.appendingPathComponent("history.jsonl")
    }

    private static var legacyURL: URL {
        AppSettings.appSupportDir.appendingPathComponent("Verlauf.md")
    }

    /// `completion` läuft auf dem Main-Thread, nachdem der Eintrag wirklich in
    /// der Datei steht - erst dann darf der Verlauf-Tab neu laden.
    static func append(_ text: String, completion: (() -> Void)? = nil) {
        queue.async {
            migrate()
            // Bei jedem Diktat mit aufräumen: Die App läuft oft wochenlang ohne
            // Neustart - nur beim Start zu prunen würde die 3 Tage weit überziehen.
            prune()
            appendLine(HistoryEntry(date: Date(), text: text))
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
    }

    /// Neueste zuerst.
    static func load(limit: Int = 200) -> [HistoryEntry] {
        queue.sync {
            migrate()
            guard let data = try? Data(contentsOf: url),
                  let content = String(data: data, encoding: .utf8) else { return [] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let entries = content.split(separator: "\n").compactMap {
                try? decoder.decode(HistoryEntry.self, from: Data($0.utf8))
            }
            return entries.suffix(limit).reversed()
        }
    }

    /// Verlauf altert automatisch aus: Einträge älter als 3 Tage werden entfernt
    /// (läuft beim App-Start). Hält die Datei klein und alte Diktate landen
    /// nicht ewig im Klartext auf der Platte.
    static func pruneOldEntries() {
        queue.async {
            migrate()
            prune()
        }
    }

    static func clear() {
        queue.async {
            // Datei leeren statt löschen - der Verlauf-Tab erwartet sie.
            try? Data().write(to: url)
            // Die alte Verlauf.md mit weg, sonst bleibt Klartext liegen,
            // den der Nutzer für gelöscht hält.
            try? FileManager.default.removeItem(at: legacyURL)
        }
    }

    // MARK: - Intern (läuft immer auf `queue`)

    private static func prune(olderThanDays days: Int = 3) {
        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8), !content.isEmpty else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let lines = content.split(separator: "\n")
        let kept = lines.filter { line in
            guard let entry = try? decoder.decode(HistoryEntry.self, from: Data(line.utf8)) else {
                return false // kaputte Zeile -> mit aufräumen
            }
            return entry.date >= cutoff
        }
        guard kept.count != lines.count else { return }
        let output = kept.isEmpty ? "" : kept.joined(separator: "\n") + "\n"
        try? Data(output.utf8).write(to: url)
        NSLog("Orbly: Verlauf aufgeräumt - \(lines.count - kept.count) Einträge älter als \(days) Tage entfernt")
    }

    private static func appendLine(_ entry: HistoryEntry) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0A)

        try? FileManager.default.createDirectory(
            at: AppSettings.appSupportDir, withIntermediateDirectories: true
        )
        // `seekToEnd`/`write(contentsOf:)` statt der alten `seekToEndOfFile`/`write`:
        // Die alten melden Fehler per NSException, die Swift nicht fangen kann.
        // Eine volle Platte genau beim Speichern beendete damit die ganze App.
        do {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: url)
            }
        } catch {
            NSLog("Orbly: Verlauf konnte nicht gespeichert werden: \(error)")
        }
    }

    /// Übernimmt Einträge aus der alten Verlauf.md ("- **yyyy-MM-dd HH:mm** – Text")
    /// genau einmal und löscht sie danach.
    private static func migrate() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migratedKey) else { return }

        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyURL.path) else {
            defaults.set(true, forKey: migratedKey)
            return
        }
        // Existiert history.jsonl schon, lief die Migration in einer früheren
        // Version - die Einträge sind übernommen, die alte Datei kann weg.
        guard !fm.fileExists(atPath: url.path) else {
            try? fm.removeItem(at: legacyURL)
            defaults.set(true, forKey: migratedKey)
            return
        }
        // Lesefehler NICHT als „migriert" abhaken - sonst wird es nie wieder
        // versucht und die alte Datei bleibt für immer liegen.
        guard let content = try? String(contentsOf: legacyURL, encoding: .utf8) else {
            NSLog("Orbly: Verlauf.md nicht lesbar - Migration wird beim nächsten Start erneut versucht")
            return
        }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        let pattern = #/^- \*\*(\d{4}-\d{2}-\d{2} \d{2}:\d{2})\*\* – (.+)$/#

        // Alte Diktate konnten Zeilenumbrüche enthalten - Zeilen ohne
        // Datums-Präfix gehören deshalb zum vorherigen Eintrag.
        var migrated: [HistoryEntry] = []
        for line in content.split(separator: "\n") {
            if let match = String(line).firstMatch(of: pattern),
               let date = df.date(from: String(match.1)) {
                migrated.append(HistoryEntry(date: date, text: String(match.2)))
            } else if let last = migrated.popLast() {
                migrated.append(HistoryEntry(date: last.date, text: last.text + "\n" + line))
            }
        }
        migrated.removeAll { $0.text == "(noch keine Diktate)" }

        try? fm.createDirectory(at: AppSettings.appSupportDir, withIntermediateDirectories: true)
        fm.createFile(atPath: url.path, contents: nil)
        migrated.forEach(appendLine)

        // Erst prüfen, dann löschen. `appendLine` schluckt Schreibfehler (volle
        // Platte, fehlende Rechte) - ohne diese Prüfung wäre die alte Datei weg
        // und die Einträge nirgends. Zeilen zählen, nicht nur „irgendwas
        // geschrieben": Bricht das Schreiben in der Mitte ab, fehlt der Rest.
        let writtenLines = (try? Data(contentsOf: url))?.filter { $0 == 0x0A }.count ?? 0
        guard writtenLines >= migrated.count else {
            NSLog("Orbly: Migration der Verlauf.md unvollständig (\(writtenLines)/\(migrated.count)) - alte Datei bleibt erhalten")
            return
        }
        try? fm.removeItem(at: legacyURL)
        defaults.set(true, forKey: migratedKey)
        NSLog("Orbly: \(migrated.count) Einträge aus Verlauf.md migriert, alte Datei entfernt")
    }
}
