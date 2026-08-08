import AVFoundation
import Foundation

/// Records the default microphone, converts to 16 kHz mono Int16 and
/// reports live RMS levels for the waveform overlay.
final class AudioRecorder {
    var onLevel: ((Float) -> Void)?

    /// Ergebnis von `stop()`. „Zu kurz" und „fehlgeschlagen" müssen sich
    /// unterscheiden lassen: zu kurz wird still verworfen, ein Fehler muss
    /// dem Nutzer gezeigt werden, sonst verschwindet sein Diktat kommentarlos.
    enum StopResult {
        case file(URL)
        case tooShort
        case failed
    }

    private let engine = AVAudioEngine()
    /// Converter samt Eingabeformat, für das er gebaut wurde. Beides muss
    /// zusammen ausgetauscht werden: `removeTap` wartet NICHT auf einen laufenden
    /// Tap-Callback, ein Puffer im alten Format könnte sonst in den Converter des
    /// neuen Geräts laufen (Apple wirft dabei eine nicht abfangbare Exception).
    private var _converter: (converter: AVAudioConverter, inputFormat: AVAudioFormat)?
    /// `os_unfair_lock` statt `NSLock`: Der Tap-Callback liest das hier, und
    /// os_unfair_lock kennt Priority Donation - eine kurz unterbrochene
    /// Main-Thread-Sperre kostet so keinen Audio-Aussetzer.
    private var converterLock = os_unfair_lock_s()

    private func setConverter(_ value: (converter: AVAudioConverter, inputFormat: AVAudioFormat)?) {
        os_unfair_lock_lock(&converterLock)
        _converter = value
        os_unfair_lock_unlock(&converterLock)
    }

