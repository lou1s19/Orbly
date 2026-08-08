import XCTest
@testable import Orbly

/// Der erste Fn-Druck nach langer Pause schien nichts zu tun: Die Audio-Hardware
/// wachte erst auf, die Aufnahme blieb unter der Mindestlänge und wurde still
/// verworfen. Diese Tests halten fest, wann daraus ein Hinweis wird.
final class WakeUpPressTests: XCTestCase {

    func testAufwachdruckMitLangsamerAudioHardwareZeigtHinweis() {
        XCTAssertTrue(
            WakeUpPress.shouldHint(
                recordingWasTooShort: true,
                audioWarmup: 1.2,
                serverColdStart: false
            )
        )
    }

    func testAufwachdruckMitServerKaltstartZeigtHinweis() {
        XCTAssertTrue(
            WakeUpPress.shouldHint(
                recordingWasTooShort: true,
                audioWarmup: 0.01,
                serverColdStart: true
            )
        )
    }

    /// Fn nur gestreift, alles war warm: bleibt stumm wie bisher, sonst blinkt
    /// bei jedem Fehlgriff ein Hinweis auf.
    func testKurzesVersehenBleibtStumm() {
        XCTAssertFalse(
            WakeUpPress.shouldHint(
                recordingWasTooShort: true,
                audioWarmup: 0.01,
                serverColdStart: false
            )
        )
    }

    /// Ein normales Diktat mit Kaltstart lief ja durch - dafür gibt es keinen Grund
    /// zu meckern.
    func testAusreichendLangeAufnahmeNieMitHinweis() {
        XCTAssertFalse(
            WakeUpPress.shouldHint(
                recordingWasTooShort: false,
                audioWarmup: 2.0,
                serverColdStart: true
            )
        )
    }

    func testGenauAufDerSchwelleGiltAlsAufwachdruck() {
        XCTAssertTrue(
            WakeUpPress.shouldHint(
                recordingWasTooShort: true,
                audioWarmup: WakeUpPress.warmupThreshold,
                serverColdStart: false
            )
        )
    }
}
