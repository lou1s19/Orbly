import XCTest
@testable import Orbly

final class SettingsTests: XCTestCase {

    /// Warning in the settings: http to another machine sends the recording in
    /// the clear, loopback does not.
    func testLoopbackDoesNotCountAsInsecure() {
        for address in [
            "http://127.0.0.1:8642/inference",
            "http://localhost:8642/inference",
            "http://[::1]:8642/inference",
        ] {
            XCTAssertFalse(
                AppSettings.isInsecureRemoteEndpoint(address),
                "\(address) never leaves the Mac"
            )
        }
    }

    func testHttpToAForeignHostIsInsecure() {
        for address in [
            "http://192.168.1.50:8643/inference",
            "http://ubuntu-server:8643/inference",
            // Address from the documentation range (RFC 5737). It stands for a
            // server behind a VPN or Tailscale: that one is not encrypted over
            // http either, just because the network is private.
            "http://203.0.113.5:8643/inference",
            "http://example.com/inference",
        ] {
            XCTAssertTrue(
                AppSettings.isInsecureRemoteEndpoint(address),
                "\(address) transmits the recording in the clear"
            )
        }
    }

    func testHttpsIsNeverInsecure() {
        XCTAssertFalse(AppSettings.isInsecureRemoteEndpoint("https://example.com/inference"))
        XCTAssertFalse(AppSettings.isInsecureRemoteEndpoint("HTTPS://Example.com/inference"))
    }

    func testCasingAndWhitespaceChangeNothing() {
        XCTAssertTrue(AppSettings.isInsecureRemoteEndpoint("  HTTP://192.168.1.50/inference  "))
        XCTAssertFalse(AppSettings.isInsecureRemoteEndpoint("  http://LOCALHOST:8642/x  "))
    }

    func testIncompleteInputRaisesNoFalseAlarm() {
        // While typing this field holds unfinished input, so no warning then.
        for input in ["", "http://", "not a url", "192.168.1.50"] {
            XCTAssertFalse(
                AppSettings.isInsecureRemoteEndpoint(input),
                "false alarm for \"\(input)\""
            )
        }
    }

    // MARK: - Timers in .common mode

    /// `Timer.scheduledTimer` only hangs in `.default` mode and stands still as
    /// soon as a menu is open or something is scrolled. That is exactly when the
    /// Fn watchdog and the recording time limit have to keep running.
    /// The actual bug was not the timer itself but the wrong factory method in
    /// five places. That is what this test checks: `Timer.scheduledTimer` must not
    /// appear in `Sources` any more, otherwise the safety net stands still again
    /// as soon as a menu is open.
    func testNoScheduledTimerLeftInTheSource() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Orbly")
        let files = try FileManager.default
            .contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "no source files found under \(sources.path)")

        for file in files {
            let content = try String(contentsOf: file, encoding: .utf8)
            for (no, line) in content.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
                XCTAssertFalse(
                    line.contains("Timer.scheduledTimer"),
                    "\(file.lastPathComponent):\(no + 1) uses Timer.scheduledTimer instead of Timer.scheduledCommon"
                )
            }
        }
    }

    func testScheduledCommonAdoptsTheTolerance() {
        let timer = Timer.scheduledCommon(every: 30, repeats: true, tolerance: 10) { _ in }
        defer { timer.invalidate() }
        XCTAssertEqual(timer.tolerance, 10, accuracy: 0.001)
        XCTAssertTrue(timer.isValid)
    }
}
