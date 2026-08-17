import XCTest
@testable import Orbly

final class ModelsTests: XCTestCase {

    // MARK: Prüfsummen

    func testSha256StimmtMitShasumUeberein() throws {
        // Referenzwert unabhängig erzeugt mit: printf 'orbly' | shasum -a 256
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("orbly-sha-test-\(UUID().uuidString)")
        try Data("orbly".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        XCTAssertEqual(
            ModelManager.sha256Hex(of: tmp),
            "bb25f6d1534ff74bf581f4de2144b6228577b6dad6e92bf2c78e0bacdd360dd7"
        )
    }

    func testSha256IstStabilUndUnterscheidetInhalte() throws {
        let dir = FileManager.default.temporaryDirectory
        let a = dir.appendingPathComponent("orbly-a-\(UUID().uuidString)")
        let b = dir.appendingPathComponent("orbly-b-\(UUID().uuidString)")
        // Größer als die 4-MB-Blockgröße, damit das blockweise Lesen mitgeprüft wird.
        try Data(repeating: 0x41, count: 5 * 1024 * 1024).write(to: a)
        var andere = Data(repeating: 0x41, count: 5 * 1024 * 1024)
        andere[andere.count - 1] = 0x42
        try andere.write(to: b)
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }

        let hashA = try XCTUnwrap(ModelManager.sha256Hex(of: a))
        XCTAssertEqual(hashA, ModelManager.sha256Hex(of: a), "Gleiche Datei, gleicher Hash")
        XCTAssertNotEqual(
            hashA, ModelManager.sha256Hex(of: b),
            "Ein einziges geändertes Byte am Ende muss auffallen"
        )
    }

    func testSha256AufFehlenderDateiIstNil() {
        let weg = FileManager.default.temporaryDirectory
            .appendingPathComponent("gibt-es-nicht-\(UUID().uuidString)")
        XCTAssertNil(ModelManager.sha256Hex(of: weg))
    }

    // MARK: Modell-Katalog

    func testJedesModellHatEinePlausiblePruefsumme() {
        for model in ModelManager.all {
            XCTAssertEqual(model.sha256.count, 64, "\(model.id): SHA-256 hat nicht 64 Zeichen")
            XCTAssertTrue(
                model.sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase },
                "\(model.id): SHA-256 muss klein geschrieben und hexadezimal sein"
            )
        }
    }

    /// `resolve/main` wäre eine bewegliche Referenz: Der Inhalt hinter der URL
    /// könnte sich ändern, ohne dass die Prüfsumme noch passt.
    func testDownloadURLsZeigenAufEinenFestenCommit() {
        for model in ModelManager.all {
            let url = model.url.absoluteString
            XCTAssertFalse(url.contains("/resolve/main/"), "\(model.id) zeigt auf main")
            XCTAssertTrue(url.hasPrefix("https://"), "\(model.id) lädt nicht über https")
            XCTAssertEqual(model.revision.count, 40, "\(model.id): Commit-SHA erwartet")
            XCTAssertTrue(
                model.revision.allSatisfy { $0.isHexDigit },
                "\(model.id): Revision ist kein Commit-Hash"
            )
        }
    }

    func testKeineDoppeltenModellIDsOderDateinamen() {
        let ids = ModelManager.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "Doppelte Modell-ID")
        let files = ModelManager.all.map(\.fileName)
        XCTAssertEqual(Set(files).count, files.count, "Zwei Modelle schreiben in dieselbe Datei")
    }

    func testUnterschiedlicheModelleHabenUnterschiedlichePruefsummen() {
        let hashes = ModelManager.all.map(\.sha256)
        XCTAssertEqual(
            Set(hashes).count, hashes.count,
            "Zwei Modelle mit derselben Prüfsumme deutet auf einen Copy-Paste-Fehler"
        )
    }

    func testJedesQualitaetsLabelExistiertInAllenSprachen() throws {
        for model in ModelManager.all {
            for lang in ["en", "de", "es", "fr", "ru"] {
                XCTAssertNotNil(
                    L10n.tables[lang]?[model.qualityKey],
                    "\(model.qualityKey) fehlt in \(lang)"
                )
            }
        }
    }

    /// Schreibstil-Regel gilt auch für Modellnamen, die direkt in der UI stehen.
    func testModellnamenOhneGedankenstriche() {
        for model in ModelManager.all {
            XCTAssertFalse(model.displayName.contains("—"), "\(model.id): Geviertstrich")
            XCTAssertFalse(model.displayName.contains("–"), "\(model.id): Halbgeviertstrich")
        }
    }

    // MARK: - Anzeigename mit Sprach-Präfix

    /// Der Sprachname stand vorher hart auf Deutsch bzw. Englisch im Modellnamen,
    /// ein französischer Nutzer las also „Deutsch:". Jetzt kommt er aus `language`
    /// und läuft über L10n.
    func testSprachspezifischeModelleZeigenUebersetztesPraefix() {
        for modell in ModelManager.languageSpecific {
            guard let sprache = modell.language else {
                XCTFail("\(modell.id): sprachspezifisches Modell ohne language")
                continue
            }
            let praefix = L10n.t("model.language.\(sprache)")
            XCTAssertNotEqual(praefix, "model.language.\(sprache)", "Schlüssel fehlt in L10n")
            XCTAssertTrue(
                modell.displayName.hasPrefix("\(praefix): "),
                "\(modell.id): \(modell.displayName) beginnt nicht mit \(praefix)"
            )
            XCTAssertFalse(modell.baseName.contains(":"), "\(modell.id): Präfix steckt noch im Namen")
        }
    }

    func testMehrsprachigeModelleHabenKeinPraefix() {
        for modell in ModelManager.multilingual {
            XCTAssertNil(modell.language, "\(modell.id) sollte mehrsprachig sein")
            XCTAssertEqual(modell.displayName, modell.baseName)
        }
    }
}
