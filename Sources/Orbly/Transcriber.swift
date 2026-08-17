import Foundation

/// Sends a WAV file to a whisper.cpp `/inference` endpoint or an
/// OpenAI-compatible `/v1/audio/transcriptions` endpoint and returns the text.
final class Transcriber {
    struct TranscriptionError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Laufender Upload (damit Esc ihn wirklich abbrechen kann) und die Nummer
    /// des Diktats, zu dem er gehört.
    ///
    /// Beides liegt hinter einer Sperre: Der erste Versuch wird vom Hauptthread
    /// gestartet, ein Wiederholungsversuch aber von einer Hintergrund-Queue, und
    /// `cancelCurrent()` kommt wieder vom Hauptthread. Ohne Sperre schrieben zwei
    /// Threads gleichzeitig auf dieselbe Referenz, was abstürzen kann.
    ///
    /// Ein Zähler statt eines Ja/Nein-Schalters, weil `transcribe()` den Schalter
    /// zurücksetzte: Ein eingeplanter Wiederholungsversuch eines ABGEBROCHENEN
    /// Diktats lief dadurch doch noch los und lud die Aufnahme hoch.
    private let lock = NSLock()
    private var currentTask: URLSessionUploadTask?
    private var generation = 0

    private func beginGeneration() -> Int {
        lock.lock(); defer { lock.unlock() }
        generation += 1
        return generation
    }

    private func isCurrent(_ generation: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation == self.generation
    }

    /// Übernimmt die Task nur, wenn sie noch zum aktuellen Diktat gehört.
    /// Liefert false, wenn inzwischen abgebrochen wurde - dann darf sie gar nicht
    /// erst starten.
    private func adoptTask(_ task: URLSessionUploadTask, generation: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard generation == self.generation else { return false }
        currentTask = task
        return true
    }

    /// Bricht eine laufende Transkription ab (Esc während der Verarbeitung).
    func cancelCurrent() {
        lock.lock()
        generation += 1
        let task = currentTask
        currentTask = nil
        lock.unlock()
        task?.cancel()
    }

    func transcribe(wavURL: URL, completion: @escaping (Result<String, Error>) -> Void) {
        let generation = beginGeneration()
        let settings = AppSettings.shared
        guard let url = URL(string: settings.activeEndpoint) else {
            try? FileManager.default.removeItem(at: wavURL)
            completion(.failure(TranscriptionError(message: L10n.t("transcriber.error.invalidURL"))))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Der Server antwortet erst, wenn er fertig ist - das ist also die Zeit,
        // die er zum Transkribieren haben darf. Bei langen Aufnahmen (Obergrenze
        // 10 Minuten) auf langsamer Hardware reichten 120 s nicht.
        request.timeoutInterval = 300
        let boundary = "Orbly-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        appendField("temperature", "0.0")
        appendField("temperature_inc", "0.2")
        appendField("response_format", "json")
        // "auto" MUSS explizit gesendet werden - ohne language-Feld fällt
        // whisper-server auf Englisch zurück statt die Sprache zu erkennen.
        // Nur bei OpenAI-kompatiblen Servern (Modellname gesetzt) wird "auto" weggelassen.
        if settings.language != "auto" {
            appendField("language", settings.language)
        } else if settings.serverModelName.isEmpty {
            appendField("language", "auto")
        }
        if !settings.serverModelName.isEmpty && settings.mode == .server {
            appendField("model", settings.serverModelName)
        }

        guard let audioData = try? Data(contentsOf: wavURL) else {
            try? FileManager.default.removeItem(at: wavURL)
            completion(.failure(TranscriptionError(message: L10n.t("transcriber.error.fileUnreadable"))))
            return
        }
        // Audio steckt jetzt komplett im Request-Body - Tempdatei wird nicht mehr gebraucht.
        try? FileManager.default.removeItem(at: wavURL)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        // Der lokale whisper-server braucht nach dem Start ein paar Sekunden zum
        // Modell-Laden und nimmt so lange keine Verbindungen an -> kurz wiederholen.
        let retries = settings.mode == .local ? 10 : 0
        send(request, body: body, retriesLeft: retries, generation: generation, completion: completion)
    }

    private func send(
        _ request: URLRequest, body: Data, retriesLeft: Int, generation: Int,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let task = URLSession.shared.uploadTask(with: request, from: body) { [weak self] data, response, error in
            if let error {
                let ns = error as NSError
                // Vom Nutzer abgebrochen: keine Fehlermeldung, kein Retry.
                if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return }
                let serverNotUpYet = ns.domain == NSURLErrorDomain
                    && (ns.code == NSURLErrorCannotConnectToHost || ns.code == NSURLErrorNetworkConnectionLost)
                if serverNotUpYet && retriesLeft > 0 {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        guard let self, self.isCurrent(generation) else { return }
                        self.send(
                            request, body: body, retriesLeft: retriesLeft - 1,
                            generation: generation, completion: completion
                        )
                    }
                    return
                }
                DispatchQueue.main.async {
                    completion(.failure(TranscriptionError(message: L10n.t("transcriber.error.unreachable", error.localizedDescription))))
                }
                return
            }
            guard let http = response as? HTTPURLResponse, let data else {
                DispatchQueue.main.async {
                    completion(.failure(TranscriptionError(message: L10n.t("transcriber.error.noResponse"))))
                }
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                let bodyText = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
                DispatchQueue.main.async {
                    completion(.failure(TranscriptionError(message: L10n.t("transcriber.error.serverError", http.statusCode, String(bodyText)))))
                }
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rawText = json["text"] as? String else {
                DispatchQueue.main.async {
                    completion(.failure(TranscriptionError(message: L10n.t("transcriber.error.unexpectedResponse"))))
                }
                return
            }

            let text = Self.cleanup(rawText)
            DispatchQueue.main.async { completion(.success(text)) }
        }
        // Zwischen dem Bauen der Task und `resume()` kann Esc dazwischenkommen.
        // Ohne diese Prüfung lief der Upload trotzdem los, obwohl der Nutzer
        // abgebrochen hat - im Servermodus wäre die Aufnahme dann doch aus dem
        // Haus gegangen.
        guard adoptTask(task, generation: generation) else {
            task.cancel()
            return
        }
        task.resume()
    }

