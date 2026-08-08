import XCTest
@testable import Orbly

/// Der Spendenhinweis darf zwei Fehler nicht machen: zu früh oder zu oft
/// erscheinen, und nach einer Spende überhaupt noch einmal auftauchen.
final class DonationTests: XCTestCase {

    private let jetzt = Date(timeIntervalSince1970: 1_800_000_000)

    private func stand(
        gespendet: Bool = false,
        abbestellt: Bool = false,
        tourFertig: Bool = true,
        diktate: Int = Donation.minimumDictations,
        zuletzt: Date? = nil
    ) -> Donation.State {
        Donation.State(
            hasDonated: gespendet,
            promptDisabled: abbestellt,
            onboardingCompleted: tourFertig,
            dictations: diktate,
            lastShown: zuletzt
        )
    }

    func testErsteAnzeigeAbDerSchwelle() {
        XCTAssertTrue(Donation.shouldShow(stand(), now: jetzt))
    }

    func testVorDerSchwelleNicht() {
        let knappDrunter = stand(diktate: Donation.minimumDictations - 1)
        XCTAssertFalse(Donation.shouldShow(knappDrunter, now: jetzt))
    }

    /// Wer noch in der Erst-Tour steckt, soll keine Spendenbitte bekommen.
    func testWaehrendDerErstTourNicht() {
        XCTAssertFalse(Donation.shouldShow(stand(tourFertig: false), now: jetzt))
    }

    /// Der Kern der Anforderung: nach einer Spende ist dauerhaft Ruhe.
    func testNachSpendeNie() {
        let gespendet = stand(gespendet: true, diktate: 10_000, zuletzt: nil)
        XCTAssertFalse(Donation.shouldShow(gespendet, now: jetzt))
    }

    func testNachAbbestellenNie() {
        XCTAssertFalse(Donation.shouldShow(stand(abbestellt: true), now: jetzt))
    }

    func testInnerhalbDerPauseNicht() {
        let vorEinemTag = jetzt.addingTimeInterval(-86_400)
        XCTAssertFalse(Donation.shouldShow(stand(zuletzt: vorEinemTag), now: jetzt))
    }

    func testNachDerPauseWieder() {
        let abstand = Double(Donation.repeatAfterDays) * 86_400 + 60
        let lange = jetzt.addingTimeInterval(-abstand)
        XCTAssertTrue(Donation.shouldShow(stand(zuletzt: lange), now: jetzt))
    }

    /// Verstellte Uhr: gespeicherter Zeitpunkt liegt in der Zukunft. Dann lieber
    /// schweigen, statt bei jedem Start zu fragen.
    func testZukunftsdatumFragtNicht() {
        let morgen = jetzt.addingTimeInterval(86_400)
        XCTAssertFalse(Donation.shouldShow(stand(zuletzt: morgen), now: jetzt))
    }

    /// Die Spendenadresse muss erreichbar aussehen, sonst öffnet der Knopf nichts.
    func testSpendenadresseIstHttps() {
        XCTAssertEqual(Donation.pageURL.scheme, "https")
        XCTAssertEqual(Donation.pageURL.host, "ko-fi.com")
    }
}
