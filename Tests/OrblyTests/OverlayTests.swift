import XCTest
@testable import Orbly

final class OverlayTests: XCTestCase {

    override func tearDown() {
        OverlayStyleFallback.orbUnavailable = false
        super.tearDown()
    }

    func testOhneMetalProblemBleibtDerStilWieGewaehlt() {
        OverlayStyleFallback.orbUnavailable = false
        for style in OverlayStyle.allCases {
            XCTAssertEqual(OverlayStyleFallback.effective(style), style)
        }
    }

    /// Ohne Metal-Gerät oder mit fehlgeschlagenem Shader bliebe das Overlay
    /// unsichtbar - orbMono ist der Standardstil, die App wirkte dann tot.
    func testOrbStileFallenAufPillZurueck() {
        OverlayStyleFallback.orbUnavailable = true
        XCTAssertEqual(OverlayStyleFallback.effective(.orb), .pill)
        XCTAssertEqual(OverlayStyleFallback.effective(.orbMono), .pill)
    }

    func testReineSwiftUIStileBleibenUnangetastet() {
        OverlayStyleFallback.orbUnavailable = true
        XCTAssertEqual(OverlayStyleFallback.effective(.pill), .pill)
        XCTAssertEqual(
            OverlayStyleFallback.effective(.minimal), .minimal,
            "minimal ist reines SwiftUI und braucht keinen Rückfall"
        )
    }

    func testJederStilHatGroesseUndBalkenzahl() {
        for style in OverlayStyle.allCases {
            XCTAssertGreaterThan(style.size.width, 0)
            XCTAssertGreaterThan(style.size.height, 0)
            XCTAssertGreaterThan(style.barCount, 0, "Sonst wirft push(level:) ins Leere")
        }
    }

    /// `push` darf bei leerem Pegel-Array nicht abstürzen (removeFirst auf leer).
    func testPushOhneVorherigesResetStuerztNicht() {
        let state = OverlayState()
        state.push(level: 0.5)
        XCTAssertTrue(state.levels.isEmpty)
    }

    func testResetFuelltPegelPassendZumStil() {
        let state = OverlayState()
        state.reset(style: .minimal)
        XCTAssertEqual(state.levels.count, OverlayStyle.minimal.barCount)
        XCTAssertEqual(state.phase, .recording)
    }

    func testPushHaeltDieLaengeKonstant() {
        let state = OverlayState()
        state.reset(style: .pill)
        let vorher = state.levels.count
        for _ in 0..<50 { state.push(level: 0.4) }
        XCTAssertEqual(state.levels.count, vorher)
    }
}
