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

    // MARK: - cleanup: whisper-Platzhalter bei Stille

    /// Der frühere Ausdruck verlangte, dass der GESAMTE Text eine Klammergruppe
    /// ist. Geht die Stille über mehr als eine Segmentgrenze (ca. 30 s), liefert
    /// whisper mehrere, und die landeten wörtlich im Dokument.
    func testMehrfachesBlankAudioWirdEntfernt() {
        XCTAssertEqual(Transcriber.cleanup(" [BLANK_AUDIO]\n [BLANK_AUDIO]"), "")
        XCTAssertEqual(Transcriber.cleanup(" (Musik)\n (Musik)"), "")
    }

    func testBlankAudioVorEchtemTextWirdEntfernt() {
        XCTAssertEqual(Transcriber.cleanup(" [BLANK_AUDIO]\n Hallo Welt"), "Hallo Welt")
        XCTAssertEqual(Transcriber.cleanup(" Hallo Welt\n [BLANK_AUDIO]"), "Hallo Welt")
    }

    func testEinzelnerPlatzhalterWieBisher() {
        XCTAssertEqual(Transcriber.cleanup("[BLANK_AUDIO]"), "")
        XCTAssertEqual(Transcriber.cleanup(" (Musik)"), "")
    }

    func testEchterTextBleibtUnveraendert() {
        XCTAssertEqual(Transcriber.cleanup(" Das ist ein Satz."), "Das ist ein Satz.")
    }

    /// Gegenprobe zum Aussortieren: Klammern MITTEN im Diktat sind gewollter
    /// Text und dürfen nicht verschwinden. (Codex-Fund an der ersten Fassung
    /// dieser Korrektur, die pauschal jede Klammergruppe entfernt hätte.)
    func testKlammernImSatzBleibenErhalten() {
        XCTAssertEqual(
            Transcriber.cleanup(" Treffen (verschoben) auf Montag"),
            "Treffen (verschoben) auf Montag"
        )
        XCTAssertEqual(Transcriber.cleanup(" Nimm array[index] her"), "Nimm array[index] her")
    }

    func testKlammerSegmentZwischenEchtenSegmenten() {
        XCTAssertEqual(
            Transcriber.cleanup(" Erster Teil\n [BLANK_AUDIO]\n zweiter Teil"),
            "Erster Teil zweiter Teil"
        )
    }
}
