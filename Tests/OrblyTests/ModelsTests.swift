import XCTest
@testable import Orbly

final class ModelsTests: XCTestCase {

    // MARK: Checksums

    func testSha256MatchesShasum() throws {
        // Reference value produced independently with: printf 'orbly' | shasum -a 256
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("orbly-sha-test-\(UUID().uuidString)")
        try Data("orbly".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        XCTAssertEqual(
            ModelManager.sha256Hex(of: tmp),
            "bb25f6d1534ff74bf581f4de2144b6228577b6dad6e92bf2c78e0bacdd360dd7"
        )
    }

    func testSha256IsStableAndTellsContentsApart() throws {
        let dir = FileManager.default.temporaryDirectory
        let a = dir.appendingPathComponent("orbly-a-\(UUID().uuidString)")
        let b = dir.appendingPathComponent("orbly-b-\(UUID().uuidString)")
        // Larger than the 4 MB block size, so block-wise reading is covered too.
        try Data(repeating: 0x41, count: 5 * 1024 * 1024).write(to: a)
        var other = Data(repeating: 0x41, count: 5 * 1024 * 1024)
        other[other.count - 1] = 0x42
        try other.write(to: b)
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }

        let hashA = try XCTUnwrap(ModelManager.sha256Hex(of: a))
        XCTAssertEqual(hashA, ModelManager.sha256Hex(of: a), "same file, same hash")
        XCTAssertNotEqual(
            hashA, ModelManager.sha256Hex(of: b),
            "a single changed byte at the end has to show up"
        )
    }

    func testSha256OfAMissingFileIsNil() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)")
        XCTAssertNil(ModelManager.sha256Hex(of: missing))
    }

    // MARK: Model catalog

    func testEveryModelHasAPlausibleChecksum() {
        for model in ModelManager.all {
            XCTAssertEqual(model.sha256.count, 64, "\(model.id): the SHA-256 is not 64 characters")
            XCTAssertTrue(
                model.sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase },
                "\(model.id): the SHA-256 has to be lowercase hexadecimal"
            )
        }
    }

    /// `resolve/main` would be a moving reference: the content behind the URL could
    /// change without the checksum still matching.
    func testDownloadURLsPointAtAPinnedCommit() {
        for model in ModelManager.all {
            let url = model.url.absoluteString
            XCTAssertFalse(url.contains("/resolve/main/"), "\(model.id) points at main")
            XCTAssertTrue(url.hasPrefix("https://"), "\(model.id) does not download over https")
            XCTAssertEqual(model.revision.count, 40, "\(model.id): a commit SHA is expected")
            XCTAssertTrue(
                model.revision.allSatisfy { $0.isHexDigit },
                "\(model.id): the revision is not a commit hash"
            )
        }
    }

    func testNoDuplicateModelIDsOrFileNames() {
        let ids = ModelManager.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate model ID")
        let files = ModelManager.all.map(\.fileName)
        XCTAssertEqual(Set(files).count, files.count, "two models write into the same file")
    }

    func testDifferentModelsHaveDifferentChecksums() {
        let hashes = ModelManager.all.map(\.sha256)
        XCTAssertEqual(
            Set(hashes).count, hashes.count,
            "two models with the same checksum suggests a copy and paste mistake"
        )
    }

    func testEveryQualityLabelExistsInAllLanguages() throws {
        for model in ModelManager.all {
            for lang in ["en", "de", "es", "fr", "ru"] {
                XCTAssertNotNil(
                    L10n.tables[lang]?[model.qualityKey],
                    "\(model.qualityKey) is missing in \(lang)"
                )
            }
        }
    }

    /// The writing rule applies to model names that appear in the UI as well.
    func testModelNamesWithoutDashes() {
        for model in ModelManager.all {
            XCTAssertFalse(model.displayName.contains("—"), "\(model.id): em dash")
            XCTAssertFalse(model.displayName.contains("–"), "\(model.id): en dash")
        }
    }

    // MARK: - Display name with language prefix

    /// The language name used to be hardwired to German or English in the model
    /// name, so a French user read "Deutsch:". Now it comes from `language` and
    /// goes through L10n.
    func testLanguageSpecificModelsShowATranslatedPrefix() {
        for model in ModelManager.languageSpecific {
            guard let language = model.language else {
                XCTFail("\(model.id): language specific model without a language")
                continue
            }
            let prefix = L10n.t("model.language.\(language)")
            XCTAssertNotEqual(prefix, "model.language.\(language)", "the key is missing in L10n")
            XCTAssertTrue(
                model.displayName.hasPrefix("\(prefix): "),
                "\(model.id): \(model.displayName) does not start with \(prefix)"
            )
            XCTAssertFalse(model.baseName.contains(":"), "\(model.id): the prefix is still in the name")
        }
    }

    func testMultilingualModelsHaveNoPrefix() {
        for model in ModelManager.multilingual {
            XCTAssertNil(model.language, "\(model.id) should be multilingual")
            XCTAssertEqual(model.displayName, model.baseName)
        }
    }
}
