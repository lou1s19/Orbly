import Foundation

/// Erkennt den "Aufwachdruck": den ersten Fn-Druck nach längerer Pause, bei dem
/// scheinbar nichts passiert.
///
/// Hintergrund: Liegt das letzte Diktat lange zurück, schläft die Audio-Hardware
/// (und im lokalen Modus oft auch der whisper-server). Der Fn-Druck weckt beides
/// auf, das Aufwecken blockiert aber den Start der Aufnahme. Wer Fn nur kurz
/// antippt, hat dann losgelassen, bevor überhaupt Ton ankam - übrig bleibt eine
/// Aufnahme unter der 0,3-s-Grenze, die bisher stillschweigend verworfen wurde.
/// Für den Nutzer sah das aus wie "der erste Druck tut nichts, erst der zweite".
///
/// Statt still zu verschwinden zeigt Orbly in diesem Fall einen kurzen Hinweis,
/// dass es jetzt wach ist und man noch einmal drücken soll.
enum WakeUpPress {
    /// Ab dieser Startdauer war die Audio-Hardware erkennbar eingeschlafen.
    /// Warm liegt der Start deutlich darunter (wenige Millisekunden).
    static let warmupThreshold: TimeInterval = 0.2

    /// Bewusst nur die gemessene Aufwachzeit der Audio-Hardware. Ein Kaltstart des
    /// lokalen whisper-servers ist zwar auch ein Zeichen langer Pause, kostet aber
    /// keine Aufnahme: Er läuft nebenher, während schon aufgenommen wird. Als
    /// Auslöser genommen, würde er jeden versehentlichen Fn-Streifer nach einer
    /// Pause zu einem Hinweis aufblasen.
    ///
    /// - Parameters:
    ///   - recordingWasTooShort: Die Aufnahme hat die Mindestlänge nicht erreicht.
    ///   - audioWarmup: Dauer des letzten `AudioRecorder.start()`.
    static func shouldHint(recordingWasTooShort: Bool, audioWarmup: TimeInterval) -> Bool {
        // Ein normaler Fehlgriff (Fn kurz gestreift) bleibt stumm wie bisher -
        // ein Hinweis bei jedem versehentlichen Antippen wäre nur lästig.
        guard recordingWasTooShort else { return false }
        return audioWarmup >= warmupThreshold
    }
}
