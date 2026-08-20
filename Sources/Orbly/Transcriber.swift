import Foundation

/// Sends a WAV file to a whisper.cpp `/inference` endpoint or an
/// OpenAI-compatible `/v1/audio/transcriptions` endpoint and returns the text.
final class Transcriber {
    struct TranscriptionError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The upload in flight (so Esc can really cancel it) and the number of the
    /// dictation it belongs to.
    ///
    /// Both sit behind a lock: the first attempt is started from the main thread,
    /// a retry from a background queue, and `cancelCurrent()` comes from the main
    /// thread again. Without the lock two threads would write the same reference
    /// at the same time, which can crash.
    ///
    /// A counter instead of a yes/no flag, because `transcribe()` reset the flag:
    /// a scheduled retry of a CANCELLED dictation therefore started after all and
    /// uploaded the recording.
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

    /// Only adopts the task while it still belongs to the current dictation.
    /// Returns false when it was cancelled in the meantime, in which case it must
    /// not start at all.
    private func adoptTask(_ task: URLSessionUploadTask, generation: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard generation == self.generation else { return false }
        currentTask = task
        return true
    }

    /// Cancels a running transcription (Esc while processing).
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
        // The server only answers when it is done, so this is the time it is
        // allowed to take for transcribing. For long recordings (10 minutes at
        // most) on slow hardware, 120 s was not enough.
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
        // "auto" MUST be sent explicitly. Without a language field whisper-server
        // falls back to English instead of detecting the language.
        // Only OpenAI-compatible servers (model name set) omit "auto".
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
        // The audio now sits entirely in the request body, no temp file needed.
        try? FileManager.default.removeItem(at: wavURL)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        // After starting, the local whisper-server needs a few seconds to load the
        // model and accepts no connections until then -> retry briefly.
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
                // Cancelled by the user: no error message, no retry.
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
        // Esc can land between building the task and `resume()`. Without this
        // check the upload started anyway although the user cancelled, and in
        // server mode the recording would have left the machine after all.
        //
        guard adoptTask(task, generation: generation) else {
            task.cancel()
            return
        }
        task.resume()
    }

    /// Removes whisper artifacts like "[BLANK_AUDIO]", "(Musik)" on silence.
    ///
    /// Filtering happens per SEGMENT, not across the whole text. Whisper always
    /// writes such a placeholder as its own segment, so as its own line.
    ///
    /// Both neighbouring solutions would be wrong: the earlier pattern required
    /// the WHOLE text to be exactly one bracket group, which left
    /// "[BLANK_AUDIO] [BLANK_AUDIO]" in the text when the silence spanned more
    /// than one segment boundary (about 30 s). Simply removing every bracket
    /// group would be wrong too, a dictation like "meeting (moved)" would lose it.
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

    /// whisper-server separates audio segments with a line break. While dictating
    /// those are not intended paragraphs, so they are joined into one line.
    ///
    /// Whether a space belongs at the segment boundary is told by the next segment
    /// itself: whisper's tokenizer puts a space in front of every word start. If
    /// it is missing, the split happened in the middle of a word (" ... the tra" +
    /// "nsition when ..."), and then no space may go between them.
    static func joinSegments(_ raw: String) -> String {
        var text = ""
        for segment in raw.split(separator: "\n") {
            let startsNewWord = segment.first?.isWhitespace ?? false
            let piece = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            if !text.isEmpty && startsNewWord { text += " " }
            text += piece
        }
        // Inside a segment there can still be runs of whitespace.
        return text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}
