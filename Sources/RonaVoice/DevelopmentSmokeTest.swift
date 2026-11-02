#if DEBUG
import AppKit
import Foundation

/// In-process integration exercise for development. This captures the actual app's content view,
/// not the desktop; it does not drive OS UI, request automation privileges, or simulate microphone input.
@MainActor enum DevelopmentSmokeTest {
    private static var started = false
    private static let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RonaVoiceSmoke")

    static func run(_ conversation: Conversation) async {
        guard !started else { return }
        started = true
        var checks: [String] = []
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try await wait { conversation.phase == .idle }
            guard conversation.languageIssue == nil, conversation.voiceReady else {
                throw VoiceFailure(message: conversation.languageIssue ?? conversation.issue ?? "Models not ready")
            }
            NSApp.appearance = NSAppearance(named: .aqua)
            try await capture("01-welcome-light")
            NSApp.appearance = NSAppearance(named: .darkAqua)
            try await capture("02-welcome-dark")
            NSApp.appearance = NSAppearance(named: .aqua)
            conversation.draft = "My name is Sam. Say hello in one short sentence."
            conversation.sendDraft()
            try await wait { conversation.phase == .speaking || conversation.issue != nil }
            guard conversation.issue == nil else { throw VoiceFailure(message: conversation.issue!) }
            try await capture("03-speaking")
            try await wait { conversation.phase == .idle }
            guard conversation.issue == nil else { throw VoiceFailure(message: conversation.issue!) }
            checks.append("Real typed turn, streamed Foundation Models response, native speech, and audio playback completion")
            conversation.draft = "What is my name? Answer with just my name."
            conversation.sendDraft()
            try await wait { conversation.phase == .idle }
            guard conversation.messages.last?.text.lowercased().contains("sam") == true else {
                throw VoiceFailure(message: "Conversation did not retain the user's name")
            }
            checks.append("Conversational memory")
            try await capture("04-conversation")

            conversation.draft = "Tell me a story in three sentences about a fox who learns to paint."
            conversation.sendDraft()
            try await wait { conversation.phase == .speaking || conversation.issue != nil }
            conversation.muted = true
            try await wait { conversation.phase == .idle }
            guard conversation.issue == nil else { throw VoiceFailure(message: conversation.issue!) }
            checks.append("Muting during playback preserves the reply and returns to idle")
            conversation.muted = false

            conversation.draft = "Tell me about a peaceful garden in three sentences."
            conversation.sendDraft()
            try await wait { conversation.phase == .speaking || conversation.issue != nil }
            conversation.stop()
            conversation.draft = "Say hello again."
            conversation.sendDraft()
            try await wait { conversation.phase == .idle }
            guard conversation.issue == nil else { throw VoiceFailure(message: conversation.issue!) }
            checks.append("Stop during speech followed immediately by a successful new turn")
            conversation.clear()
            guard conversation.messages.isEmpty, conversation.draft.isEmpty else { throw VoiceFailure(message: "Clear failed") }
            checks.append("New conversation clears transcript and draft")
            if let window = NSApp.windows.first(where: { $0.contentView != nil && $0.title == "Rona Voice" }) {
                window.setContentSize(NSSize(width: 900, height: 690))
                try await capture("05-minimum-size")
                window.setContentSize(NSSize(width: 1040, height: 760))
            }
            try await write(["result": "passed", "checks": checks, "scope": "In-process app state and content-view captures. Not XCTest UI automation or live microphone verification."])
        } catch {
            conversation.stop()
            try? await capture("failure")
            try? await write(["result": "failed", "checks": checks, "error": error.localizedDescription])
        }
        print("Smoke test artifacts: \(folder.path)")
    }

    private static func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(60)
        while !condition() {
            if Date() > deadline { throw VoiceFailure(message: "App state timed out") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func capture(_ name: String) async throws {
        try await Task.sleep(for: .milliseconds(250))
        guard let view = NSApp.windows.first(where: { $0.title == "Rona Voice" })?.contentView,
              let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw VoiceFailure(message: "App content view is not available for capture")
        }
        view.layoutSubtreeIfNeeded()
        view.cacheDisplay(in: view.bounds, to: image)
        guard let png = image.representation(using: .png, properties: [:]) else { throw VoiceFailure(message: "Capture failed") }
        try png.write(to: folder.appendingPathComponent(name + ".png"))
    }

    private static func write(_ result: [String: Any]) async throws {
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("result.json"))
    }
}
#endif
