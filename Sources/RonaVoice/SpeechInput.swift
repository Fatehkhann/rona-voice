@preconcurrency import AVFoundation
import Speech

// This converter is used exclusively by the serial audio tap. AnalyzerInput owns each new output
// buffer, so the recognizer never reads a microphone buffer after the tap has returned.
private final class MicrophoneConverter: @unchecked Sendable {
    let converter: AVAudioConverter
    let format: AVAudioFormat
    let continuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation
    let meter: @Sendable (Float) -> Void

    init(source: AVAudioFormat, target: AVAudioFormat,
         continuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation,
         meter: @escaping @Sendable (Float) -> Void) throws {
        guard let converter = AVAudioConverter(from: source, to: target) else {
            throw VoiceFailure(message: "This microphone’s audio format is not supported.")
        }
        self.converter = converter
        format = target
        self.continuation = continuation
        self.meter = meter
    }

    func receive(_ input: AVAudioPCMBuffer) {
        if let channel = input.floatChannelData?[0], input.frameLength > 0 {
            var sum: Float = 0
            for index in 0..<Int(input.frameLength) { sum += channel[index] * channel[index] }
            meter(min(1, sqrt(sum / Float(input.frameLength)) * 6))
        }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * format.sampleRate / input.format.sampleRate)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true
            state.pointee = .haveData
            return input
        }
        if status == .error {
            continuation.finish(throwing: error ?? VoiceFailure(message: "Microphone audio conversion failed.") as NSError)
        } else if output.frameLength > 0 {
            if case .dropped = continuation.yield(AnalyzerInput(buffer: output)) {
                continuation.finish(throwing: VoiceFailure(message: "The microphone could not keep up. Please try again."))
            }
        }
    }
}

@MainActor
final class SpeechInput {
    private var engine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncThrowingStream<AnalyzerInput, Error>.Continuation?
    private var analysisTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?
    private var generation = UUID()
    private var isFinalizing = false
    private(set) var transcript = ""
    var canInstallAssets: Bool { SpeechTranscriber.isAvailable }

    func availabilityIssue() async -> String? {
        guard SpeechTranscriber.isAvailable else { return "On-device speech recognition is unavailable on this Mac. You can still type." }
        let locales = await SpeechTranscriber.installedLocales
        guard locales.contains(where: { $0.identifier.replacingOccurrences(of: "_", with: "-") == "en-US" }) else {
            return "English speech needs a one-time download before the microphone works offline. You can still type."
        }
        return nil
    }

    // Called only by the explicit Download English button; conversation startup never downloads.
    func installAssets() async throws {
        guard SpeechTranscriber.isAvailable else {
            throw VoiceFailure(message: "On-device speech recognition is unavailable on this Mac.")
        }
        let locale = Locale(identifier: "en-US")
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        _ = try await AssetInventory.reserve(locale: locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        if let issue = await availabilityIssue() { throw VoiceFailure(message: issue) }
    }

    func start(update: @escaping @MainActor (String) -> Void,
               level: @escaping @MainActor (Float) -> Void,
               failure: @escaping @MainActor (Error) -> Void) async throws {
        cancel()
        let identifier = generation
        let authorized = await AVCaptureDevice.requestAccess(for: .audio)
        try Task.checkCancellation()
        guard generation == identifier else { throw CancellationError() }
        guard authorized else {
            throw VoiceFailure(message: "Allow Rona Voice to use your microphone in System Settings → Privacy & Security → Microphone. You can still type below.")
        }
        if let issue = await availabilityIssue() { throw VoiceFailure(message: issue) }
        try Task.checkCancellation()
        guard generation == identifier else { throw CancellationError() }
        let transcriber = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .progressiveTranscription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let engine = AVAudioEngine()
        let source = engine.inputNode.outputFormat(forBus: 0)
        guard source.sampleRate > 0, source.channelCount > 0 else {
            throw VoiceFailure(message: "No microphone is connected. Connect one or type your message.")
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: source) else {
            throw VoiceFailure(message: "The speech recognizer could not select an audio format.")
        }
        try await analyzer.prepareToAnalyze(in: format)
        try Task.checkCancellation()
        guard generation == identifier else { await analyzer.cancelAndFinishNow(); throw CancellationError() }
        let (stream, continuation) = AsyncThrowingStream<AnalyzerInput, Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
        let converter = try MicrophoneConverter(source: source, target: format, continuation: continuation) { [weak self] value in
            Task { @MainActor [weak self] in
                guard self?.generation == identifier else { return }
                level(value)
            }
        }
        transcript = ""
        self.analyzer = analyzer
        self.engine = engine
        input = continuation
        resultTask = Task { [weak self] in
            var committed = ""
            do {
                for try await result in transcriber.results {
                    guard let self, self.generation == identifier, !Task.isCancelled else { return }
                    let text = String(result.text.characters)
                    self.transcript = (committed + text).trimmingCharacters(in: .whitespacesAndNewlines)
                    update(self.transcript)
                    if result.isFinal { committed += text + " " }
                }
            } catch {
                guard self?.generation == identifier, self?.isFinalizing == false, !Task.isCancelled else { return }
                failure(error)
            }
        }
        analysisTask = Task { [weak self] in
            do { try await analyzer.start(inputSequence: stream) }
            catch {
                guard self?.generation == identifier, !Task.isCancelled else { return }
                failure(error)
            }
        }
        // AVAudioEngine invokes this on its real-time queue. Explicit Sendable prevents Swift 6
        // from inheriting MainActor isolation from start() and trapping on the first mic buffer.
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: source) { @Sendable [converter] buffer, _ in
            converter.receive(buffer)
        }
        do { engine.prepare(); try engine.start() }
        catch { cancel(); throw error }
    }

    func finish() async -> String {
        let identifier = generation
        isFinalizing = true
        stopMicrophone()
        input?.finish()
        input = nil
        if let analyzer {
            // Finalization has a bounded grace period; keep the last partial if recognition stalls.
            let watchdog = Task {
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled { await analyzer.cancelAndFinishNow() }
            }
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
            watchdog.cancel()
        }
        await resultTask?.value
        guard generation == identifier else { return "" }
        analyzer = nil
        analysisTask = nil
        resultTask = nil
        return transcript
    }

    func cancel() {
        generation = UUID()
        isFinalizing = false
        stopMicrophone()
        input?.finish()
        input = nil
        analysisTask?.cancel()
        resultTask?.cancel()
        analysisTask = nil
        resultTask = nil
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        analyzer = nil
        transcript = ""
    }

    private func stopMicrophone() {
        guard let engine else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        self.engine = nil
    }
}
