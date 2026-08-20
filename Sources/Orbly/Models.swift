import CryptoKit
import Foundation

/// Curated whisper.cpp models (GGML files from Hugging Face).
///
/// Only quantized files are offered (q5/q8): under 1 % more word errors than
/// the f16 originals, for 40 to 60 % less RAM. The old unquantized models stay
/// around as `legacy` and are shown as long as they are installed, otherwise
/// existing installations would suddenly have an active model that no longer
/// appears in the list at all.
struct WhisperModel: Identifiable {
    let id: String
    /// Without a language prefix. That comes from `language` and is translated,
    /// see `displayName`.
    let baseName: String
    let fileName: String
    let sizeMB: Int
    /// L10n key for the short quality description.
    let qualityKey: String
    /// Hugging Face repo of the file. Language packs live outside ggerganov.
    let repo: String
    /// Pinned commit of the repo. `resolve/main` would be a moving reference: the
    /// content behind the URL could change at any time, and the file is then
    /// parsed by whisper.cpp in its own process.
    let revision: String
    /// Expected SHA-256 of the file. Without it the only check would be the 4 byte
    /// GGML magic, which only catches HTML error pages.
    let sha256: String
    /// ISO code when the model is specialized on ONE language (a fine-tune or an
    /// `.en` variant). nil = multilingual (99 languages).
    let language: String?
    /// No longer offered actively, only visible while installed.
    let legacy: Bool

    init(
        id: String, displayName: String, fileName: String,
        revision: String = WhisperModel.whisperCppRevision, sha256: String,
        sizeMB: Int, qualityKey: String, repo: String = "ggerganov/whisper.cpp",
        language: String? = nil, legacy: Bool = false
    ) {
        self.id = id
        self.baseName = displayName
        self.fileName = fileName
        self.sizeMB = sizeMB
        self.qualityKey = qualityKey
        self.repo = repo
        self.revision = revision
        self.sha256 = sha256
        self.language = language
        self.legacy = legacy
    }

    /// Checked as of 2026-08-03. When updating these, renew the SHA-256 of the
    /// affected files as well, otherwise the download fails (which is intended).
    static let whisperCppRevision = "5359861c739e955e79d9a303bcbc70fb988958b1"

    /// "German: Large v3 Turbo". The language name used to be hardwired to German
    /// or English, so a French user read "Deutsch:".
    var displayName: String {
        guard let language else { return baseName }
        return "\(L10n.t("model.language.\(language)")): \(baseName)"
    }

    var url: URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(fileName)")!
    }

    var localPath: String {
        AppSettings.appSupportDir.appendingPathComponent("models/\(fileName)").path
    }
}

/// Downloads, manages and activates Whisper models for local mode.
final class ModelManager: NSObject, ObservableObject {
    static let shared = ModelManager()

    /// Multilingual models (99 languages), ascending by memory footprint.
    static let multilingual: [WhisperModel] = [
        WhisperModel(
            id: "tiny-q5_1", displayName: "Tiny", fileName: "ggml-tiny-q5_1.bin",
            sha256: "818710568da3ca15689e31a743197b520007872ff9576237bda97bd1b469c3d7",
            sizeMB: 32, qualityKey: "model.quality.tiny"
        ),
        WhisperModel(
            id: "base-q5_1", displayName: "Base", fileName: "ggml-base-q5_1.bin",
            sha256: "422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898",
            sizeMB: 60, qualityKey: "model.quality.base"
        ),
        WhisperModel(
            id: "small-q5_1", displayName: "Small", fileName: "ggml-small-q5_1.bin",
            sha256: "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb",
            sizeMB: 190, qualityKey: "model.quality.small"
        ),
        WhisperModel(
            id: "large-v3-turbo-q5_0", displayName: "Large v3 Turbo",
            fileName: "ggml-large-v3-turbo-q5_0.bin",
            sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
            sizeMB: 574, qualityKey: "model.quality.turboq5"
        ),
        WhisperModel(
            id: "large-v3-turbo-q8_0", displayName: "Large v3 Turbo (q8)",
            fileName: "ggml-large-v3-turbo-q8_0.bin",
            sha256: "317eb69c11673c9de1e1f0d459b253999804ec71ac4c23c17ecf5fbe24e259a1",
            sizeMB: 874, qualityKey: "model.quality.turboq8"
        ),
    ]

