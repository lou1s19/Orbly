import XCTest
@testable import Orbly

final class SettingsTests: XCTestCase {

    /// Warnhinweis in den Einstellungen: http auf einen anderen Rechner überträgt
    /// die Aufnahme im Klartext, Loopback nicht.
    func testLoopbackGiltNichtAlsUnsicher() {
        for adresse in [
            "http://127.0.0.1:8642/inference",
            "http://localhost:8642/inference",
            "http://[::1]:8642/inference",
        ] {
            XCTAssertFalse(
                AppSettings.isInsecureRemoteEndpoint(adresse),
                "\(adresse) verlässt den Mac nicht"
            )
        }
    }

    func testHttpAufFremdenHostIstUnsicher() {
        for adresse in [
            "http://192.168.1.50:8643/inference",
            "http://ubuntu-server:8643/inference",
            // Adresse aus dem Dokumentationsbereich (RFC 5737). Steht hier für
            // einen Server hinter VPN oder Tailscale: auch der ist über http
            // nicht verschlüsselt, nur weil das Netz privat ist.
            "http://203.0.113.5:8643/inference",
            "http://example.com/inference",
        ] {
            XCTAssertTrue(
                AppSettings.isInsecureRemoteEndpoint(adresse),
                "\(adresse) überträgt die Aufnahme im Klartext"
            )
        }
    }

    func testHttpsIstNieUnsicher() {
        XCTAssertFalse(AppSettings.isInsecureRemoteEndpoint("https://example.com/inference"))
        XCTAssertFalse(AppSettings.isInsecureRemoteEndpoint("HTTPS://Example.com/inference"))
    }

    func testGrossschreibungUndLeerzeichenAendernNichts() {
        XCTAssertTrue(AppSettings.isInsecureRemoteEndpoint("  HTTP://192.168.1.50/inference  "))
        XCTAssertFalse(AppSettings.isInsecureRemoteEndpoint("  http://LOCALHOST:8642/x  "))
    }

    func testUnvollstaendigeEingabeMeldetKeinenFehlalarm() {
        // Während des Tippens steht hier ständig Unfertiges - dann keine Warnung.
        for eingabe in ["", "http://", "kein url", "192.168.1.50"] {
            XCTAssertFalse(
                AppSettings.isInsecureRemoteEndpoint(eingabe),
                "Fehlalarm bei \"\(eingabe)\""
            )
        }
    }

    // MARK: - Timer im .common-Modus

    /// `Timer.scheduledTimer` hängt nur im `.default`-Modus und steht still,
    /// sobald ein Menü offen ist oder gescrollt wird. Genau dann sollen der
    /// Fn-Wächter und das Aufnahme-Zeitlimit aber weiterlaufen.
    /// Der eigentliche Fehler war nicht der Timer selbst, sondern die falsche
    /// Fabrikmethode an fünf Stellen. Genau das prüft dieser Test: In `Sources`
    /// darf `Timer.scheduledTimer` nicht mehr vorkommen, sonst steht das
    /// Sicherheitsnetz wieder still, sobald ein Menü offen ist.
    func testKeinScheduledTimerMehrImQuelltext() throws {
        let quellen = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Orbly")
        let dateien = try FileManager.default
            .contentsOfDirectory(at: quellen, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(dateien.isEmpty, "Quelldateien nicht gefunden unter \(quellen.path)")

        for datei in dateien {
            let inhalt = try String(contentsOf: datei, encoding: .utf8)
            for (nr, zeile) in inhalt.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                guard !zeile.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
                XCTAssertFalse(
                    zeile.contains("Timer.scheduledTimer"),
                    "\(datei.lastPathComponent):\(nr + 1) nutzt Timer.scheduledTimer statt Timer.scheduledCommon"
                )
            }
        }
    }

    func testScheduledCommonUebernimmtToleranz() {
        let timer = Timer.scheduledCommon(every: 30, repeats: true, tolerance: 10) { _ in }
        defer { timer.invalidate() }
        XCTAssertEqual(timer.tolerance, 10, accuracy: 0.001)
        XCTAssertTrue(timer.isValid)
    }
}
