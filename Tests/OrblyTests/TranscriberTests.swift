import XCTest
@testable import Orbly

/// `joinSegments` ist der Fix für Lücken mitten im Wort („gest alten").
/// whisper-server trennt Segmente mit \n und stellt jedem WORTANFANG ein
/// Leerzeichen voran. Fehlt es, wurde mitten im Wort getrennt.
final class TranscriberTests: XCTestCase {

    func testEchteServerausgabeMitTrennungImWort() {
        // Genau diese Antwort kam vom Server, als der Fehler auftrat.
        let raw = " Ich finde den Ü\nbergang schön, wenn er lädt."
        XCTAssertEqual(
            Transcriber.joinSegments(raw),
            "Ich finde den Übergang schön, wenn er lädt."
        )
    }

    func testWortanfangBekommtLeerzeichen() {
        XCTAssertEqual(Transcriber.joinSegments(" Hallo\n Welt"), "Hallo Welt")
    }

    func testSatzzeichenWirdDirektAngehaengt() {
        XCTAssertEqual(Transcriber.joinSegments(" Hallo Welt\n."), "Hallo Welt.")
    }

    func testMehrereSegmente() {
        let raw = " Erstens.\n Zweitens.\n Drittens."
        XCTAssertEqual(Transcriber.joinSegments(raw), "Erstens. Zweitens. Drittens.")
    }

    func testLeereSegmenteWerdenUebersprungen() {
        XCTAssertEqual(Transcriber.joinSegments(" Eins\n\n\n Zwei"), "Eins Zwei")
    }

    func testWhitespaceFolgenInnerhalbEinesSegments() {
        XCTAssertEqual(Transcriber.joinSegments(" Eins    Zwei"), "Eins Zwei")
    }

    func testLeererText() {
        XCTAssertEqual(Transcriber.joinSegments(""), "")
        XCTAssertEqual(Transcriber.joinSegments("\n\n"), "")
    }

    func testEinzelnesSegmentOhneUmbruch() {
        XCTAssertEqual(Transcriber.joinSegments(" Nur ein Satz."), "Nur ein Satz.")
    }

    func testKeinLeerzeichenVerlorenBeiTabsUndUmbruechen() {
        XCTAssertEqual(Transcriber.joinSegments(" Eins\t\n Zwei"), "Eins Zwei")
    }
}
