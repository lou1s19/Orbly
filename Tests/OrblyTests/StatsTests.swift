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
        // Verglichen werden die Zahlen, nicht die Buchhaltung: `compactedPrefix`
        // MUSS hier von 1 auf 0 fallen. Der zweite Lauf bekommt `erst.kept`,
        // also die schon gekürzte Liste - genau der Fall, in dem das
        // Anfangsstück nicht mehr in der Datei steht.
        XCTAssertEqual(nochmal.archive.dictations, erst.archive.dictations, "Zweiter Lauf darf nichts verdoppeln")
        XCTAssertEqual(nochmal.archive.words, erst.archive.words, "Zweiter Lauf darf nichts verdoppeln")
        XCTAssertEqual(nochmal.archive.spokenSeconds, erst.archive.spokenSeconds, accuracy: 0.001)
        XCTAssertEqual(nochmal.archive.savedSeconds, erst.archive.savedSeconds, accuracy: 0.001)
        XCTAssertEqual(nochmal.archive.compactedPrefix, 0)
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

    // MARK: - Verdichten ist wiederholbar

    /// Bricht das Verdichten nach dem Schreiben des Archivs ab (Platte voll),
    /// stehen dieselben Einträge beim nächsten Lauf noch in stats.jsonl. Ohne
    /// die Marke `compactedUpTo` wurden sie erneut aufaddiert, und die
    /// Gesamtzahlen blieben dauerhaft zu hoch.
    func testZweitesVerdichtenZaehltNichtDoppelt() {
        let jetzt = Date()
        let alt = DictationStat(
            date: jetzt.addingTimeInterval(-40 * 86_400),
            words: 100, characters: 500, seconds: 60
        )
        let erste = Stats.compacted([alt], into: StatsArchive(), olderThanDays: 30, now: jetzt)
        XCTAssertEqual(erste.archive.dictations, 1)
        XCTAssertEqual(erste.archive.words, 100)
        XCTAssertEqual(erste.archive.compactedPrefix, 1)
        XCTAssertTrue(erste.kept.isEmpty)

        // Zweiter Lauf mit denselben Einträgen (das Kürzen war fehlgeschlagen).
        let zweite = Stats.compacted([alt], into: erste.archive, olderThanDays: 30, now: jetzt)
        XCTAssertEqual(zweite.archive.dictations, 1, "Eintrag wurde doppelt gezählt")
        XCTAssertEqual(zweite.archive.words, 100, "Wörter wurden doppelt gezählt")
        XCTAssertTrue(zweite.kept.isEmpty)
    }

    func testNeuerAlterEintragWirdWeiterhinVerdichtet() {
        let jetzt = Date()
        let frueh = DictationStat(
            date: jetzt.addingTimeInterval(-60 * 86_400), words: 10, characters: 50, seconds: 6
        )
        let spaeter = DictationStat(
            date: jetzt.addingTimeInterval(-40 * 86_400), words: 20, characters: 100, seconds: 12
        )
        let erste = Stats.compacted([frueh], into: StatsArchive(), olderThanDays: 30, now: jetzt)
        let zweite = Stats.compacted([frueh, spaeter], into: erste.archive, olderThanDays: 30, now: jetzt)
        XCTAssertEqual(zweite.archive.dictations, 2)
        XCTAssertEqual(zweite.archive.words, 30)
    }

    /// Der Grund für die Anzahl statt einer Zeitmarke: Springt die Systemuhr
    /// zurück (Zeitumstellung, NTP-Korrektur), bekommt ein SPÄTER geschriebener
    /// Eintrag einen älteren Zeitstempel. Eine Zeitmarke hätte ihn verworfen,
    /// ohne ihn je zu zählen; die Reihenfolge in der Datei stimmt dagegen immer.
    func testUhrRuecksprungVerliertKeinenEintrag() {
        let jetzt = Date()
        let zuerst = DictationStat(
            date: jetzt.addingTimeInterval(-40 * 86_400), words: 10, characters: 50, seconds: 6
        )
        // Danach geschrieben, aber mit älterem Stempel als der erste.
        let nachRuecksprung = DictationStat(
            date: jetzt.addingTimeInterval(-50 * 86_400), words: 20, characters: 100, seconds: 12
        )
        let erste = Stats.compacted([zuerst], into: StatsArchive(), olderThanDays: 30, now: jetzt)
        let zweite = Stats.compacted(
            [zuerst, nachRuecksprung], into: erste.archive, olderThanDays: 30, now: jetzt
        )
        XCTAssertEqual(zweite.archive.dictations, 2, "Eintrag mit älterem Stempel ging verloren")
        XCTAssertEqual(zweite.archive.words, 30)
    }

    /// Gegenprobe zum zweiten Archiv-Schreiben: Nach erfolgreichem Kürzen steht
    /// die Marke wieder auf 0, junge Einträge dürfen nie übersprungen werden.
    func testJungeEintraegeWerdenNieUebersprungen() {
        let jetzt = Date()
        let jung = DictationStat(date: jetzt, words: 5, characters: 25, seconds: 3)
        var archiv = StatsArchive()
        archiv.compactedPrefix = 3 // veraltete Marke, absichtlich zu groß
        let ergebnis = Stats.compacted([jung], into: archiv, olderThanDays: 30, now: jetzt)
        XCTAssertEqual(ergebnis.kept.count, 1, "junger Eintrag wurde verworfen")
        XCTAssertEqual(ergebnis.archive.compactedPrefix, 0)
    }
}
