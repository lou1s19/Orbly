import Foundation

/// Sends a WAV file to a whisper.cpp `/inference` endpoint or an
/// OpenAI-compatible `/v1/audio/transcriptions` endpoint and returns the text.
final class Transcriber {
    struct TranscriptionError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Laufender Upload, damit Esc ihn wirklich abbrechen kann.
    private var currentTask: URLSessionUploadTask?
    /// Verhindert, dass ein eingeplanter Wiederholungsversuch nach dem Abbruch
    /// noch losläuft.
    private var cancelled = false

    /// Bricht eine laufende Transkription ab (Esc während der Verarbeitung).
    func cancelCurrent() {
        cancelled = true
        currentTask?.cancel()
        currentTask = nil
    }

    func transcribe(wavURL: URL, completion: @escaping (Result<String, Error>) -> Void) {
        cancelled = false
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
        send(request, body: body, retriesLeft: retries, completion: completion)
    }

    private func send(
        _ request: URLRequest, body: Data, retriesLeft: Int,
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
                        guard let self, !self.cancelled else { return }
                        self.send(request, body: body, retriesLeft: retriesLeft - 1, completion: completion)
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
        currentTask = task
        task.resume()
    }

    /// Removes whisper artifacts like "[BLANK_AUDIO]", "(Musik)" on silence.
    private static func cleanup(_ raw: String) -> String {
        var text = joinSegments(raw)
        let artifactPattern = "^[\\[\\(][^\\]\\)]*[\\]\\)]$"
        if text.range(of: artifactPattern, options: .regularExpression) != nil {
            text = ""
        }
        return text
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
