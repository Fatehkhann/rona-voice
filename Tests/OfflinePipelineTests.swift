import XCTest
import AVFoundation
import Speech
@testable import RonaVoice

final class OfflinePipelineTests: XCTestCase {
    @MainActor func testRealLanguageVoiceAndTranscription() async throws {
        let language = LanguageEngine()
        if let issue = language.availabilityIssue { throw XCTSkip(issue) }
        let speech = SpeechInput()
        if let issue = await speech.availabilityIssue() { throw XCTSkip(issue) }

        var answer = ""
        try await language.respond(to: "My name is Sam. Say exactly: Hello Sam. What would you like to talk about?") { answer = $0 }
        XCTAssertTrue(answer.lowercased().contains("sam"), answer)
        let voice = VoiceRuntime(bundleURL: Bundle.main.resourceURL!.appendingPathComponent("YaraVoice_bundle"))
        try await voice.prepare()
        var samples: [Float] = []
        for try await buffer in voice.audio(for: answer, voice: .warm) { samples += buffer }
        XCTAssertGreaterThan(samples.count, 24_000)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
            buffer.frameLength = buffer.frameCapacity
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
            try file.write(from: buffer)
        }
        let transcriber = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let transcriptionTask = Task { () throws -> String in
            var text = ""
            for try await result in transcriber.results { text += String(result.text.characters) }
            return text
        }
        let file = try AVAudioFile(forReading: url)
        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
        let transcribed = try await transcriptionTask.value
        XCTAssertTrue(transcribed.lowercased().contains("sam"), transcribed)
        let evidence = XCTAttachment(string: "Generated: \(answer)\nRecognized: \(transcribed)\nAudio: \(Double(samples.count) / 24_000) seconds")
        evidence.name = "offline-pipeline"
        evidence.lifetime = .keepAlways
        add(evidence)

        var remembered = ""
        try await language.respond(to: "What is my name? Answer with only my name.") { remembered = $0 }
        XCTAssertTrue(remembered.lowercased().contains("sam"), remembered)
    }
}
