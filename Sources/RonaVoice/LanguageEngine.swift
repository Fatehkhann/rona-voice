import Foundation
import FoundationModels

@MainActor
final class LanguageEngine {
    private var session = LanguageModelSession(instructions: instructions)
    private var completedTurns = 0
    private var recentTurns: [(user: String, assistant: String)] = []
    static let instructions = """
        You are Rona, a thoughtful, friendly conversational companion running privately on this Mac.
        Speak casually in English, like an easygoing conversation with a friend, not a written assistant response.
        Usually use one to three short sentences, under 70 words. Use contractions and varied sentence lengths.
        Be useful, direct, and warm. Occasionally include natural spoken reactions: "Hmm," or "Um," while
        considering something, "I guess" for a tentative opinion, "Aha!" for a realization, or "Uh-huh" and
        "Ah, I see" when acknowledging someone. A brief "Ha!" or "Haha," is welcome when something is funny.
        Use these only where they fit; do not force a filler or laugh into every answer, repeat the same opening,
        or laugh at serious or upsetting topics. Ask a short, conversational follow-up when it would help.
        Write the actual words to speak. Never output stage directions such as [laughs], [pause], or *chuckles*.
        Use plain text, without Markdown, lists, or emojis, because your reply will be spoken aloud.
        You have no internet access and cannot take actions outside this conversation. Never pretend to
        search, send messages, access files, or complete tasks you cannot perform. Be candid when uncertain.
        """

    var availabilityIssue: String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(.appleIntelligenceNotEnabled):
            "Turn on Apple Intelligence in System Settings, then return here and retry."
        case .unavailable(.deviceNotEligible):
            "This app needs an Apple silicon Mac that supports Apple Intelligence."
        case .unavailable(.modelNotReady):
            "Apple’s on-device language model is not ready. Let its initial download finish in System Settings, then retry."
        case .unavailable:
            "Apple Intelligence is currently unavailable on this Mac. Check its language and region in System Settings."
        }
    }

    func prepare() { if availabilityIssue == nil { session.prewarm() } }

    func reset() {
        session = LanguageModelSession(instructions: Self.instructions)
        completedTurns = 0
        recentTurns = []
    }

    // Keep recent conversational context inside the model's finite window. Conversation text stays
    // in a user prompt, never in higher-priority system instructions.
    private func renewedSession() -> String {
        session = LanguageModelSession(instructions: Self.instructions)
        completedTurns = 0
        let context = recentTurns.suffix(2).map { "User: \($0.user)\nRona: \($0.assistant)" }.joined(separator: "\n")
        return context.isEmpty ? "" : "Earlier conversation (for context):\n\(context)\n\nCurrent message:\n"
    }

    func respond(to prompt: String, snapshot: @MainActor (String) -> Void) async throws {
        if let issue = availabilityIssue { throw VoiceFailure(message: issue) }
        var prefix = completedTurns >= 4 ? renewedSession() : ""
        for attempt in 0...1 {
            // Capture the session: reset/interruption may replace the property while this stream unwinds.
            let activeSession = session
            do {
                var answer = ""
                let stream = activeSession.streamResponse(to: prefix + prompt,
                    options: GenerationOptions(temperature: 0.65, maximumResponseTokens: 220))
                for try await part in stream {
                    try Task.checkCancellation()
                    answer = part.content
                    snapshot(answer)
                }
                try Task.checkCancellation()
                guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw VoiceFailure(message: "The model returned an empty reply. Please try again.")
                }
                recentTurns.append((String(prompt.prefix(1500)), String(answer.prefix(1500))))
                recentTurns = Array(recentTurns.suffix(2))
                completedTurns += 1
                return
            } catch LanguageModelSession.GenerationError.exceededContextWindowSize where attempt == 0 {
                prefix = renewedSession()
            } catch {
                // A cancelled/failed generation must not poison the next session.
                if session === activeSession { _ = renewedSession() }
                throw error
            }
        }
    }

    func interrupt() { _ = renewedSession() }
}

// Streams complete sentences to speech, with no duplicate text from cumulative model snapshots.
struct SentenceAccumulator {
    private(set) var consumed = 0

    mutating func take(from text: String, final: Bool = false) -> [String] {
        let characters = Array(text)
        guard characters.count >= consumed else { return [] }
        var sentences: [String] = []
        var start = consumed
        for index in consumed..<characters.count {
            guard ".!?\n".contains(characters[index]) else { continue }
            // Wait for the following whitespace so a streamed decimal/abbreviation is not cut early.
            let next = index + 1
            guard next < characters.count, characters[next].isWhitespace else { continue }
            let value = String(characters[start...index]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { sentences.append(value) }
            start = next
            consumed = next
        }
        if final, consumed < characters.count {
            let value = String(characters[consumed...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { sentences.append(value) }
            consumed = characters.count
        }
        return sentences
    }
}
