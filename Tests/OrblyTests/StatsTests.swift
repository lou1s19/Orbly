import XCTest
@testable import Orbly

final class StatsTests: XCTestCase {

    /// Fester Kalender und feste „jetzt"-Zeit, damit der Test nicht davon
    /// abhängt, wann er läuft.
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

    func testSummeUeberAlleEintraege() {
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

    func testZeitersparnisGegenTippen() {
        // 40 Wörter bei 40 WPM = 60 s Tippen, 20 s gesprochen -> 40 s gespart.
        let s = Stats.summarize(
            [stat("2026-08-03T10:00:00+02:00", words: 40, seconds: 20)],
            now: date("2026-08-03T12:00:00+02:00"), calendar: calendar
        )
        XCTAssertEqual(s.savedSeconds, 40, accuracy: 0.001)
    }

    func testErsparnisWirdNieNegativ() {
        // Langsam gesprochen: Tippen wäre schneller gewesen. Trotzdem nicht < 0,
        // sonst würde ein langsames Diktat gesparte Zeit wieder abziehen.
        let s = Stats.summarize(
            [stat("2026-08-03T10:00:00+02:00", words: 5, seconds: 300)],
            now: date("2026-08-03T12:00:00+02:00"), calendar: calendar
        )
        XCTAssertEqual(s.savedSeconds, 0)
    }

    func testTagesreiheHatImmerDieVerlangteLaenge() {
        let s = Stats.summarize(
            [stat("2026-08-03T10:00:00+02:00", words: 10, seconds: 5)],
            days: 14, now: date("2026-08-03T12:00:00+02:00"), calendar: calendar
        )
        XCTAssertEqual(s.perDay.count, 14)
        XCTAssertEqual(s.perDay.last?.words, 10, "Heute muss der letzte Eintrag sein")
        XCTAssertEqual(s.perDay.first?.words, 0, "Tage ohne Diktat sind 0, nicht ausgelassen")
    }

    func testEintraegeAmselbenTagWerdenAddiert() {
        let entries = [
            stat("2026-08-03T08:00:00+02:00", words: 10, seconds: 5),
            stat("2026-08-03T20:00:00+02:00", words: 15, seconds: 5),
        ]
        let s = Stats.summarize(
            entries, days: 3, now: date("2026-08-03T22:00:00+02:00"), calendar: calendar
        )
        XCTAssertEqual(s.perDay.last?.words, 25)
    }

    func testArchivZahltInDieGesamtsummeAberNichtInsDiagramm() {
        let archive = StatsArchive(dictations: 100, words: 5000, spokenSeconds: 2000, savedSeconds: 3000)
        let s = Stats.summarize(
            [stat("2026-08-03T10:00:00+02:00", words: 10, seconds: 5)],
            archive: archive, days: 3,
            now: date("2026-08-03T12:00:00+02:00"), calendar: calendar
        )
        XCTAssertEqual(s.dictations, 101)
        XCTAssertEqual(s.words, 5010)
        XCTAssertEqual(s.perDay.last?.words, 10, "Archiv darf das Diagramm nicht verfälschen")
    }

    func testLeereStatistik() {
        let s = Stats.summarize([], days: 7, now: date("2026-08-03T12:00:00+02:00"), calendar: calendar)
        XCTAssertEqual(s.dictations, 0)
        XCTAssertEqual(s.wordsPerDictation, 0, "Keine Division durch 0")
        XCTAssertEqual(s.perDay.count, 7)
    }

    // MARK: Verdichten

    func testVerdichtenFasstNurAlteEintraegeZusammen() {
        let now = date("2026-08-03T12:00:00+02:00")
        let entries = [
            stat("2026-05-01T10:00:00+02:00", words: 40, seconds: 20),   // alt
            stat("2026-08-01T10:00:00+02:00", words: 10, seconds: 5),    // neu
        ]
        let r = Stats.compacted(entries, into: StatsArchive(), olderThanDays: 30, now: now)
        XCTAssertEqual(r.kept.count, 1)
        XCTAssertEqual(r.archive.dictations, 1)
        XCTAssertEqual(r.archive.words, 40)
        XCTAssertEqual(r.archive.savedSeconds, 40, accuracy: 0.001)
    }

    func testVerdichtenVerliertKeineGesamtsummen() {
        let now = date("2026-08-03T12:00:00+02:00")
        let entries = [
            stat("2026-01-01T10:00:00+02:00", words: 40, seconds: 20),
            stat("2026-02-01T10:00:00+02:00", words: 60, seconds: 30),
            stat("2026-08-02T10:00:00+02:00", words: 10, seconds: 5),
        ]
        let vorher = Stats.summarize(entries, days: 14, now: now, calendar: calendar)
        let r = Stats.compacted(entries, into: StatsArchive(), olderThanDays: 30, now: now)
        let nachher = Stats.summarize(r.kept, archive: r.archive, days: 14, now: now, calendar: calendar)

        XCTAssertEqual(nachher.dictations, vorher.dictations)
        XCTAssertEqual(nachher.words, vorher.words)
        XCTAssertEqual(nachher.spokenSeconds, vorher.spokenSeconds, accuracy: 0.001)
        XCTAssertEqual(nachher.savedSeconds, vorher.savedSeconds, accuracy: 0.001)
    }

    func testVerdichtenIstWiederholbarOhneDoppeltZuZaehlen() {
        let now = date("2026-08-03T12:00:00+02:00")
        let entries = [stat("2026-01-01T10:00:00+02:00", words: 40, seconds: 20)]
        let erst = Stats.compacted(entries, into: StatsArchive(), olderThanDays: 30, now: now)
        let nochmal = Stats.compacted(erst.kept, into: erst.archive, olderThanDays: 30, now: now)
        XCTAssertEqual(nochmal.archive, erst.archive, "Zweiter Lauf darf nichts verdoppeln")
    }

    // MARK: Datei-Format

    func testDecodeUeberspringtKaputteZeilen() {
        let content = """
        {"date":"2026-08-03T10:00:00Z","words":10,"characters":60,"seconds":5}
        das ist keine gültige Zeile
        {"date":"2026-08-03T11:00:00Z","words":20,"characters":120,"seconds":8}
        """
        let entries = Stats.decode(content)
        XCTAssertEqual(entries.count, 2, "Eine kaputte Zeile darf nicht alles verwerfen")
        XCTAssertEqual(entries.map(\.words), [10, 20])
    }

    func testStatistikSpeichertKeinenText() throws {
        // Datenschutz-Versprechen aus README und CLAUDE.md: Die Statistik
        // speichert nur Zahlen. Schlägt dieser Test fehl, hat jemand ein
        // Textfeld eingebaut.
        let stat = DictationStat(date: Date(), words: 1, characters: 1, seconds: 1)
        let data = try JSONEncoder().encode(stat)
        let fields = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(Set(fields.keys), ["date", "words", "characters", "seconds"])
    }
}
