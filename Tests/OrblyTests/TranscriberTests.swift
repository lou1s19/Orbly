import XCTest
@testable import Orbly

/// `joinSegments` is the fix for gaps in the middle of a word ("gest alten").
/// whisper-server separates segments with \n and puts a space in front of every
/// word start. If it is missing, the split happened inside a word.
///
/// The sample texts are German on purpose: that is the recorded output from the
/// session where the bug appeared, including the umlaut that whisper split.
final class TranscriberTests: XCTestCase {

    func testRealServerOutputWithASplitInsideAWord() {
        // This is the exact response the server sent when the bug showed up.
        let raw = " Ich finde den Ü\nbergang schön, wenn er lädt."
        XCTAssertEqual(
            Transcriber.joinSegments(raw),
            "Ich finde den Übergang schön, wenn er lädt."
        )
    }

    func testWordStartGetsASpace() {
        XCTAssertEqual(Transcriber.joinSegments(" Hallo\n Welt"), "Hallo Welt")
    }

    func testPunctuationIsAppendedDirectly() {
        XCTAssertEqual(Transcriber.joinSegments(" Hallo Welt\n."), "Hallo Welt.")
    }

    func testSeveralSegments() {
        let raw = " Erstens.\n Zweitens.\n Drittens."
        XCTAssertEqual(Transcriber.joinSegments(raw), "Erstens. Zweitens. Drittens.")
    }

    func testEmptySegmentsAreSkipped() {
        XCTAssertEqual(Transcriber.joinSegments(" Eins\n\n\n Zwei"), "Eins Zwei")
    }

    func testWhitespaceRunsInsideASegment() {
        XCTAssertEqual(Transcriber.joinSegments(" Eins    Zwei"), "Eins Zwei")
    }

    func testEmptyText() {
        XCTAssertEqual(Transcriber.joinSegments(""), "")
        XCTAssertEqual(Transcriber.joinSegments("\n\n"), "")
    }

    func testSingleSegmentWithoutALineBreak() {
        XCTAssertEqual(Transcriber.joinSegments(" Nur ein Satz."), "Nur ein Satz.")
    }

    func testNoSpaceLostOnTabsAndLineBreaks() {
        XCTAssertEqual(Transcriber.joinSegments(" Eins\t\n Zwei"), "Eins Zwei")
    }

    // MARK: - cleanup: whisper placeholders on silence

    /// The earlier expression required the WHOLE text to be one bracket group. If
    /// the silence spans more than one segment boundary (about 30 s), whisper
    /// returns several, and those ended up verbatim in the document.
    func testRepeatedBlankAudioIsRemoved() {
        XCTAssertEqual(Transcriber.cleanup(" [BLANK_AUDIO]\n [BLANK_AUDIO]"), "")
        XCTAssertEqual(Transcriber.cleanup(" (Musik)\n (Musik)"), "")
    }

    func testBlankAudioBeforeRealTextIsRemoved() {
        XCTAssertEqual(Transcriber.cleanup(" [BLANK_AUDIO]\n Hallo Welt"), "Hallo Welt")
        XCTAssertEqual(Transcriber.cleanup(" Hallo Welt\n [BLANK_AUDIO]"), "Hallo Welt")
    }

    func testSinglePlaceholderAsBefore() {
        XCTAssertEqual(Transcriber.cleanup("[BLANK_AUDIO]"), "")
        XCTAssertEqual(Transcriber.cleanup(" (Musik)"), "")
    }

    func testRealTextStaysUnchanged() {
        XCTAssertEqual(Transcriber.cleanup(" Das ist ein Satz."), "Das ist ein Satz.")
    }

    /// The counter-check for the filtering: brackets IN THE MIDDLE of a dictation
    /// are text the user wanted and must not disappear. The first version of this
    /// fix removed every bracket group indiscriminately.
    func testBracketsInASentenceAreKept() {
        XCTAssertEqual(
            Transcriber.cleanup(" Treffen (verschoben) auf Montag"),
            "Treffen (verschoben) auf Montag"
        )
        XCTAssertEqual(Transcriber.cleanup(" Nimm array[index] her"), "Nimm array[index] her")
    }

    func testBracketSegmentBetweenRealSegments() {
        XCTAssertEqual(
            Transcriber.cleanup(" Erster Teil\n [BLANK_AUDIO]\n zweiter Teil"),
            "Erster Teil zweiter Teil"
        )
    }
}
