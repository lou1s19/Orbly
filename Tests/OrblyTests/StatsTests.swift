import XCTest
@testable import Orbly

final class StatsTests: XCTestCase {

    /// Fixed calendar and a fixed "now", so the test does not depend on when it
    /// runs.
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return c
    }()

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "Europe/Berlin")!
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

    private func stat(_ iso: String, words: Int, seconds: Double) -> DictationStat {
        DictationStat(date: date(iso), words: words, characters: words * 6, seconds: seconds)
    }

    // MARK: summarize

    func testSumOverAllEntries() {
        let entries = [
            stat("2026-08-03T10:00:00+02:00", words: 100, seconds: 30),
            stat("2026-08-03T11:00:00+02:00", words: 50, seconds: 20),
        ]
        let s = Stats.summarize(
            entries, days: 14, now: date("2026-08-03T12:00:00+02:00"), calendar: calendar
        )
        XCTAssertEqual(s.dictations, 2)
        XCTAssertEqual(s.words, 150)
        XCTAssertEqual(s.spokenSeconds, 50)
        XCTAssertEqual(s.wordsPerDictation, 75)
    }

    func testTimeSavedComparedToTyping() {
        // 40 words at 40 WPM = 60 s of typing, 20 s spoken -> 40 s saved.
        let s = Stats.summarize(
            [stat("2026-08-03T10:00:00+02:00", words: 40, seconds: 20)],
            now: date("2026-08-03T12:00:00+02:00"), calendar: calendar
        )
        XCTAssertEqual(s.savedSeconds, 40, accuracy: 0.001)
    }

    func testSavingIsNeverNegative() {
        // Spoken slowly: typing would have been faster. Still not < 0, otherwise
        // a slow dictation would subtract time saved earlier.
        let s = Stats.summarize(
            [stat("2026-08-03T10:00:00+02:00", words: 5, seconds: 300)],
            now: date("2026-08-03T12:00:00+02:00"), calendar: calendar
        )
        XCTAssertEqual(s.savedSeconds, 0)
    }

    func testDaySeriesAlwaysHasTheRequestedLength() {
        let s = Stats.summarize(
            [stat("2026-08-03T10:00:00+02:00", words: 10, seconds: 5)],
            days: 14, now: date("2026-08-03T12:00:00+02:00"), calendar: calendar
        )
        XCTAssertEqual(s.perDay.count, 14)
        XCTAssertEqual(s.perDay.last?.words, 10, "today has to be the last entry")
        XCTAssertEqual(s.perDay.first?.words, 0, "days without a dictation are 0, not left out")
    }

    func testEntriesOnTheSameDayAreAddedUp() {
        let entries = [
            stat("2026-08-03T08:00:00+02:00", words: 10, seconds: 5),
            stat("2026-08-03T20:00:00+02:00", words: 15, seconds: 5),
        ]
        let s = Stats.summarize(
            entries, days: 3, now: date("2026-08-03T22:00:00+02:00"), calendar: calendar
        )
        XCTAssertEqual(s.perDay.last?.words, 25)
    }

    func testArchiveCountsTowardTotalsButNotTheChart() {
        let archive = StatsArchive(dictations: 100, words: 5000, spokenSeconds: 2000, savedSeconds: 3000)
        let s = Stats.summarize(
            [stat("2026-08-03T10:00:00+02:00", words: 10, seconds: 5)],
            archive: archive, days: 3,
            now: date("2026-08-03T12:00:00+02:00"), calendar: calendar
        )
        XCTAssertEqual(s.dictations, 101)
        XCTAssertEqual(s.words, 5010)
        XCTAssertEqual(s.perDay.last?.words, 10, "the archive must not distort the chart")
    }

    func testEmptyStatistics() {
        let s = Stats.summarize([], days: 7, now: date("2026-08-03T12:00:00+02:00"), calendar: calendar)
        XCTAssertEqual(s.dictations, 0)
        XCTAssertEqual(s.wordsPerDictation, 0, "no division by 0")
        XCTAssertEqual(s.perDay.count, 7)
    }

    // MARK: Compaction

    func testCompactionOnlySummarizesOldEntries() {
        let now = date("2026-08-03T12:00:00+02:00")
        let entries = [
            stat("2026-05-01T10:00:00+02:00", words: 40, seconds: 20),   // old
            stat("2026-08-01T10:00:00+02:00", words: 10, seconds: 5),    // new
        ]
        let r = Stats.compacted(entries, into: StatsArchive(), olderThanDays: 30, now: now)
        XCTAssertEqual(r.kept.count, 1)
        XCTAssertEqual(r.archive.dictations, 1)
        XCTAssertEqual(r.archive.words, 40)
        XCTAssertEqual(r.archive.savedSeconds, 40, accuracy: 0.001)
    }

    func testCompactionLosesNoTotals() {
        let now = date("2026-08-03T12:00:00+02:00")
        let entries = [
            stat("2026-01-01T10:00:00+02:00", words: 40, seconds: 20),
            stat("2026-02-01T10:00:00+02:00", words: 60, seconds: 30),
            stat("2026-08-02T10:00:00+02:00", words: 10, seconds: 5),
        ]
        let before = Stats.summarize(entries, days: 14, now: now, calendar: calendar)
        let r = Stats.compacted(entries, into: StatsArchive(), olderThanDays: 30, now: now)
        let after = Stats.summarize(r.kept, archive: r.archive, days: 14, now: now, calendar: calendar)

        XCTAssertEqual(after.dictations, before.dictations)
        XCTAssertEqual(after.words, before.words)
        XCTAssertEqual(after.spokenSeconds, before.spokenSeconds, accuracy: 0.001)
        XCTAssertEqual(after.savedSeconds, before.savedSeconds, accuracy: 0.001)
    }

    func testCompactionIsRepeatableWithoutDoubleCounting() {
        let now = date("2026-08-03T12:00:00+02:00")
        let entries = [stat("2026-01-01T10:00:00+02:00", words: 40, seconds: 20)]
        let first = Stats.compacted(entries, into: StatsArchive(), olderThanDays: 30, now: now)
        let again = Stats.compacted(first.kept, into: first.archive, olderThanDays: 30, now: now)
        // What is compared are the numbers, not the bookkeeping: `compactedPrefix`
        // MUST drop from 1 to 0 here. The second run gets `first.kept`, that is
        // the already shortened list, which is exactly the case where the leading
        // part is no longer in the file.
        XCTAssertEqual(again.archive.dictations, first.archive.dictations, "the second run must not double anything")
        XCTAssertEqual(again.archive.words, first.archive.words, "the second run must not double anything")
        XCTAssertEqual(again.archive.spokenSeconds, first.archive.spokenSeconds, accuracy: 0.001)
        XCTAssertEqual(again.archive.savedSeconds, first.archive.savedSeconds, accuracy: 0.001)
        XCTAssertEqual(again.archive.compactedPrefix, 0)
    }

    // MARK: File format

    func testDecodeSkipsBrokenLines() {
        let content = """
        {"date":"2026-08-03T10:00:00Z","words":10,"characters":60,"seconds":5}
        this is not a valid line
        {"date":"2026-08-03T11:00:00Z","words":20,"characters":120,"seconds":8}
        """
        let entries = Stats.decode(content)
        XCTAssertEqual(entries.count, 2, "one broken line must not discard everything")
        XCTAssertEqual(entries.map(\.words), [10, 20])
    }

    func testStatisticsStoreNoText() throws {
        // Privacy promise from the README: the statistics only store numbers.
        // If this test fails, someone added a text field.
        let stat = DictationStat(date: Date(), words: 1, characters: 1, seconds: 1)
        let data = try JSONEncoder().encode(stat)
        let fields = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(Set(fields.keys), ["date", "words", "characters", "seconds"])
    }

    // MARK: - Compaction is repeatable

    /// If compaction aborts after writing the archive (disk full), the same
    /// entries are still in stats.jsonl on the next run. Without the
    /// `compactedUpTo` marker they were added up again and the totals stayed
    /// permanently too high.
    func testASecondCompactionDoesNotCountTwice() {
        let now = Date()
        let old = DictationStat(
            date: now.addingTimeInterval(-40 * 86_400),
            words: 100, characters: 500, seconds: 60
        )
        let firstRun = Stats.compacted([old], into: StatsArchive(), olderThanDays: 30, now: now)
        XCTAssertEqual(firstRun.archive.dictations, 1)
        XCTAssertEqual(firstRun.archive.words, 100)
        XCTAssertEqual(firstRun.archive.compactedPrefix, 1)
        XCTAssertTrue(firstRun.kept.isEmpty)

        // Second run with the same entries (the shortening had failed).
        let secondRun = Stats.compacted([old], into: firstRun.archive, olderThanDays: 30, now: now)
        XCTAssertEqual(secondRun.archive.dictations, 1, "the entry was counted twice")
        XCTAssertEqual(secondRun.archive.words, 100, "the words were counted twice")
        XCTAssertTrue(secondRun.kept.isEmpty)
    }

    func testANewOldEntryIsStillCompacted() {
        let now = Date()
        let early = DictationStat(
            date: now.addingTimeInterval(-60 * 86_400), words: 10, characters: 50, seconds: 6
        )
        let later = DictationStat(
            date: now.addingTimeInterval(-40 * 86_400), words: 20, characters: 100, seconds: 12
        )
        let firstRun = Stats.compacted([early], into: StatsArchive(), olderThanDays: 30, now: now)
        let secondRun = Stats.compacted([early, later], into: firstRun.archive, olderThanDays: 30, now: now)
        XCTAssertEqual(secondRun.archive.dictations, 2)
        XCTAssertEqual(secondRun.archive.words, 30)
    }

    /// The reason for a count instead of a timestamp: if the system clock jumps
    /// back (daylight saving, an NTP correction), an entry written LATER gets an
    /// older timestamp. A time marker would have discarded it without ever
    /// counting it, while the order in the file is always right.
    func testAClockJumpBackLosesNoEntry() {
        let now = Date()
        let firstWritten = DictationStat(
            date: now.addingTimeInterval(-40 * 86_400), words: 10, characters: 50, seconds: 6
        )
        // Written afterwards, but with an older stamp than the first one.
        let afterClockJump = DictationStat(
            date: now.addingTimeInterval(-50 * 86_400), words: 20, characters: 100, seconds: 12
        )
        let firstRun = Stats.compacted([firstWritten], into: StatsArchive(), olderThanDays: 30, now: now)
        let secondRun = Stats.compacted(
            [firstWritten, afterClockJump], into: firstRun.archive, olderThanDays: 30, now: now
        )
        XCTAssertEqual(secondRun.archive.dictations, 2, "the entry with the older stamp was lost")
        XCTAssertEqual(secondRun.archive.words, 30)
    }

    /// Counter-check for writing the archive a second time: after a successful
    /// shortening the marker is back at 0, recent entries must never be skipped.
    func testRecentEntriesAreNeverSkipped() {
        let now = Date()
        let recent = DictationStat(date: now, words: 5, characters: 25, seconds: 3)
        var archive = StatsArchive()
        archive.compactedPrefix = 3 // stale marker, deliberately too large
        let result = Stats.compacted([recent], into: archive, olderThanDays: 30, now: now)
        XCTAssertEqual(result.kept.count, 1, "a recent entry was discarded")
        XCTAssertEqual(result.archive.compactedPrefix, 0)
    }
}
