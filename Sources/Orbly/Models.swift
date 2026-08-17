import CryptoKit
import Foundation

/// Kuratierte whisper.cpp-Modelle (GGML-Dateien von Hugging Face).
///
/// Angeboten werden ausschließlich quantisierte Dateien (q5/q8): unter 1 % mehr
/// Wortfehler als die f16-Originale, dafür 40-60 % weniger RAM. Die alten
/// unquantisierten Modelle bleiben als `legacy` bestehen und werden angezeigt,
/// solange sie installiert sind - sonst hätten Bestandsinstallationen plötzlich
/// ein aktives Modell, das in der Liste gar nicht mehr auftaucht.
struct WhisperModel: Identifiable {
    let id: String
    /// Ohne Sprach-Präfix. Das kommt aus `language` und wird übersetzt, siehe
    /// `displayName`.
    let baseName: String
    let fileName: String
    let sizeMB: Int
    /// L10n-Key für die Qualitäts-Kurzbeschreibung.
    let qualityKey: String
    /// Hugging-Face-Repo der Datei - Sprachpakete liegen außerhalb von ggerganov.
    let repo: String
    /// Fester Commit des Repos. `resolve/main` wäre eine bewegliche Referenz:
    /// Der Inhalt hinter der URL könnte sich jederzeit ändern, und die Datei
    /// wird anschließend von whisper.cpp im eigenen Prozess geparst.
    let revision: String
    /// Erwartete SHA-256 der Datei. Ohne sie wäre die einzige Prüfung die
    /// 4-Byte-GGML-Kennung, und die erkennt nur HTML-Fehlerseiten.
    let sha256: String
    /// ISO-Code, wenn das Modell auf EINE Sprache spezialisiert ist (Fine-Tune
    /// oder `.en`-Variante). nil = mehrsprachig (99 Sprachen).
    let language: String?
    /// Nicht mehr aktiv angeboten - nur sichtbar, solange installiert.
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

    /// Stand 2026-08-03 geprüft. Beim Aktualisieren die SHA-256 der betroffenen
    /// Dateien mit erneuern, sonst schlägt der Download fehl (das ist Absicht).
    static let whisperCppRevision = "5359861c739e955e79d9a303bcbc70fb988958b1"

    /// „Deutsch: Large v3 Turbo". Der Sprachname wurde vorher hart auf Deutsch
    /// bzw. Englisch geschrieben, ein französischer Nutzer las also „Deutsch:".
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

/// Lädt, verwaltet und aktiviert Whisper-Modelle für den lokalen Modus.
final class ModelManager: NSObject, ObservableObject {
    static let shared = ModelManager()

    /// Mehrsprachige Modelle (99 Sprachen), aufsteigend nach RAM-Bedarf.
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

    /// Auf eine Sprache spezialisierte Modelle. Sie schlagen die mehrsprachigen
    /// Modelle bei ihrer Sprache deutlich, können aber KEINE andere.
    /// Bewusst nur dort, wo es sich wirklich lohnt: Für Spanisch und Russisch
    /// gibt es (Stand Aug 2026) keine brauchbaren GGML-Fine-Tunes - die
    /// vorhandenen sind large-v2-basiert (3 GB) und damit RAM-technisch sinnlos.
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

    /// Frühere, unquantisierte Modelle. Nur sichtbar, solange installiert -
    /// damit ein bestehendes Setup weiter auswählbar und löschbar bleibt.
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

    /// Download-Fortschritt 0…1 je Modell-ID.
    @Published var progress: [String: Double] = [:]
    /// Modelle, deren letzter Download fehlgeschlagen ist.
    @Published var failed: Set<String> = []

    /// taskIdentifier -> Modell-ID.
    ///
    /// Hinter einer Sperre, weil `delegateQueue: nil` heißt: URLSession ruft die
    /// Delegate-Methoden auf einer eigenen Hintergrund-Queue auf. Start und
    /// Abbruch eines Downloads kommen dagegen vom Hauptthread. Ein Swift-Dictionary
    /// verträgt das nicht - beim Vergrößern wird der Puffer neu angelegt, und der
    /// lesende Thread greift dann ins Freigegebene (Absturz).
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

    // MARK: - Empfehlung & Sichtbarkeit

