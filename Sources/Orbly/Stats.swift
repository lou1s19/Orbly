import Foundation

/// One finished dictation, for the statistics. Deliberately NO text is stored,
/// only numbers (data minimization). The text itself optionally lives in the
/// history.
struct DictationStat: Codable {
    let date: Date
    let words: Int
    let characters: Int
    /// Recording length in seconds.
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
    /// Estimated saving compared to typing it yourself.
    var savedSeconds: Double = 0
    var perDay: [DayWords] = []

    var wordsPerDictation: Int {
        dictations > 0 ? words / dictations : 0
    }
}

/// Summarized old data. So that `stats.jsonl` does not grow without bound, old
/// individual entries are compacted into these four numbers. The totals stay
/// exact, only the per-day resolution of old days is dropped (the chart shows
/// 14 days anyway).
struct StatsArchive: Codable, Equatable {
    var dictations = 0
    var words = 0
    var spokenSeconds: Double = 0
    var savedSeconds: Double = 0
    /// This many entries at the START of `stats.jsonl` are already contained in
    /// the numbers above.
    ///
    /// Compaction needs two file writes (the archive, then the shortened list of
    /// entries), and those cannot be atomic together. If it aborts in between
    /// (disk full), the same entries are still there on the next run and without
    /// this marker were added up a second time: the totals stayed permanently too
    /// high.
    ///
    /// Deliberately a count and not a timestamp: entries sit in the order they
    /// were written, and that order still holds when the system clock jumps
    /// (daylight saving, an NTP correction). A time marker would have discarded an
    /// entry written after the jump back without ever counting it.
    ///
    var compactedPrefix = 0
}

/// Persistent dictation statistics as a JSON Lines file in Application Support.
enum Stats {
    /// Average typing speed the saving is calculated against.
    static let typingWordsPerMinute = 40.0
    /// From this age on, individual entries are compacted.
    static let compactAfterDays = 30

    /// All file access goes through this: `record` comes from the main thread,
    /// compaction and evaluation from the background.
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
            NSLog("Orbly: could not save the statistics: \(error)")
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

    static func load() -> [DictationStat] {
        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else { return [] }
        return decode(content)
    }

    /// A pure function, so it can be tested.
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

    // MARK: - Evaluation

    /// Computes the summary from finished values. No file, no clock, no calendar
    /// from the environment, which is exactly why it is testable.
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

    /// Compacts entries older than `olderThanDays` into the archive.
    /// A pure function: returns the new archive and the entries to keep.
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
            // Two conditions, and both have to hold: the entry sits in the already
            // compacted leading part AND it is old enough. The second one covers the
            // case "shortening worked, writing the archive the second time did not":
            // after that there are recent entries at the front which must not be
            // discarded under any circumstances.
            if index < archive.compactedPrefix { continue }
            newArchive.dictations += 1
            newArchive.words += entry.words
            newArchive.spokenSeconds += entry.seconds
            newArchive.savedSeconds += savedSeconds(for: entry)
        }
        // If the shortening fails right away, exactly this leading part is
        // already counted on the next run.
        newArchive.compactedPrefix = verdichtet
        return (newArchive, kept)
    }

    /// Call at startup: keeps `stats.jsonl` small without losing the totals.
    static func compactOldEntries() {
        queue.async {
            let entries = load()
            guard !entries.isEmpty else { return }
            let result = compacted(entries, into: loadArchive(), olderThanDays: compactAfterDays)
            guard result.kept.count != entries.count else { return }

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            // The order is deliberate: the archive first, then shorten the list of
            // entries. If it aborts in between, numbers are duplicated rather than
            // lost, and `compactedPrefix` makes sure the next run does not count them
            // again. The other way round they would be gone for good.
            guard let archiveData = try? JSONEncoder().encode(result.archive),
                  (try? archiveData.write(to: archiveURL)) != nil else {
                NSLog("Orbly: statistics archive not writable, compaction skipped")
                return
            }
            let lines = result.kept.compactMap { try? encoder.encode($0) }
                .compactMap { String(data: $0, encoding: .utf8) }
            let output = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
            guard (try? Data(output.utf8).write(to: url)) != nil else {
                NSLog("Orbly: statistics entries could not be shortened, the archive remembers that")
                return
            }
            // Shortened is shortened: the leading part is no longer in the file, so
            // the marker has to go back to 0. If exactly this write fails, nothing is
            // broken: the remaining entries are all younger than the compaction
            // threshold, and the marker only applies to old ones.
            var aufgeraeumt = result.archive
            aufgeraeumt.compactedPrefix = 0
            if let data = try? JSONEncoder().encode(aufgeraeumt) {
                try? data.write(to: archiveURL)
            }
            restrictPermissions() // write(to:) creates it anew, with default permissions
            cachedSummary = nil
            NSLog("Orbly: statistics compacted, \(entries.count - result.kept.count) old entries summarized")
        }
    }

    // MARK: - Cache (do not parse on the main thread)

    private static var cachedSummary: StatsSummary?

    /// Call after "delete all data". Without it the overview kept showing the old
    /// numbers until the next launch.
    static func invalidateCache() {
        queue.async { cachedSummary = nil }
    }

    /// Reads and computes in the background, `completion` runs on the main thread.
    /// This used to run synchronously when the window opened and got slower with
    /// every week of use.
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
