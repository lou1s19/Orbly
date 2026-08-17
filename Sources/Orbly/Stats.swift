import Foundation

/// Ein abgeschlossenes Diktat für die Statistik. Es wird bewusst KEIN Text
/// gespeichert - nur Zahlen (Datenminimierung), der Text selbst steht optional
/// im Verlauf.
struct DictationStat: Codable {
    let date: Date
    let words: Int
    let characters: Int
    /// Aufnahmedauer in Sekunden.
    let seconds: Double
}

struct DayWords: Identifiable {
    let day: Date
    let words: Int
    var id: Date { day }
}

struct StatsSummary {
    var dictations = 0
    var words = 0
    var spokenSeconds: Double = 0
    /// Geschätzte Ersparnis gegenüber Selbertippen.
    var savedSeconds: Double = 0
    var perDay: [DayWords] = []

    var wordsPerDictation: Int {
        dictations > 0 ? words / dictations : 0
    }
}

/// Zusammengefasste Altdaten. Damit `stats.jsonl` nicht unbegrenzt wächst,
/// werden alte Einzeleinträge zu diesen vier Zahlen verdichtet - die
/// Gesamtsummen bleiben exakt, nur die Tagesauflösung alter Tage entfällt
/// (das Diagramm zeigt ohnehin 14 Tage).
struct StatsArchive: Codable, Equatable {
    var dictations = 0
    var words = 0
    var spokenSeconds: Double = 0
    var savedSeconds: Double = 0
    /// So viele Einträge am ANFANG von `stats.jsonl` stecken schon in den Zahlen
    /// oben drüber.
    ///
    /// Verdichten braucht zwei Dateischreibvorgänge (Archiv, dann gekürzte
    /// Einzelliste), und die gehen nicht gemeinsam atomar. Bricht es dazwischen
    /// ab (Platte voll), stehen dieselben Einträge beim nächsten Lauf noch da und
    /// wurden ohne diese Marke ein zweites Mal aufaddiert: Die Gesamtzahlen
    /// blieben dauerhaft zu hoch.
    ///
    /// Bewusst eine Anzahl und kein Zeitstempel: Einträge stehen in der
    /// Reihenfolge, in der sie geschrieben wurden, und diese Reihenfolge stimmt
    /// auch dann noch, wenn die Systemuhr springt (Zeitumstellung, NTP-Korrektur).
    /// Eine Zeitmarke hätte einen nach dem Rücksprung geschriebenen Eintrag
    /// verworfen, ohne ihn je zu zählen.
    var compactedPrefix = 0
}

/// Persistente Diktier-Statistik als JSON-Lines-Datei im App-Support-Ordner.
enum Stats {
    /// Durchschnittliches Tipptempo, gegen das die Ersparnis gerechnet wird.
    static let typingWordsPerMinute = 40.0
    /// Ab diesem Alter werden Einzeleinträge verdichtet.
    static let compactAfterDays = 30

    /// Alle Dateizugriffe laufen hierüber: `record` kommt vom Main-Thread,
    /// Verdichten und Auswerten vom Hintergrund.
    private static let queue = DispatchQueue(label: "orbly.stats")

    static var url: URL {
        AppSettings.appSupportDir.appendingPathComponent("stats.jsonl")
    }

    static var archiveURL: URL {
        AppSettings.appSupportDir.appendingPathComponent("stats-archive.json")
    }

    static func record(text: String, seconds: Double) {
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        guard words > 0 else { return }
        let stat = DictationStat(date: Date(), words: words, characters: text.count, seconds: seconds)
        queue.async {
            appendLine(stat)
            cachedSummary = nil
        }
    }

    private static func appendLine(_ stat: DictationStat) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(stat) else { return }
        line.append(0x0A)

