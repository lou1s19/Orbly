import XCTest
@testable import Orbly

/// The first Fn press after a long pause seemed to do nothing: the audio
/// hardware woke up first, the recording stayed below the minimum length and
/// was discarded silently. These tests pin down when that becomes a note.
final class WakeUpPressTests: XCTestCase {

    func testWakeUpPressWithSlowAudioHardwareShowsNote() {
        XCTAssertTrue(
            WakeUpPress.shouldHint(recordingWasTooShort: true, audioWarmup: 1.2)
        )
    }

    /// Fn only brushed, everything warm: stays silent as before, otherwise a note
    /// would flash up on every misfire.
    func testShortMisfireStaysSilent() {
        XCTAssertFalse(
            WakeUpPress.shouldHint(recordingWasTooShort: true, audioWarmup: 0.01)
        )
    }

    /// A dictation that got long enough despite sleeping hardware did go through,
    /// so there is no reason to complain about it.
    func testLongEnoughRecordingNeverShowsNote() {
        XCTAssertFalse(
            WakeUpPress.shouldHint(recordingWasTooShort: false, audioWarmup: 2.0)
        )
    }

    func testExactlyAtTheThresholdCountsAsAWakeUpPress() {
        XCTAssertTrue(
            WakeUpPress.shouldHint(
                recordingWasTooShort: true, audioWarmup: WakeUpPress.warmupThreshold
            )
        )
    }
}
