import Foundation

/// Detects the "wake-up press": the first Fn press after a longer pause, where
/// seemingly nothing happens.
///
/// Background: if the last dictation was a while ago, the audio hardware is
/// asleep (and in local mode often the whisper-server too). The Fn press wakes
/// both up, but waking blocks the start of the recording. Whoever only taps Fn
/// briefly has let go before any audio arrived, which leaves a recording below
/// the 0.3 s threshold that used to be discarded silently.
/// To the user that looked like "the first press does nothing, only the second".
///
/// Instead of vanishing silently, Orbly now shows a short note that it is awake
/// and that you should press again.
enum WakeUpPress {
    /// From this start duration on, the audio hardware was measurably asleep.
    /// Warm, the start is far below that (a few milliseconds).
    static let warmupThreshold: TimeInterval = 0.2

    /// Deliberately only the measured wake-up time of the audio hardware. A cold
    /// start of the local whisper-server is a sign of a long pause too, but it does
    /// not cost a recording: it runs alongside while recording is already going. As
    /// a trigger it would inflate every accidental brush of the Fn key after a
    /// pause into a note.
    ///
    /// - Parameters:
    ///   - recordingWasTooShort: the recording did not reach the minimum length.
    ///   - audioWarmup: how long the last `AudioRecorder.start()` took.
    static func shouldHint(recordingWasTooShort: Bool, audioWarmup: TimeInterval) -> Bool {
        // An ordinary misfire (Fn brushed briefly) stays silent as before. A note on
        // every accidental tap would only be annoying.
        guard recordingWasTooShort else { return false }
        return audioWarmup >= warmupThreshold
    }
}
