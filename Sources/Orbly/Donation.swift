import Foundation

/// Spendenhinweis. Orbly ist quelloffen und bleibt kostenlos, deshalb fragt die
/// App genau einmal höflich nach, sobald sie sich im Alltag bewährt hat.
///
/// Bewusst ohne Server, ohne Konto und ohne Prüfung: Wer bestätigt, gespendet zu
/// haben, wird geglaubt. Bei offenem Quellcode wäre jede Prüfung in zwei Minuten
/// entfernt, und ein Bezahlserver würde genau die Daten sammeln, die Orbly sonst
/// vermeidet.
enum Donation {
    static let pageURL = URL(string: "https://ko-fi.com/lou1s")!

    /// Vorher kennt der Nutzer die App noch nicht gut genug, um zu beurteilen,
    /// ob sie ihm etwas wert ist.
    static let minimumDictations = 20

    /// Abstand zwischen zwei Nachfragen.
    static let repeatAfterDays = 14

    /// Alles, was über das Anzeigen entscheidet. Als eigener Typ, damit die
    /// Regel ohne UserDefaults testbar bleibt.
    struct State: Equatable {
        var hasDonated = false
        var promptDisabled = false
        var onboardingCompleted = false
        var dictations = 0
        var lastShown: Date?
    }

    static func shouldShow(_ state: State, now: Date = Date()) -> Bool {
        // Gespendet oder abbestellt: nie wieder.
        guard !state.hasDonated, !state.promptDisabled else { return false }
        // Nicht in die Erst-Tour hineinfragen.
        guard state.onboardingCompleted else { return false }
        guard state.dictations >= minimumDictations else { return false }
        guard let last = state.lastShown else { return true }
        let days = now.timeIntervalSince(last) / 86_400
        // Negativ heißt: gespeicherter Zeitpunkt liegt in der Zukunft (verstellte
        // Uhr). Dann lieber schweigen, statt bei jedem Start zu fragen.
        guard days >= 0 else { return false }
        return days >= Double(repeatAfterDays)
    }

    /// Aktueller Stand aus den Einstellungen.
    static var currentState: State {
        let settings = AppSettings.shared
        return State(
            hasDonated: settings.hasDonated,
            promptDisabled: settings.donationPromptDisabled,
            onboardingCompleted: settings.onboardingCompleted,
            dictations: settings.dictationCount,
            lastShown: settings.donationPromptLastShown
        )
    }

    static var shouldShowNow: Bool { shouldShow(currentState) }
}
