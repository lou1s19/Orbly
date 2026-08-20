import XCTest
@testable import Orbly

/// Exactly this class of bug showed up on 2026-08-03: one key was never
/// translated into German ("Listening …"). From now on the test catches it,
/// not the user.
final class L10nTests: XCTestCase {

    private let languages = ["en", "de", "es", "fr", "ru"]

    private func table(_ lang: String) throws -> [String: String] {
        try XCTUnwrap(L10n.tables[lang], "the language table \(lang) is missing entirely")
    }

    func testAllFiveLanguagesExist() {
        XCTAssertEqual(Set(L10n.tables.keys), Set(languages))
    }

    func testEveryLanguageHasTheSameKeys() throws {
        let reference = Set(try table("en").keys)
        for lang in languages where lang != "en" {
            let keys = Set(try table(lang).keys)
            XCTAssertTrue(
                reference.subtracting(keys).isEmpty,
                "missing in \(lang): \(reference.subtracting(keys).sorted())"
            )
            XCTAssertTrue(
                keys.subtracting(reference).isEmpty,
                "\(lang) has keys that do not exist in English: \(keys.subtracting(reference).sorted())"
            )
        }
    }

    /// A differing placeholder formats wrongly at runtime, or crashes.
    func testPlaceholdersMatch() throws {
        let en = try table("en")
        for lang in languages where lang != "en" {
            let table = try self.table(lang)
            for (key, english) in en {
                guard let translated = table[key] else { continue }
                XCTAssertEqual(
                    Self.placeholders(english), Self.placeholders(translated),
                    "placeholders differ at \(lang) / \(key)"
                )
            }
        }
    }

    /// No value may be empty. An empty string looks like a bug in the UI.
    func testNoEmptyValues() throws {
        for lang in languages {
            for (key, value) in try table(lang) {
                XCTAssertFalse(
                    value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "empty text at \(lang) / \(key)"
                )
            }
        }
    }

    /// Writing rule of the project: no en or em dashes as punctuation. Hyphens in
    /// compound words are allowed, so only – and — are checked.
    func testNoDashes() throws {
        for lang in languages {
            for (key, value) in try table(lang) {
                XCTAssertFalse(
                    value.contains("—"),
                    "em dash at \(lang) / \(key): \(value)"
                )
                XCTAssertFalse(
                    value.contains("–"),
                    "en dash at \(lang) / \(key): \(value)"
                )
            }
        }
    }

    /// The same rule for the rest of the source, not just L10n.swift.
    ///
    /// Before this only the table was checked, and two placeholders for the RAM
    /// value (AppDelegate, Dashboard) ended up with an en dash in the menu and in
    /// the sidebar.
    func testNoDashesInTheRestOfTheSource() throws {
        // History.swift reads the old Verlauf.md format, whose separator IS an en
        // dash. That is a parser, not new output.
        let exceptions = ["History.swift"]
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OrblyTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // project root
            .appendingPathComponent("Sources/Orbly")

        let files = try FileManager.default
            .contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .filter { !exceptions.contains($0.lastPathComponent) }
        XCTAssertFalse(files.isEmpty, "no source files found under \(sources.path)")

        for file in files {
            let content = try String(contentsOf: file, encoding: .utf8)
            for (no, line) in content.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                // Comments explain things, they do not appear in the interface.
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//") else { continue }
                XCTAssertFalse(
                    line.contains("—") || line.contains("–"),
                    "dash in \(file.lastPathComponent):\(no + 1): \(trimmed)"
                )
            }
        }
    }

    /// When a translation falls back to English, the fallback kicked in and the
    /// user sees English. That may only happen for proper nouns.
    func testNoUntranslatedSentences() throws {
        // These keys may be identical to the English ones: loan words and
        // technical terms that are spelled the same in that language, plus
        // format strings with unit abbreviations. Checked on 2026-08-03, one
        // by one. Whoever adds something here has to actually look it up and
        // make sure it is not a missing translation.
        // Deliberately per language AND key: if the exception hung off the key
        // alone, a genuine missing translation in another language would slip
        // through with it.
        let knownLoanWords: Set<String> = [
            "de/settings.card.overlay", "es/settings.card.overlay", "fr/settings.card.overlay",
            "de/menu.ram", "es/menu.ram",
            "de/menu.ram.withServer",
            "de/mode.server",
            "de/settings.media.pause", "fr/settings.media.pause",
            "de/settings.version", "fr/settings.version",
            "es/mode.local", "fr/mode.local",
            "es/settings.card.general",
            "es/settings.overlayStyle.orbColor",   // "color" is spelled the same in Spanish
            "es/stats.duration.hourMin", "fr/stats.duration.hourMin",
            "fr/settings.card.transcription",
            "fr/onboarding.permissions.mic",
        ]
        let en = try table("en")
        for lang in ["de", "es", "fr"] {
            let table = try self.table(lang)
            for (key, english) in en {
                guard !knownLoanWords.contains("\(lang)/\(key)") else { continue }
                guard let translated = table[key], translated == english else { continue }
                // Do not judge very short values (abbreviations, numbers, symbols).
                let textOnly = english
                    .replacingOccurrences(of: "%@", with: "")
                    .replacingOccurrences(of: "%d", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard textOnly.count > 3 else { continue }
                XCTFail("\(lang) / \(key) is identical to English: \"\(english)\"")
            }
        }
    }

    /// Order and number of the placeholders of a string.
    private static func placeholders(_ text: String) -> [String] {
        var found: [String] = []
        var rest = Substring(text)
        while let idx = rest.firstIndex(of: "%") {
            let after = rest.index(after: idx)
            guard after < rest.endIndex else { break }
            // %@, %d, %lld, %.1f ... read up to the type letter.
            var spec = "%"
            var cursor = after
            while cursor < rest.endIndex {
                let ch = rest[cursor]
                spec.append(ch)
                cursor = rest.index(after: cursor)
                if ch.isLetter || ch == "@" { break }
            }
            found.append(spec)
            rest = rest[cursor...]
        }
        return found
    }
}
