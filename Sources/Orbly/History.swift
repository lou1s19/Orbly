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

/// Persistent dictation history as a JSON Lines file, shown in the history tab
/// of the app. Replaces the earlier Verlauf.md (existing entries are migrated
/// once, the old file is deleted afterwards).
///
/// All file access goes through `queue`. Without that, the cleanup run at app
/// start and a dictation finishing at the same moment could overwrite each
/// other: read, append, write back the old state loses the new dictation.
enum History {
    private static let queue = DispatchQueue(label: "orbly.history")
    /// Remembers that the Verlauf.md migration has run. Before this, "history.jsonl
    /// does not exist" was the marker, which left the old file lying around forever
    /// and let it survive "clear history".
    private static let migratedKey = "historyMigratedFromMarkdown"

    static var url: URL {
        AppSettings.appSupportDir.appendingPathComponent("history.jsonl")
    }

    private static var legacyURL: URL {
        AppSettings.appSupportDir.appendingPathComponent("Verlauf.md")
    }

    /// `completion` runs on the main thread after the entry really is in the file.
    /// Only then may the history tab reload.
    static func append(_ text: String, completion: (() -> Void)? = nil) {
        queue.async {
            migrate()
            // Clean up with every dictation: the app often runs for weeks without a
            // restart, so pruning at startup only would overshoot the 3 days by far.
            prune()
            appendLine(HistoryEntry(date: Date(), text: text))
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
    }

    /// Newest first.
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

    /// The history ages out automatically: entries older than 3 days are removed
    /// (runs at app start). Keeps the file small, and old dictations do not sit on
    /// disk in plain text forever.
    static func pruneOldEntries() {
        queue.async {
            migrate()
            prune()
        }
    }


    /// Readable by the owner only. Unlike Desktop and Documents, `Application
    /// Support` is NOT protected by macOS: with the usual 0644 any other app
    /// running as the same user could read the dictations.
    ///
    /// Deliberately for EXISTING files too: whoever has dictated before would
    /// otherwise be the only one left with an open file, and those are exactly the
    /// users who have content in it.
    static func restrictPermissions() {
        let fm = FileManager.default
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: AppSettings.appSupportDir.path)
        if fm.fileExists(atPath: url.path) {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } else {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
    }

    static func clear() {
        queue.async {
            // Empty the file instead of deleting it, the history tab expects it.
            try? Data().write(to: url)
            restrictPermissions() // write(to:) creates it anew, with default permissions
            // Take the old Verlauf.md with it, otherwise plain text stays behind
            // that the user believes is deleted.
            try? FileManager.default.removeItem(at: legacyURL)
        }
    }

    // MARK: - Internal (always runs on `queue`)

    private static func prune(olderThanDays days: Int = 3) {
        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8), !content.isEmpty else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let lines = content.split(separator: "\n")
        let kept = lines.filter { line in
            guard let entry = try? decoder.decode(HistoryEntry.self, from: Data(line.utf8)) else {
                return false // broken line -> clean it up as well
            }
            return entry.date >= cutoff
        }
        guard kept.count != lines.count else { return }
        let output = kept.isEmpty ? "" : kept.joined(separator: "\n") + "\n"
        try? Data(output.utf8).write(to: url)
        restrictPermissions() // write(to:) creates it anew, with default permissions
        NSLog("Orbly: history cleaned up, \(lines.count - kept.count) entries older than \(days) days removed")
    }

    private static func appendLine(_ entry: HistoryEntry) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0A)

        try? FileManager.default.createDirectory(
            at: AppSettings.appSupportDir, withIntermediateDirectories: true
        )
        restrictPermissions()
        // `seekToEnd`/`write(contentsOf:)` instead of the old `seekToEndOfFile`/`write`:
        // the old ones report errors through an NSException, which Swift cannot catch.
        // A full disk exactly while saving therefore terminated the whole app.
        do {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: url)
            }
        } catch {
            NSLog("Orbly: could not save the history: \(error)")
        }
    }

    /// Takes over entries from the old Verlauf.md ("- **yyyy-MM-dd HH:mm** – text")
    /// exactly once and deletes it afterwards.
    private static func migrate() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migratedKey) else { return }

        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyURL.path) else {
            defaults.set(true, forKey: migratedKey)
            return
        }
        // If history.jsonl exists already, the migration ran in an earlier
        // version. The entries are taken over, the old file can go.
        guard !fm.fileExists(atPath: url.path) else {
            try? fm.removeItem(at: legacyURL)
            defaults.set(true, forKey: migratedKey)
            return
        }
        // Do NOT tick a read error off as "migrated", otherwise it is never
        // tried again and the old file stays around forever.
        guard let content = try? String(contentsOf: legacyURL, encoding: .utf8) else {
            NSLog("Orbly: Verlauf.md not readable, the migration is retried on the next launch")
            return
        }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        let pattern = #/^- \*\*(\d{4}-\d{2}-\d{2} \d{2}:\d{2})\*\* – (.+)$/#

        // Old dictations could contain line breaks, so lines without a date
        // prefix belong to the previous entry.
        var migrated: [HistoryEntry] = []
        for line in content.split(separator: "\n") {
            if let match = String(line).firstMatch(of: pattern),
               let date = df.date(from: String(match.1)) {
                migrated.append(HistoryEntry(date: date, text: String(match.2)))
            } else if let last = migrated.popLast() {
                migrated.append(HistoryEntry(date: last.date, text: last.text + "\n" + line))
            }
        }
        // German on purpose: this is the placeholder the old Verlauf.md was
        // created with, so it is legacy data and not text we produce.
        migrated.removeAll { $0.text == "(noch keine Diktate)" }

        try? fm.createDirectory(at: AppSettings.appSupportDir, withIntermediateDirectories: true)
        fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        migrated.forEach(appendLine)

        // Check first, then delete. `appendLine` swallows write errors (disk
        // full, missing permissions). Without this check the old file would be
        // gone and the entries nowhere. Count lines, do not just check that
        // "something was written": if writing aborts halfway, the rest is missing.
        let writtenLines = (try? Data(contentsOf: url))?.filter { $0 == 0x0A }.count ?? 0
        guard writtenLines >= migrated.count else {
            NSLog("Orbly: migration of Verlauf.md incomplete (\(writtenLines)/\(migrated.count)), the old file is kept")
            return
        }
        try? fm.removeItem(at: legacyURL)
        defaults.set(true, forKey: migratedKey)
        NSLog("Orbly: \(migrated.count) entries migrated from Verlauf.md, the old file was removed")
    }
}
