import Foundation

/// Donation prompt. Orbly is open source and stays free, so the app asks
/// politely exactly once, after it has proven itself in everyday use.
///
/// Deliberately without a server, an account or a check: whoever confirms they
/// donated is believed. With open source any check would be removed in two
/// minutes, and a payment server would collect exactly the data Orbly otherwise
/// vermeidet.
enum Donation {
    static let pageURL = URL(string: "https://ko-fi.com/lou1s")!

    /// Before that the user does not know the app well enough to judge whether it
    /// is worth anything to them.
    static let minimumDictations = 20

    /// Gap between two prompts, in days.
    static let repeatAfterDays = 14

    /// Everything that decides whether to show it. A separate type, so the rule
    /// stays testable without UserDefaults.
    struct State: Equatable {
        var hasDonated = false
        var promptDisabled = false
        var onboardingCompleted = false
        var dictations = 0
        var lastShown: Date?
    }

    static func shouldShow(_ state: State, now: Date = Date()) -> Bool {
        // Donated or opted out: never again.
        guard !state.hasDonated, !state.promptDisabled else { return false }
        // Do not interrupt the first-run tour with it.
        guard state.onboardingCompleted else { return false }
        guard state.dictations >= minimumDictations else { return false }
        guard let last = state.lastShown else { return true }
        let days = now.timeIntervalSince(last) / 86_400
        // Negative means the stored date is in the future (clock changed). Then
        // stay quiet rather than ask on every launch.
        guard days >= 0 else { return false }
        return days >= Double(repeatAfterDays)
    }

    /// Current state from the settings.
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