        try? FileManager.default.createDirectory(
            at: AppSettings.appSupportDir, withIntermediateDirectories: true
        )
        restrictPermissions()
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
            NSLog("Orbly: Statistik konnte nicht gespeichert werden: \(error)")
        }
    }


    /// Nur für den Besitzer lesbar. `Application Support` ist im Gegensatz zu
    /// Schreibtisch und Dokumente NICHT von macOS geschützt: Mit den üblichen
    /// 0644 konnte jede andere App unter demselben Benutzer die Diktate lesen.
    ///
    /// Bewusst auch für BESTEHENDE Dateien: Wer schon diktiert hat, hätte sonst
    /// als Einziger weiter eine offene Datei, und genau das sind die Nutzer mit
    /// Inhalt darin.
    static func restrictPermissions() {
        let fm = FileManager.default
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: AppSettings.appSupportDir.path)
        if fm.fileExists(atPath: url.path) {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } else {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
    }

    static func load() -> [DictationStat] {
        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else { return [] }
        return decode(content)
    }

    /// Reine Funktion, damit sie testbar ist.
    static func decode(_ content: String) -> [DictationStat] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return content.split(separator: "\n").compactMap {
            try? decoder.decode(DictationStat.self, from: Data($0.utf8))
        }
    }

    static func loadArchive() -> StatsArchive {
        guard let data = try? Data(contentsOf: archiveURL),
              let archive = try? JSONDecoder().decode(StatsArchive.self, from: data)
        else { return StatsArchive() }
        return archive
    }

    // MARK: - Auswertung

    /// Rechnet die Zusammenfassung aus fertigen Werten. Keine Datei, keine Uhr,
    /// kein Kalender aus der Umgebung - genau deshalb testbar.
    static func summarize(
        _ entries: [DictationStat],
        archive: StatsArchive = StatsArchive(),
        days: Int = 14,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> StatsSummary {
        var summary = StatsSummary()
        var wordsPerDay: [Date: Int] = [:]

        summary.dictations = archive.dictations
        summary.words = archive.words
        summary.spokenSeconds = archive.spokenSeconds
        summary.savedSeconds = archive.savedSeconds

        for entry in entries {
            summary.dictations += 1
            summary.words += entry.words
            summary.spokenSeconds += entry.seconds
            summary.savedSeconds += savedSeconds(for: entry)
            wordsPerDay[calendar.startOfDay(for: entry.date), default: 0] += entry.words
        }

        let today = calendar.startOfDay(for: now)
        summary.perDay = (0..<days).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return DayWords(day: day, words: wordsPerDay[day] ?? 0)
        }
        return summary
    }

    static func savedSeconds(for entry: DictationStat) -> Double {
        let typingSeconds = Double(entry.words) / typingWordsPerMinute * 60
        return max(0, typingSeconds - entry.seconds)
    }

    /// Verdichtet Einträge, die älter als `olderThanDays` sind, in das Archiv.
    /// Reine Funktion: liefert das neue Archiv und die zu behaltenden Einträge.
    static func compacted(
        _ entries: [DictationStat], into archive: StatsArchive,
        olderThanDays days: Int, now: Date = Date()
    ) -> (archive: StatsArchive, kept: [DictationStat]) {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        var newArchive = archive
        var kept: [DictationStat] = []
        var verdichtet = 0
        for (index, entry) in entries.enumerated() {
            guard entry.date < cutoff else {
                kept.append(entry)
                continue
            }
            verdichtet += 1
            // Zwei Bedingungen, und beide müssen stimmen: Der Eintrag steht im
            // schon verdichteten Anfangsstück UND er ist alt genug. Die zweite
            // schützt den Fall „Kürzen hat geklappt, das zweite Schreiben des
            // Archivs nicht": Danach stehen vorne junge Einträge, die auf keinen
            // Fall verworfen werden dürfen.
            if index < archive.compactedPrefix { continue }
            newArchive.dictations += 1
            newArchive.words += entry.words
            newArchive.spokenSeconds += entry.seconds
            newArchive.savedSeconds += savedSeconds(for: entry)
        }
        // Geht das Kürzen gleich schief, ist genau dieses Anfangsstück beim
        // nächsten Lauf schon gezählt.
        newArchive.compactedPrefix = verdichtet
        return (newArchive, kept)
    }

    /// Beim Start aufrufen: hält `stats.jsonl` klein, ohne Gesamtsummen zu verlieren.
    static func compactOldEntries() {
        queue.async {
            let entries = load()
            guard !entries.isEmpty else { return }
            let result = compacted(entries, into: loadArchive(), olderThanDays: compactAfterDays)
            guard result.kept.count != entries.count else { return }

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            // Reihenfolge ist Absicht: erst das Archiv, dann die Einzeleinträge
            // kürzen. Bricht es dazwischen ab, sind Zahlen doppelt statt verloren,
            // und `compactedPrefix` sorgt dafür, dass der nächste Lauf sie nicht
            // noch einmal zählt. Andersherum wären sie ersatzlos weg.
            guard let archiveData = try? JSONEncoder().encode(result.archive),
                  (try? archiveData.write(to: archiveURL)) != nil else {
                NSLog("Orbly: Statistik-Archiv nicht schreibbar - Verdichten übersprungen")
                return
            }
            let lines = result.kept.compactMap { try? encoder.encode($0) }
                .compactMap { String(data: $0, encoding: .utf8) }
            let output = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
            guard (try? Data(output.utf8).write(to: url)) != nil else {
                NSLog("Orbly: Statistik-Einträge nicht kürzbar - Archiv merkt sich das")
                return
            }
            // Gekürzt ist gekürzt: Das Anfangsstück steht nicht mehr in der Datei,
            // die Marke muss zurück auf 0. Schlägt genau dieses Schreiben fehl,
            // ist nichts kaputt: Die verbliebenen Einträge sind alle jünger als
            // die Verdichtungsgrenze, und die Marke greift nur bei alten.
            var aufgeraeumt = result.archive
            aufgeraeumt.compactedPrefix = 0
            if let data = try? JSONEncoder().encode(aufgeraeumt) {
                try? data.write(to: archiveURL)
            }
            restrictPermissions() // write(to:) legt neu an, mit Standardrechten
            cachedSummary = nil
            NSLog("Orbly: Statistik verdichtet - \(entries.count - result.kept.count) alte Einträge zusammengefasst")
        }
    }

    // MARK: - Zwischenspeicher (nicht auf dem Main-Thread parsen)

    private static var cachedSummary: StatsSummary?

    /// Nach „alle Daten löschen" aufrufen. Ohne das zeigte die Übersicht die
    /// alten Zahlen bis zum nächsten Start weiter.
    static func invalidateCache() {
        queue.async { cachedSummary = nil }
    }

    /// Liest und rechnet im Hintergrund, `completion` läuft auf dem Main-Thread.
    /// Vorher lief das synchron beim Öffnen des Fensters und wurde mit jeder
    /// Nutzungswoche langsamer.
    static func summaryAsync(days: Int = 14, completion: @escaping (StatsSummary) -> Void) {
        queue.async {
            if let cachedSummary {
                DispatchQueue.main.async { completion(cachedSummary) }
                return
            }
            let result = summarize(load(), archive: loadArchive(), days: days)
            cachedSummary = result
            DispatchQueue.main.async { completion(result) }
        }
    }

    static func formatDuration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return L10n.t("stats.duration.sec", Int(seconds)) }
        if minutes < 60 { return L10n.t("stats.duration.min", minutes) }
        return L10n.t("stats.duration.hourMin", minutes / 60, minutes % 60)
    }
}