    /// Models specialized on one language. They clearly beat the multilingual
    /// models on their language, but cannot handle ANY other one.
    /// Deliberately only where it really pays off: for Spanish and Russian there
    /// are no usable GGML fine-tunes (as of Aug 2026). The ones that exist are
    /// based on large-v2 (3 GB) and therefore pointless in terms of RAM.
    static let languageSpecific: [WhisperModel] = [
        WhisperModel(
            id: "large-v3-turbo-german-q5_0", displayName: "Large v3 Turbo",
            fileName: "ggml-large-v3-turbo-german-q5_0.bin",
            revision: "8ca650615c50e0d16a49de2bf707d2791242d829", sha256: "15e92e3db0993c52fffa781513eec9253475331c1be808f8fb409285c9d9d030",
            sizeMB: 574, qualityKey: "model.quality.german",
            repo: "MolyProduction/whisper-large-v3-turbo-german-ggml-q5_0",
            language: "de"
        ),
        WhisperModel(
            id: "small.en-q5_1", displayName: "Small",
            fileName: "ggml-small.en-q5_1.bin",
            sha256: "bfdff4894dcb76bbf647d56263ea2a96645423f1669176f4844a1bf8e478ad30",
            sizeMB: 190, qualityKey: "model.quality.englishSmall", language: "en"
        ),
        WhisperModel(
            id: "base.en-q5_1", displayName: "Base",
            fileName: "ggml-base.en-q5_1.bin",
            sha256: "4baf70dd0d7c4247ba2b81fafd9c01005ac77c2f9ef064e00dcf195d0e2fdd2f",
            sizeMB: 60, qualityKey: "model.quality.englishBase", language: "en"
        ),
    ]

    /// Earlier, unquantized models. Only visible while installed, so an existing
    /// setup stays selectable and deletable.
    static let legacyModels: [WhisperModel] = [
        WhisperModel(
            id: "tiny", displayName: "Tiny (f16)", fileName: "ggml-tiny.bin",
            sha256: "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21",
            sizeMB: 78, qualityKey: "model.quality.tiny", legacy: true
        ),
        WhisperModel(
            id: "base", displayName: "Base (f16)", fileName: "ggml-base.bin",
            sha256: "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe",
            sizeMB: 148, qualityKey: "model.quality.base", legacy: true
        ),
        WhisperModel(
            id: "small", displayName: "Small (f16)", fileName: "ggml-small.bin",
            sha256: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b",
            sizeMB: 488, qualityKey: "model.quality.small", legacy: true
        ),
        WhisperModel(
            id: "large-v3-turbo", displayName: "Large v3 Turbo (f16)",
            fileName: "ggml-large-v3-turbo.bin",
            sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69",
            sizeMB: 1620, qualityKey: "model.quality.turbo", legacy: true
        ),
    ]

    static let all: [WhisperModel] = multilingual + languageSpecific + legacyModels

    /// Download progress 0…1 per model ID.
    @Published var progress: [String: Double] = [:]
    /// Models whose last download failed.
    @Published var failed: Set<String> = []

    /// taskIdentifier -> model ID.
    ///
    /// Behind a lock, because `delegateQueue: nil` means URLSession calls the
    /// delegate methods on a background queue of its own. Starting and cancelling
    /// a download come from the main thread instead. A Swift dictionary does not
    /// tolerate that: when it grows, the buffer is reallocated, and the reading
    /// thread then reaches into freed memory (a crash).
    private let tasksLock = NSLock()
    private var tasksStorage: [Int: String] = [:]

    private func modelID(forTask id: Int) -> String? {
        tasksLock.lock(); defer { tasksLock.unlock() }
        return tasksStorage[id]
    }

    private func setModelID(_ modelID: String?, forTask id: Int) {
        tasksLock.lock(); defer { tasksLock.unlock() }
        tasksStorage[id] = modelID
    }

    private func taskID(forModel modelID: String) -> Int? {
        tasksLock.lock(); defer { tasksLock.unlock() }
        return tasksStorage.first { $0.value == modelID }?.key
    }
    private lazy var session = URLSession(
        configuration: .default, delegate: self, delegateQueue: nil
    )

    func isInstalled(_ model: WhisperModel) -> Bool {
        FileManager.default.fileExists(atPath: model.localPath)
    }

    // MARK: - Recommendation and visibility

    /// The language recommendations are made for: the configured dictation
    /// language, or with "auto" the resolved app/system language.
    private static var targetLanguage: String {
        let dictation = AppSettings.shared.language
        return dictation == "auto" ? L10n.lang : dictation
    }

    /// The model that fits the language and the memory of this Mac. On small Macs
    /// frugality wins, otherwise accuracy does. For German the fine-tune comes on
    /// top at an identical size.
    static var recommendedID: String {
        let lang = targetLanguage
        let gigabytes = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        if gigabytes <= 8 {
            return lang == "en" ? "small.en-q5_1" : "small-q5_1"
        }
        if lang == "de" { return "large-v3-turbo-german-q5_0" }
        return "large-v3-turbo-q5_0"
    }

    func isRecommended(_ model: WhisperModel) -> Bool {
        model.id == Self.recommendedID
    }

    /// Multilingual models plus installed legacy models.
    var visibleGeneralModels: [WhisperModel] {
        Self.multilingual + Self.legacyModels.filter { isInstalled($0) }
    }

