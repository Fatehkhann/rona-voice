import Foundation
import Observation

struct Message: Identifiable {
    enum Role { case user, assistant }
    enum Delivery { case streaming, complete, interrupted, failed }
    let id = UUID()
    let role: Role
    var text: String
    var delivery: Delivery = .complete
}

enum ConversationPhase: Equatable {
    case preparing, idle, requestingMicrophone, listening, finishing, thinking, speaking
    var title: String {
        switch self {
        case .preparing: "Getting ready"
        case .idle: "Ready when you are"
        case .requestingMicrophone: "Opening microphone"
        case .listening: "I’m listening"
        case .finishing: "One moment"
        case .thinking: "Thinking with you"
        case .speaking: "Rona is speaking"
        }
    }
    var isWorking: Bool { self != .idle && self != .preparing }
}

@MainActor @Observable
final class Conversation {
    var messages: [Message] = []
    var draft = ""
    var liveTranscript = ""
    var phase = ConversationPhase.preparing
    var selectedVoice = Voice.warm
    var muted = false {
        didSet { if muted { playback.stop() } }
    }
    var voiceConversation = false
    var microphoneLevel: Float = 0
    var issue: String?
    var languageIssue: String?
    var microphoneIssue: String?
    var downloadingSpeech = false
    var voiceReady = false
    let maximumMessageLength = 1500

    @ObservationIgnored private let language = LanguageEngine()
    @ObservationIgnored private let speech = SpeechInput()
    @ObservationIgnored private let playback = AudioPlayback()
    @ObservationIgnored private let voice: VoiceRuntime
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var silence: Task<Void, Never>?
    @ObservationIgnored private var listeningLimit: Task<Void, Never>?
    @ObservationIgnored private var epoch = UUID()

    var canSend: Bool {
        phase == .idle && languageIssue == nil && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.count <= maximumMessageLength
    }
    var canListen: Bool { phase != .preparing && languageIssue == nil && microphoneIssue == nil }
    var canDownloadSpeech: Bool { microphoneIssue != nil && speech.canInstallAssets }

    init(bundleURL: URL? = nil) {
        voice = VoiceRuntime(bundleURL: bundleURL ?? Bundle.main.resourceURL!.appendingPathComponent("YaraVoice_bundle"))
    }

    func prepare() async {
        guard phase == .preparing else { return }
        languageIssue = language.availabilityIssue
        language.prepare()
        microphoneIssue = await speech.availabilityIssue()
        do { try await voice.prepare(); voiceReady = true }
        catch { issue = "The voice model could not load. You can still type. \(error.localizedDescription)" }
        phase = .idle
    }

    func refreshAvailability() async {
        issue = nil
        languageIssue = language.availabilityIssue
        microphoneIssue = await speech.availabilityIssue()
        if !voiceReady {
            do { try await voice.prepare(); voiceReady = true; issue = nil }
            catch { issue = error.localizedDescription }
        }
    }

    func downloadSpeechAssets() async {
        guard !downloadingSpeech else { return }
        downloadingSpeech = true
        defer { downloadingSpeech = false }
        do {
            try await speech.installAssets()
            microphoneIssue = nil
            issue = nil
        } catch { issue = "English speech could not be downloaded. \(error.localizedDescription)" }
    }

    func sendDraft() {
        guard canSend else { return }
        let value = draft
        draft = ""
        submit(value)
    }

    func suggest(_ text: String) {
        guard phase == .idle else { return }
        draft = text
        sendDraft()
    }

    private func submit(_ input: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { phase = .idle; return }
        guard text.count <= maximumMessageLength else {
            draft = text
            issue = "Please shorten your message to \(maximumMessageLength) characters so it fits the on-device model."
            voiceConversation = false
            phase = .idle
            return
        }
        let identifier = UUID()
        epoch = identifier
        issue = nil
        liveTranscript = ""
        messages.append(Message(role: .user, text: text))
        let answer = Message(role: .assistant, text: "", delivery: .streaming)
        messages.append(answer)
        phase = .thinking
        let chosenVoice = selectedVoice
        operation = Task { [self] in
            let (sentences, continuation) = AsyncStream<String>.makeStream()
            let speechTask = Task { @MainActor [self] in
                for await sentence in sentences {
                    try Task.checkCancellation()
                    guard epoch == identifier else { throw CancellationError() }
                    if muted || !voiceReady { continue }
                    for try await samples in voice.audio(for: sentence, voice: chosenVoice) {
                        try Task.checkCancellation()
                        guard epoch == identifier else { throw CancellationError() }
                        if muted { break }
                        try playback.enqueue(samples)
                        phase = .speaking
                    }
                }
                if !muted {
                    do { try await playback.finish() }
                    catch is CancellationError where muted && !Task.isCancelled { /* Muting stops audio, not the reply. */ }
                }
            }
            defer { continuation.finish(); speechTask.cancel() }
            do {
                var accumulator = SentenceAccumulator()
                var latest = ""
                try await language.respond(to: text) { snapshot in
                    guard self.epoch == identifier else { return }
                    latest = snapshot
                    self.update(answer.id, text: snapshot)
                    for sentence in accumulator.take(from: snapshot) { continuation.yield(sentence) }
                }
                for sentence in accumulator.take(from: latest, final: true) { continuation.yield(sentence) }
                continuation.finish()
                update(answer.id, delivery: .complete)
                try await speechTask.value
                guard epoch == identifier, !Task.isCancelled else { return }
                playback.stop()
                phase = .idle
                operation = nil
                if voiceConversation { beginListening() }
            } catch {
                continuation.finish()
                speechTask.cancel()
                guard epoch == identifier, !Task.isCancelled else { return }
                playback.stop()
                update(answer.id, delivery: .failed)
                issue = friendlyError(error)
                phase = .idle
                voiceConversation = false
                operation = nil
            }
        }
    }

