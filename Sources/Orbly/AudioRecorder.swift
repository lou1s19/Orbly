import AVFoundation
import Foundation

/// Records the default microphone, converts to 16 kHz mono Int16 and
/// reports live RMS levels for the waveform overlay.
final class AudioRecorder {
    var onLevel: ((Float) -> Void)?

    /// Result of `stop()`. "Too short" and "failed" have to be distinguishable:
    /// too short is discarded silently, an error has to be shown to the user,
    /// otherwise their dictation disappears without a word.
    enum StopResult {
        case file(URL)
        case tooShort
        case failed
    }

    private let engine = AVAudioEngine()
    /// The converter together with the input format it was built for. Both have to
    /// be swapped together: `removeTap` does NOT wait for a running tap callback,
    /// so a buffer in the old format could otherwise reach the converter of the
    /// new device (Apple throws an exception there that cannot be caught).
    private var _converter: (converter: AVAudioConverter, inputFormat: AVAudioFormat)?
    /// `os_unfair_lock` instead of `NSLock`: the tap callback reads this, and
    /// os_unfair_lock supports priority donation, so a briefly held main thread
    /// lock does not cost an audio dropout.
    private var converterLock = os_unfair_lock_s()

    private func setConverter(_ value: (converter: AVAudioConverter, inputFormat: AVAudioFormat)?) {
        os_unfair_lock_lock(&converterLock)
        _converter = value
        os_unfair_lock_unlock(&converterLock)
    }

    /// Only returns the converter when it matches this buffer format.
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
    /// Length of the last finished recording (from the sample count, for statistics).
    private(set) var lastDurationSeconds: Double = 0
    /// How long the last `start()` took. After a longer pause the audio hardware
    /// is asleep: waking it up blocks noticeably here, and exactly that time is
    /// missing from the front of the recording. The AppDelegate uses it to detect
    /// a "wake-up press" and asks the user to press again.
    private(set) var lastStartWarmupSeconds: TimeInterval = 0
    /// Device change in the middle of a recording that the engine could not
    /// recover from (AirPods connecting, for example).
    private var engineBroken = false

    init() {
        // When the input device changes (AirPods, dock, USB microphone), macOS
        // stops the engine and the tap delivers nothing any more. Without a
        // reaction the recording seems to continue and the user gets nothing.
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    /// Remove recordings of earlier sessions from the temp directory. If the app
    /// dies mid-dictation, raw speech would otherwise stay behind.
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
        // Measuring starts here: `inputNode`, `prepare()` and `start()` together
        // wake the audio hardware, which can take more than a second after a long
        // pause.
        let warmupStart = Date()
        lastStartWarmupSeconds = 0

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(domain: "Orbly", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No microphone found."
            ])
        }
        guard let conv = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw NSError(domain: "Orbly", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Audio format not usable."
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
            // The tap has to come off again, otherwise the next installTap throws an
            // Objective-C exception ("tap already installed") and crashes the app.
            input.removeTap(onBus: 0)
            setConverter(nil)
            throw error
        }
        lastStartWarmupSeconds = Date().timeIntervalSince(warmupStart)
        if lastStartWarmupSeconds >= WakeUpPress.warmupThreshold {
            NSLog("Orbly: the audio hardware was asleep, the start took \(String(format: "%.2f", lastStartWarmupSeconds)) s")
        }
        isRecording = true
    }

    /// True when the last recording was cut short by a device change (AirPods
    /// connecting mid-dictation). Only the part before it is in there.
    private(set) var lastRecordingWasTruncated = false

    /// Stops the recording and returns the WAV file.
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
        // Empty the buffer right away: otherwise the app held the complete audio
        // data of the last dictation (1.9 MB per minute) until the next Fn press,
        // so potentially for hours in a menu bar app.
        samplesQueue.sync {
            recorded = samples
            samples.removeAll(keepingCapacity: false)
        }
        lastDurationSeconds = Double(recorded.count) / targetFormat.sampleRate
        // Require at least 0.3 s of audio
        guard recorded.count > 4800 else {
            // Device change without usable audio: the user spoke, nothing was
            // recorded, and they have to be told.
            return broken ? .failed : .tooShort
        }
        // Only the part BEFORE the device change is transcribed. The user has to
        // be told, otherwise half the recording is missing without any hint.
        lastRecordingWasTruncated = broken
        if broken {
            NSLog("Orbly: input device changed during the recording, transcribing the part before it")
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("orbly-\(UUID().uuidString).wav")
        do {
            try Self.writeWav(samples: recorded, to: url)
            return .file(url)
        } catch {
            NSLog("Orbly: WAV write failed: \(error)")
            // Raw speech must not stay behind, not even as a fragment.
            try? FileManager.default.removeItem(at: url)
            return .failed
        }
    }

    /// The input device changed: point the tap and the converter at the new
    /// format and start the engine again. The samples so far are kept, so the
    /// beginning of the dictation is not lost.
    private func handleConfigurationChange() {
        guard isRecording else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let conv = AVAudioConverter(from: format, to: targetFormat) else {
            engineBroken = true
            NSLog("Orbly: input device changed, no usable format left")
            return
        }
        setConverter((conv, format))
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.process(buffer: buffer)
        }
        engine.prepare()
        do {
            try engine.start()
            NSLog("Orbly: recording resumed after the device change")
        } catch {
            input.removeTap(onBus: 0)
            setConverter(nil)
            engineBroken = true
            NSLog("Orbly: cannot resume the recording after the device change: \(error)")
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
        // If the converter does not match the buffer format, the buffer is still
        // from the old device. Discard it instead of risking a format conflict.
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
        // Atomic: if writing fails (disk full), half a speech recording would
        // otherwise stay in the temp folder with nobody left to delete it.
        try data.write(to: url, options: .atomic)
    }
}
