import XCTest
@testable import Orbly

/// The donation prompt must not make two mistakes: appear too early or too
/// often, and show up again at all after someone donated.
final class DonationTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func state(
        donated: Bool = false,
        optedOut: Bool = false,
        tourDone: Bool = true,
        dictations: Int = Donation.minimumDictations,
        lastShown: Date? = nil
    ) -> Donation.State {
        Donation.State(
            hasDonated: donated,
            promptDisabled: optedOut,
            onboardingCompleted: tourDone,
            dictations: dictations,
            lastShown: lastShown
        )
    }

    func testFirstPromptFromTheThresholdOn() {
        XCTAssertTrue(Donation.shouldShow(state(), now: now))
    }

    func testNotBeforeTheThreshold() {
        let justBelow = state(dictations: Donation.minimumDictations - 1)
        XCTAssertFalse(Donation.shouldShow(justBelow, now: now))
    }

    /// Whoever is still in the first-run tour should not get a donation prompt.
    func testNotDuringTheFirstRunTour() {
        XCTAssertFalse(Donation.shouldShow(state(tourDone: false), now: now))
    }

    /// The core requirement: after a donation there is silence for good.
    func testNeverAfterADonation() {
        let donated = state(donated: true, dictations: 10_000, lastShown: nil)
        XCTAssertFalse(Donation.shouldShow(donated, now: now))
    }

    func testNeverAfterOptingOut() {
        XCTAssertFalse(Donation.shouldShow(state(optedOut: true), now: now))
    }

    func testNotWithinThePause() {
        let aDayAgo = now.addingTimeInterval(-86_400)
        XCTAssertFalse(Donation.shouldShow(state(lastShown: aDayAgo), now: now))
    }

    func testAgainAfterThePause() {
        let gap = Double(Donation.repeatAfterDays) * 86_400 + 60
        let longAgo = now.addingTimeInterval(-gap)
        XCTAssertTrue(Donation.shouldShow(state(lastShown: longAgo), now: now))
    }

    /// Clock changed: the stored date is in the future. Then stay quiet rather
    /// than ask on every launch.
    func testAFutureDateDoesNotAsk() {
        let tomorrow = now.addingTimeInterval(86_400)
        XCTAssertFalse(Donation.shouldShow(state(lastShown: tomorrow), now: now))
    }

    /// The donation address has to look reachable, otherwise the button opens nothing.
    func testDonationAddressIsHttps() {
        XCTAssertEqual(Donation.pageURL.scheme, "https")
        XCTAssertEqual(Donation.pageURL.host, "ko-fi.com")
    }
}