    /// Language packs: the one for your own language first, other languages below.
    /// Hiding them would be wrong, people do dictate in a second language.
    var visibleLanguageModels: [WhisperModel] {
        let lang = Self.targetLanguage
        return Self.languageSpecific.sorted { a, b in
            (a.language == lang ? 0 : 1) < (b.language == lang ? 0 : 1)
        }
    }

    func isSelected(_ model: WhisperModel) -> Bool {
        AppSettings.shared.modelPath == model.localPath
    }

    func isDownloading(_ model: WhisperModel) -> Bool {
        progress[model.id] != nil
    }

    /// Activates an installed model, the local server restarts with it.
    func select(_ model: WhisperModel) {
        guard isInstalled(model) else { return }
        AppSettings.shared.modelPath = model.localPath
        AppSettings.shared.notifyChanged()
        // The check mark in the list hangs off isSelected(), which reads
        // AppSettings. Without this line it stayed on the old model until the row
        // was redrawn for another reason (hovering, for example).
        objectWillChange.send()
    }

    func download(_ model: WhisperModel) {
        guard !isDownloading(model), !isInstalled(model) else { return }
        failed.remove(model.id)
        progress[model.id] = 0
        let task = session.downloadTask(with: model.url)
        setModelID(model.id, forTask: task.taskIdentifier)
        task.resume()
    }

    func cancelDownload(_ model: WhisperModel) {
        guard let id = taskID(forModel: model.id) else { return }
        session.getAllTasks { all in
            all.first { $0.taskIdentifier == id }?.cancel()
        }
        setModelID(nil, forTask: id)
        DispatchQueue.main.async { self.progress[model.id] = nil }
    }

    /// Deletes a downloaded model file (not the active model).
    func delete(_ model: WhisperModel) {
        guard !isSelected(model) else { return }
        try? FileManager.default.removeItem(atPath: model.localPath)
        objectWillChange.send()
    }
}

extension ModelManager: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let id = modelID(forTask: downloadTask.taskIdentifier), totalBytesExpectedToWrite > 0 else { return }
        let value = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { self.progress[id] = value }
    }

    /// SHA-256 in blocks, so even a 1.6 GB model does not have to go into memory
    /// completely.
    static func sha256Hex(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let id = modelID(forTask: downloadTask.taskIdentifier),
              let model = Self.all.first(where: { $0.id == id }) else { return }

        // An HTTP error would otherwise land on disk as a "model": URLSession
        // dutifully downloads a 404 page too, and whisper-server later fails with
        // a meaningless message. Better to abort here.
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            NSLog("Orbly: model download \(model.id) fehlgeschlagen (HTTP \(http.statusCode))")
            DispatchQueue.main.async { self.failed.insert(id) }
            return
        }
        // GGML files start with the magic 0x67676D6C. It sits little-endian in the
        // file, so the bytes read as "lmgg" and NOT "ggml" (verified against the
        // real model files). It also guards against HTML pages that are served
        // with status 200.
        let ggmlMagic = Data([0x6C, 0x6D, 0x67, 0x67])
        let isGGML: Bool = {
            guard let handle = try? FileHandle(forReadingFrom: location) else { return false }
            defer { try? handle.close() }
            return (try? handle.read(upToCount: 4)) == ggmlMagic
        }()
        guard isGGML else {
            NSLog("Orbly: model download \(model.id) is not a GGML file, discarded")
            DispatchQueue.main.async { self.failed.insert(id) }
            return
        }
        // A real integrity check: the GGML magic above only catches roughly wrong
        // files. This file is then parsed by whisper.cpp in its own process, so it
        // has to be byte for byte the one that is expected.
        //
        guard let digest = Self.sha256Hex(of: location) else {
            NSLog("Orbly: model \(model.id) not readable for the checksum, discarded")
            DispatchQueue.main.async { self.failed.insert(id) }
            return
        }
        guard digest == model.sha256 else {
            NSLog("""
                Orbly: checksum of \(model.id) does not match, discarded.
                expected: \(model.sha256)
                received: \(digest)
                """)
            DispatchQueue.main.async { self.failed.insert(id) }
            return
        }

        // location is only valid until the end of this call -> move synchronously.
        let dest = URL(fileURLWithPath: model.localPath)
        do {
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            NSLog("Orbly: model download verschieben fehlgeschlagen: \(error)")
            DispatchQueue.main.async { self.failed.insert(id) }
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
    ) {
        guard let id = modelID(forTask: task.taskIdentifier) else { return }
        setModelID(nil, forTask: task.taskIdentifier)
        DispatchQueue.main.async {
            self.progress[id] = nil
            if let error, (error as NSError).code != NSURLErrorCancelled {
                NSLog("Orbly: model download fehlgeschlagen: \(error)")
                self.failed.insert(id)
            }
            self.objectWillChange.send()
        }
    }
}