    /// Liefert den Converter nur, wenn er zu diesem Pufferformat passt.
    private func converter(for format: AVAudioFormat) -> AVAudioConverter? {
        os_unfair_lock_lock(&converterLock)
        let current = _converter
        os_unfair_lock_unlock(&converterLock)
        guard let current, current.inputFormat == format else { return nil }
        return current.converter
    }
    private var samples: [Int16] = []
    private let samplesQueue = DispatchQueue(label: "orbly.samples")
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true
    )!
    private(set) var isRecording = false
    /// Dauer der letzten abgeschlossenen Aufnahme (aus der Sample-Zahl, für die Statistik).
    private(set) var lastDurationSeconds: Double = 0
    /// Wie lange der letzte `start()` gebraucht hat. Nach längerer Pause schläft
    /// die Audio-Hardware: Das Aufwecken blockiert hier spürbar, und genau diese
    /// Zeit fehlt vorne in der Aufnahme. Der AppDelegate erkennt daran einen
    /// "Aufwachdruck" und bittet den Nutzer, noch einmal zu drücken.
    private(set) var lastStartWarmupSeconds: TimeInterval = 0
    /// Gerätewechsel mitten in der Aufnahme, von dem sich die Engine nicht
    /// erholen konnte (z. B. AirPods verbinden sich).
    private var engineBroken = false

    init() {
        // Wechselt das Eingabegerät (AirPods, Dock, USB-Mikrofon), stoppt macOS
        // die Engine und der Tap liefert nichts mehr. Ohne Reaktion läuft die
        // Aufnahme scheinbar weiter und der Nutzer bekommt am Ende nichts.
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    /// Aufnahmen früherer Sitzungen aus dem Temp-Verzeichnis entfernen. Stirbt die
    /// App mitten im Diktat, bleibt sonst rohe Sprachaufnahme liegen.
    static func sweepLeftoverRecordings() {
        let tmp = FileManager.default.temporaryDirectory
        DispatchQueue.global(qos: .utility).async {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: tmp, includingPropertiesForKeys: nil
            ) else { return }
            for file in files where file.lastPathComponent.hasPrefix("orbly-")
                && file.pathExtension == "wav" {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    func requestPermission(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async { completion(ok) }
            }
        default:
            completion(false)
        }
    }

    func start() throws {
        guard !isRecording else { return }
        samplesQueue.sync { samples.removeAll() }
        engineBroken = false
        // Ab hier wird gemessen: `inputNode`, `prepare()` und `start()` wecken
        // zusammen die Audio-Hardware auf, das kann nach langer Pause über eine
        // Sekunde dauern.
        let warmupStart = Date()
        lastStartWarmupSeconds = 0

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(domain: "Orbly", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Kein Mikrofon gefunden."
            ])
        }
        guard let conv = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw NSError(domain: "Orbly", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Audio-Format nicht nutzbar."
            ])
        }
        setConverter((conv, inputFormat))

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer: buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            // Tap muss wieder runter, sonst wirft der nächste installTap eine
            // Objective-C-Exception ("tap already installed") und crasht die App.
            input.removeTap(onBus: 0)
            setConverter(nil)
            throw error
        }
        lastStartWarmupSeconds = Date().timeIntervalSince(warmupStart)
        if lastStartWarmupSeconds >= WakeUpPress.warmupThreshold {
            NSLog("Orbly: Audio-Hardware war eingeschlafen, Start dauerte \(String(format: "%.2f", lastStartWarmupSeconds)) s")
        }
        isRecording = true
    }

    /// Beendet die Aufnahme und liefert die WAV-Datei.
    @discardableResult
    func stop() -> StopResult {
        guard isRecording else { return .tooShort }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        setConverter(nil)
        let broken = engineBroken
        engineBroken = false

        var recorded: [Int16] = []
        samplesQueue.sync { recorded = samples }
        lastDurationSeconds = Double(recorded.count) / targetFormat.sampleRate
        // Require at least 0.3 s of audio
        guard recorded.count > 4800 else {
            // Gerätewechsel ohne brauchbares Audio: der Nutzer hat gesprochen,
            // aufgenommen wurde nichts - das muss er erfahren.
            return broken ? .failed : .tooShort
        }
        if broken {
            NSLog("Orbly: Eingabegerät wechselte während der Aufnahme - transkribiere den Teil davor")
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("orbly-\(UUID().uuidString).wav")
        do {
            try Self.writeWav(samples: recorded, to: url)
            return .file(url)
        } catch {
            NSLog("Orbly: WAV write failed: \(error)")
            return .failed
        }
    }

    /// Eingabegerät hat gewechselt: Tap und Converter auf das neue Format
    /// umstellen und die Engine wieder starten. Die bisherigen Samples bleiben,
    /// damit der Anfang des Diktats nicht verloren geht.
    private func handleConfigurationChange() {
        guard isRecording else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let conv = AVAudioConverter(from: format, to: targetFormat) else {
            engineBroken = true
            NSLog("Orbly: Eingabegerät gewechselt, kein nutzbares Format mehr")
            return
        }
        setConverter((conv, format))
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.process(buffer: buffer)
        }
        engine.prepare()
        do {
            try engine.start()
            NSLog("Orbly: Aufnahme nach Gerätewechsel fortgesetzt")
        } catch {
            input.removeTap(onBus: 0)
            setConverter(nil)
            engineBroken = true
            NSLog("Orbly: Aufnahme nach Gerätewechsel nicht fortsetzbar: \(error)")
        }
    }

    func cancel() {
        guard isRecording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        setConverter(nil)
        samplesQueue.sync { samples.removeAll() }
    }

    private func process(buffer: AVAudioPCMBuffer) {
        // Live level for the overlay animation
        if let ch = buffer.floatChannelData?[0] {
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            let rms = n > 0 ? sqrtf(sum / Float(n)) : 0
            let display = min(1.0, rms * 9)
            DispatchQueue.main.async { [weak self] in self?.onLevel?(display) }
        }

        // Convert to 16 kHz mono Int16
        // Passt der Converter nicht zum Pufferformat, stammt der Puffer noch
        // vom alten Gerät - verwerfen statt Formatkonflikt riskieren.
        guard let converter = converter(for: buffer.format) else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var served = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, outStatus in
            if served {
                outStatus.pointee = .noDataNow
                return nil
            }
            served = true
            outStatus.pointee = .haveData
            return buffer
        }
        if error != nil { return }

        if out.frameLength > 0, let data = out.int16ChannelData?[0] {
            let chunk = Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
            samplesQueue.async { [weak self] in self?.samples.append(contentsOf: chunk) }
        }
    }

    // MARK: - WAV writing

    private static func writeWav(samples: [Int16], to url: URL) throws {
        func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

        let sampleRate: UInt32 = 16000
        let channels: UInt16 = 1
        let bits: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bits / 8)
        let blockAlign = channels * bits / 8
        let dataSize = UInt32(samples.count * 2)

        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        data.append(le32(36 + dataSize))
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        data.append(le32(16))
        data.append(le16(1)) // PCM
        data.append(le16(channels))
        data.append(le32(sampleRate))
        data.append(le32(byteRate))
        data.append(le16(blockAlign))
        data.append(le16(bits))
        data.append("data".data(using: .ascii)!)
        data.append(le32(dataSize))
        samples.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        try data.write(to: url)
    }
}
