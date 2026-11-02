import AVFoundation

@MainActor
final class AudioPlayback {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    private var pendingBuffers = 0
    private var generation = 0
    private var waiter: CheckedContinuation<Void, Error>?

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func enqueue(_ samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else {
            throw VoiceFailure(message: "The audio output buffer could not be created.")
        }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { source in channel.update(from: source.baseAddress!, count: source.count) }
        if !engine.isRunning { try engine.start() }
        let currentGeneration = generation
        pendingBuffers += 1
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, currentGeneration == self.generation else { return }
                self.pendingBuffers -= 1
                if self.pendingBuffers == 0 {
                    self.waiter?.resume()
                    self.waiter = nil
                }
            }
        }
        if !player.isPlaying { player.play() }
    }

    func finish() async throws {
        try Task.checkCancellation()
        if pendingBuffers == 0 { return }
        let currentGeneration = generation
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiter = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                self.stop()
            }
        }
        try Task.checkCancellation()
    }

    func stop() {
        generation += 1
        player.stop()
        engine.stop()
        pendingBuffers = 0
        waiter?.resume(throwing: CancellationError())
        waiter = nil
    }
}
