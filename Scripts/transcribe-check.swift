import AVFoundation
import Speech
import Foundation

@main struct TranscribeCheck {
    static func main() async throws {
        for path in CommandLine.arguments.dropFirst() {
            let transcriber = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .transcription)
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let results = Task { () throws -> String in
                var text = ""
                for try await result in transcriber.results { text += String(result.text.characters) }
                return text
            }
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
            let text = try await results.value
            print("\(URL(fileURLWithPath: path).lastPathComponent): \(text)")
            guard text.lowercased().contains("hello"), text.lowercased().contains("talk") else {
                throw NSError(domain: "Voice intelligibility test failed", code: 1)
            }
        }
    }
}