    /// Sprache, für die empfohlen wird: die eingestellte Diktatsprache, bei
    /// „auto" die aufgelöste App-/Systemsprache.
    private static var targetLanguage: String {
        let dictation = AppSettings.shared.language
        return dictation == "auto" ? L10n.lang : dictation
    }

    /// Das Modell, das zu Sprache und Arbeitsspeicher dieses Macs passt.
    /// Auf kleinen Macs hat Sparsamkeit Vorrang, sonst gewinnt Genauigkeit;
    /// für Deutsch gibt es das Fine-Tune bei identischer Größe obendrauf.
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

    /// Mehrsprachige Modelle + installierte Altmodelle.
    var visibleGeneralModels: [WhisperModel] {
        Self.multilingual + Self.legacyModels.filter { isInstalled($0) }
    }

    /// Sprachpakete: das der eigenen Sprache zuerst, fremde Sprachen darunter -
    /// verstecken wäre falsch, jemand diktiert auch mal in einer zweiten Sprache.
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

    /// Aktiviert ein installiertes Modell - der lokale Server startet damit neu.
    func select(_ model: WhisperModel) {
        guard isInstalled(model) else { return }
        AppSettings.shared.modelPath = model.localPath
        AppSettings.shared.notifyChanged()
        // Der Haken in der Liste hängt an isSelected(), das AppSettings liest -
        // ohne diese Zeile blieb er beim alten Modell stehen, bis die Zeile aus
        // einem anderen Grund neu gezeichnet wurde (z. B. Hover).
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

    /// Löscht eine heruntergeladene Modelldatei (nicht das aktive Modell).
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

    /// SHA-256 in Blöcken, damit auch ein 1,6-GB-Modell nicht komplett in den
    /// Speicher muss.
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

        // Ein HTTP-Fehler landet sonst als "Modell" auf der Platte: URLSession
        // lädt auch eine 404-Seite brav herunter, und whisper-server scheitert
        // später mit einer nichtssagenden Meldung. Lieber hier abbrechen.
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            NSLog("Orbly: Modell-Download \(model.id) fehlgeschlagen (HTTP \(http.statusCode))")
            DispatchQueue.main.async { self.failed.insert(id) }
            return
        }
        // GGML-Dateien beginnen mit der Magic 0x67676D6C. Sie steht little-endian
        // in der Datei, die Bytes lesen sich also als "lmgg" - NICHT "ggml"
        // (geprüft an den echten Modelldateien). Schützt zusätzlich vor
        // HTML-Seiten, die mit Status 200 ausgeliefert werden.
        let ggmlMagic = Data([0x6C, 0x6D, 0x67, 0x67])
        let isGGML: Bool = {
            guard let handle = try? FileHandle(forReadingFrom: location) else { return false }
            defer { try? handle.close() }
            return (try? handle.read(upToCount: 4)) == ggmlMagic
        }()
        guard isGGML else {
            NSLog("Orbly: Modell-Download \(model.id) ist keine GGML-Datei - verworfen")
            DispatchQueue.main.async { self.failed.insert(id) }
            return
        }
        // Echte Integritätsprüfung: Die GGML-Kennung oben erkennt nur grob
        // falsche Dateien. Diese Datei wird anschließend von whisper.cpp im
        // eigenen Prozess geparst, deshalb muss sie Byte für Byte die sein,
        // die erwartet wird.
        guard let digest = Self.sha256Hex(of: location) else {
            NSLog("Orbly: Modell \(model.id) nicht lesbar für die Prüfsumme - verworfen")
            DispatchQueue.main.async { self.failed.insert(id) }
            return
        }
        guard digest == model.sha256 else {
            NSLog("""
                Orbly: Prüfsumme von \(model.id) stimmt nicht - verworfen.
                erwartet: \(model.sha256)
                erhalten: \(digest)
                """)
            DispatchQueue.main.async { self.failed.insert(id) }
            return
        }

        // location ist nur bis zum Ende dieses Aufrufs gültig -> synchron verschieben.
        let dest = URL(fileURLWithPath: model.localPath)
        do {
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            NSLog("Orbly: Modell-Download verschieben fehlgeschlagen: \(error)")
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
                NSLog("Orbly: Modell-Download fehlgeschlagen: \(error)")
                self.failed.insert(id)
            }
            self.objectWillChange.send()
        }
    }
}
