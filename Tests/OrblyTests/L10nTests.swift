import XCTest
@testable import Orbly

/// Genau diese Fehlerklasse ist am 2026-08-03 aufgefallen: ein Schlüssel war auf
/// Deutsch nie übersetzt („Listening …"). Ab jetzt fällt das im Test auf, nicht
/// beim Nutzer.
final class L10nTests: XCTestCase {

    private let sprachen = ["en", "de", "es", "fr", "ru"]

    private func tabelle(_ lang: String) throws -> [String: String] {
        try XCTUnwrap(L10n.tables[lang], "Sprachtabelle \(lang) fehlt komplett")
    }

    func testAlleFuenfSprachenExistieren() {
        XCTAssertEqual(Set(L10n.tables.keys), Set(sprachen))
    }

    func testJedeSpracheHatDieselbenSchluessel() throws {
        let referenz = Set(try tabelle("en").keys)
        for lang in sprachen where lang != "en" {
            let keys = Set(try tabelle(lang).keys)
            XCTAssertTrue(
                referenz.subtracting(keys).isEmpty,
                "In \(lang) fehlen: \(referenz.subtracting(keys).sorted())"
            )
            XCTAssertTrue(
                keys.subtracting(referenz).isEmpty,
                "In \(lang) stehen Schlüssel, die es auf Englisch nicht gibt: \(keys.subtracting(referenz).sorted())"
            )
        }
    }

    /// Ein abweichender Platzhalter formatiert zur Laufzeit falsch oder stürzt ab.
    func testPlatzhalterStimmenUeberein() throws {
        let en = try tabelle("en")
        for lang in sprachen where lang != "en" {
            let tabelle = try self.tabelle(lang)
            for (key, englisch) in en {
                guard let uebersetzt = tabelle[key] else { continue }
                XCTAssertEqual(
                    Self.platzhalter(englisch), Self.platzhalter(uebersetzt),
                    "Platzhalter weichen ab bei \(lang) / \(key)"
                )
            }
        }
    }

    /// Kein Wert darf leer sein - eine leere Zeichenkette sieht in der UI wie ein
    /// Fehler aus.
    func testKeineLeerenWerte() throws {
        for lang in sprachen {
            for (key, wert) in try tabelle(lang) {
                XCTAssertFalse(
                    wert.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "Leerer Text bei \(lang) / \(key)"
                )
            }
        }
    }

    /// Schreibstil-Regel des Projekts: keine Gedankenstriche als Satzzeichen.
    /// Bindestriche in zusammengesetzten Wörtern sind erlaubt, deshalb wird nur
    /// auf – und — geprüft.
    func testKeineGedankenstriche() throws {
        for lang in sprachen {
            for (key, wert) in try tabelle(lang) {
                XCTAssertFalse(
                    wert.contains("—"),
                    "Geviertstrich bei \(lang) / \(key): \(wert)"
                )
                XCTAssertFalse(
                    wert.contains("–"),
                    "Halbgeviertstrich bei \(lang) / \(key): \(wert)"
                )
            }
        }
    }

    /// Fällt eine Übersetzung auf Englisch zurück, greift der Fallback und der
    /// Nutzer sieht Englisch. Das darf nur bei Eigennamen passieren.
    func testKeineUnuebersetztenSaetze() throws {
        // Diese Schlüssel dürfen identisch mit dem Englischen sein: Lehnwörter
        // und Fachbegriffe, die in der jeweiligen Sprache genauso geschrieben
        // werden, sowie Formatstrings mit Einheitenkürzeln. Geprüft am
        // 2026-08-03, einzeln nachgesehen. Wer hier etwas ergänzt, muss vorher
        // wirklich nachschauen, ob es kein Übersetzungsloch ist.
        // Absichtlich pro Sprache UND Schlüssel: Wäre die Ausnahme nur am
        // Schlüssel festgemacht, würde ein echtes Übersetzungsloch in einer
        // anderen Sprache mit durchrutschen.
        let bekannteLehnwoerter: Set<String> = [
            "de/settings.card.overlay", "es/settings.card.overlay", "fr/settings.card.overlay",
            "de/menu.ram", "es/menu.ram",
            "de/menu.ram.withServer",
            "de/mode.server",
            "de/settings.media.pause", "fr/settings.media.pause",
            "de/settings.version", "fr/settings.version",
            "es/mode.local", "fr/mode.local",
            "es/settings.card.general",
            "es/settings.overlayStyle.orbColor",   // „color" schreibt sich spanisch gleich
            "es/stats.duration.hourMin", "fr/stats.duration.hourMin",
            "fr/settings.card.transcription",
            "fr/onboarding.permissions.mic",
        ]
        let en = try tabelle("en")
        for lang in ["de", "es", "fr"] {
            let tabelle = try self.tabelle(lang)
            for (key, englisch) in en {
                guard !bekannteLehnwoerter.contains("\(lang)/\(key)") else { continue }
                guard let uebersetzt = tabelle[key], uebersetzt == englisch else { continue }
                // Sehr kurze Werte (Kürzel, Zahlen, Symbole) nicht bewerten.
                let nurText = englisch
                    .replacingOccurrences(of: "%@", with: "")
                    .replacingOccurrences(of: "%d", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard nurText.count > 3 else { continue }
                XCTFail("\(lang) / \(key) ist identisch mit Englisch: \"\(englisch)\"")
            }
        }
    }

    /// Reihenfolge und Anzahl der Platzhalter einer Zeichenkette.
    private static func platzhalter(_ text: String) -> [String] {
        var found: [String] = []
        var rest = Substring(text)
        while let idx = rest.firstIndex(of: "%") {
            let after = rest.index(after: idx)
            guard after < rest.endIndex else { break }
            // %@, %d, %lld, %.1f ... bis zum Typ-Buchstaben lesen.
            var spec = "%"
            var cursor = after
            while cursor < rest.endIndex {
                let ch = rest[cursor]
                spec.append(ch)
                cursor = rest.index(after: cursor)
                if ch.isLetter || ch == "@" { break }
            }
            found.append(spec)
            rest = rest[cursor...]
        }
        return found
    }
}