    /// Removes whisper artifacts like "[BLANK_AUDIO]", "(Musik)" on silence.
    ///
    /// Aussortiert wird pro SEGMENT, nicht über den ganzen Text. Whisper schreibt
    /// so einen Platzhalter immer als eigenes Segment, also als eigene Zeile.
    ///
    /// Beide Nachbarlösungen wären falsch: Das frühere Muster verlangte, dass der
    /// GESAMTE Text genau eine Klammergruppe ist, dann blieb bei Stille über mehr
    /// als eine Segmentgrenze (ca. 30 s) "[BLANK_AUDIO] [BLANK_AUDIO]" im Text
    /// stehen. Einfach jede Klammergruppe zu entfernen wäre auch falsch, dann
    /// verlöre ein Diktat wie "Treffen (verschoben)" seinen Einschub.
    static func cleanup(_ raw: String) -> String {
        let artifactPattern = "^[\\[\\(][^\\]\\)]*[\\]\\)]$"
        let echteSegmente = raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { segment in
                let inhalt = segment.trimmingCharacters(in: .whitespaces)
                return inhalt.range(of: artifactPattern, options: .regularExpression) == nil
            }
        return joinSegments(echteSegmente.joined(separator: "\n"))
    }

    /// whisper-server trennt Audio-Segmente per Zeilenumbruch - beim Diktieren
    /// sind das keine gewollten Absätze, sie werden zu einer Zeile verbunden.
    ///
    /// Ob an die Segmentgrenze ein Leerzeichen gehört, sagt das nächste Segment
    /// selbst: Whispers Tokenizer stellt jedem Wortanfang ein Leerzeichen voran.
    /// Fehlt es, wurde mitten im Wort getrennt (" ... der Ü" + "bergang wenn ...")
    /// - dann darf kein Leerzeichen dazwischen, sonst entsteht "der Ü bergang".
    static func joinSegments(_ raw: String) -> String {
        var text = ""
        for segment in raw.split(separator: "\n") {
            let startsNewWord = segment.first?.isWhitespace ?? false
            let piece = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            if !text.isEmpty && startsNewWord { text += " " }
            text += piece
        }
        // Innerhalb eines Segments können noch Whitespace-Folgen stehen.
        return text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}
