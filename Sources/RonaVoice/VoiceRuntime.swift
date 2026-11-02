import Foundation
import RonaSpeech

struct VoiceFailure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

enum Voice: String, CaseIterable, Identifiable, Sendable {
    case warm = "f_us_warm", bright = "f_us_bright", relaxed = "m_us_relaxed", upbeat = "m_us_upbeat"
    var id: String { rawValue }
    var title: String {
        switch self { case .warm: "Warm"; case .bright: "Bright"; case .relaxed: "Relaxed"; case .upbeat: "Upbeat" }
    }
}

// The native cancellation flag is atomic; this is the only native object shared across threads.
private final class VoiceCancellation: @unchecked Sendable {
    let pointer = yv_cancellation_create()!
    func cancel() { yv_cancellation_cancel(pointer) }
    deinit { yv_cancellation_destroy(pointer) }
}

private final class AudioSink {
    let continuation: AsyncThrowingStream<[Float], Error>.Continuation
    let cancellation: VoiceCancellation
    init(_ continuation: AsyncThrowingStream<[Float], Error>.Continuation, cancellation: VoiceCancellation) {
        self.continuation = continuation
        self.cancellation = cancellation
    }
}

// ONNX sessions and voice caches are confined to this serial queue. No model work runs on the UI thread.
final class VoiceRuntime: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.rona.voice.inference", qos: .userInitiated)
    private var engine: OpaquePointer?
    private let bundleURL: URL

    init(bundleURL: URL) { self.bundleURL = bundleURL }
    deinit { if let engine { yv_engine_destroy(engine) } }

    func prepare() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do { try load(); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func load() throws {
        if engine != nil { return }
        var error: UnsafeMutablePointer<CChar>?
        guard let loaded = yv_engine_create(bundleURL.path, &error) else { throw nativeError(error) }
        guard yv_validate_tokenizer(loaded, &error) else {
            yv_engine_destroy(loaded)
            throw nativeError(error)
        }
        engine = loaded
    }

    private func nativeError(_ pointer: UnsafeMutablePointer<CChar>?) -> VoiceFailure {
        defer { yv_free_error(pointer) }
        return VoiceFailure(message: pointer.map { String(cString: $0) } ?? "The local voice model could not run.")
    }

    func audio(for text: String, voice: Voice) -> AsyncThrowingStream<[Float], Error> {
        let cancellation = VoiceCancellation()
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(64)) { continuation in
            continuation.onTermination = { _ in cancellation.cancel() }
            queue.async { [self] in
                do {
                    try load()
                    let sink = AudioSink(continuation, cancellation: cancellation)
                    let context = Unmanaged.passRetained(sink).toOpaque()
                    defer { Unmanaged<AudioSink>.fromOpaque(context).release() }
                    var error: UnsafeMutablePointer<CChar>?
                    let success = yv_synthesize(engine, text, voice.rawValue, cancellation.pointer, { samples, count, context in
                        guard let samples, let context else { return }
                        let sink = Unmanaged<AudioSink>.fromOpaque(context).takeUnretainedValue()
                        let result = sink.continuation.yield(Array(UnsafeBufferPointer(start: samples, count: count)))
                        if case .dropped = result {
                            sink.cancellation.cancel()
                            sink.continuation.finish(throwing: VoiceFailure(message: "Audio playback fell behind. Please try a shorter reply."))
                        }
                    }, context, &error)
                    if success { continuation.finish() }
                    else { continuation.finish(throwing: nativeError(error)) }
                } catch { continuation.finish(throwing: error) }
            }
        }
    }
}