    func microphoneTapped() {
        if phase == .listening { finishListening(); return }
        guard canListen else { return }
        if phase.isWorking { stop() }
        voiceConversation = true
        beginListening()
    }

    private func beginListening() {
        guard canListen else { voiceConversation = false; return }
        let identifier = UUID()
        epoch = identifier
        issue = nil
        liveTranscript = ""
        phase = .requestingMicrophone
        operation = Task { [self] in
            do {
                try await speech.start(update: { [weak self] text in
                    guard let self, self.epoch == identifier, self.phase == .listening else { return }
                    self.liveTranscript = text
                    self.scheduleEndOfTurn(identifier)
                }, level: { [weak self] level in
                    guard let self, self.epoch == identifier else { return }
                    self.microphoneLevel = level
                }, failure: { [weak self] error in
                    guard let self, self.epoch == identifier else { return }
                    self.stop()
                    self.issue = error.localizedDescription
                })
                guard epoch == identifier, !Task.isCancelled else { return }
                phase = .listening
                // Avoid leaving an idle microphone active indefinitely.
                listeningLimit = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(45))
                    guard !Task.isCancelled, let self, self.epoch == identifier else { return }
                    if self.liveTranscript.isEmpty {
                        self.stop()
                        self.issue = "I didn’t hear anything. Tap the microphone when you’re ready."
                    } else { self.finishListening() }
                }
            } catch {
                guard epoch == identifier, !Task.isCancelled else { return }
                stop()
                issue = error.localizedDescription
            }
        }
    }

    private func scheduleEndOfTurn(_ identifier: UUID) {
        silence?.cancel()
        guard !liveTranscript.isEmpty else { return }
        silence = Task { [weak self] in
            // A 1.6 s pause lets the person finish a thought before automatically sending it.
            try? await Task.sleep(for: .milliseconds(1600))
            guard !Task.isCancelled, let self, self.epoch == identifier, self.phase == .listening else { return }
            self.finishListening()
        }
    }

    private func finishListening() {
        guard phase == .listening else { return }
        silence?.cancel()
        listeningLimit?.cancel()
        phase = .finishing
        let identifier = epoch
        operation = Task { [self] in
            let text = await speech.finish()
            guard epoch == identifier, !Task.isCancelled else { return }
            microphoneLevel = 0
            if text.isEmpty {
                voiceConversation = false
                phase = .idle
                issue = "I didn’t catch that. Try speaking again, or type below."
            } else { submit(text) }
        }
    }

    func stop() {
        epoch = UUID()
        operation?.cancel()
        operation = nil
        silence?.cancel()
        listeningLimit?.cancel()
        silence = nil
        listeningLimit = nil
        speech.cancel()
        playback.stop()
        language.interrupt()
        for index in messages.indices where messages[index].delivery == .streaming {
            messages[index].delivery = .interrupted
        }
        messages.removeAll { $0.role == .assistant && $0.text.isEmpty }
        phase = .idle
        microphoneLevel = 0
        liveTranscript = ""
        voiceConversation = false
    }

    func clear() {
        stop()
        messages = []
        draft = ""
        issue = nil
        language.reset()
    }

    private func update(_ id: UUID, text: String? = nil, delivery: Message.Delivery? = nil) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        if let text { messages[index].text = text }
        if let delivery { messages[index].delivery = delivery }
    }

    private func friendlyError(_ error: Error) -> String {
        if error is CancellationError { return "The reply was stopped. You can start again." }
        return "The reply couldn’t finish. \(error.localizedDescription)"
    }
}
