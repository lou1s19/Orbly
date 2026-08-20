import XCTest
@testable import Orbly

final class OverlayTests: XCTestCase {

    override func tearDown() {
        OverlayStyleFallback.orbUnavailable = false
        super.tearDown()
    }

    func testWithoutAMetalProblemTheStyleStaysAsChosen() {
        OverlayStyleFallback.orbUnavailable = false
        for style in OverlayStyle.allCases {
            XCTAssertEqual(OverlayStyleFallback.effective(style), style)
        }
    }

    /// Without a Metal device, or with a failed shader, the overlay would stay
    /// invisible. orbMono is the default style, so the app would look dead.
    func testOrbStylesFallBackToPill() {
        OverlayStyleFallback.orbUnavailable = true
        XCTAssertEqual(OverlayStyleFallback.effective(.orb), .pill)
        XCTAssertEqual(OverlayStyleFallback.effective(.orbMono), .pill)
    }

    func testPlainSwiftUIStylesStayUntouched() {
        OverlayStyleFallback.orbUnavailable = true
        XCTAssertEqual(OverlayStyleFallback.effective(.pill), .pill)
        XCTAssertEqual(
            OverlayStyleFallback.effective(.minimal), .minimal,
            "minimal is plain SwiftUI and needs no fallback"
        )
    }

    func testEveryStyleHasASizeAndABarCount() {
        for style in OverlayStyle.allCases {
            XCTAssertGreaterThan(style.size.width, 0)
            XCTAssertGreaterThan(style.size.height, 0)
            XCTAssertGreaterThan(style.barCount, 0, "otherwise push(level:) writes into the void")
        }
    }

    /// `push` must not crash on an empty level array (removeFirst on empty).
    func testPushWithoutAPriorResetDoesNotCrash() {
        let state = OverlayState()
        state.push(level: 0.5)
        XCTAssertTrue(state.levels.isEmpty)
    }

    func testResetFillsLevelsToMatchTheStyle() {
        let state = OverlayState()
        state.reset(style: .minimal)
        XCTAssertEqual(state.levels.count, OverlayStyle.minimal.barCount)
        XCTAssertEqual(state.phase, .recording)
    }

    func testPushKeepsTheLengthConstant() {
        let state = OverlayState()
        state.reset(style: .pill)
        let before = state.levels.count
        for _ in 0..<50 { state.push(level: 0.4) }
        XCTAssertEqual(state.levels.count, before)
    }
}
