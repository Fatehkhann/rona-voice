import XCTest
@testable import RonaVoice

final class SentenceAccumulatorTests: XCTestCase {
    func testCumulativeSnapshotsDoNotRepeatSpeech() {
        var accumulator = SentenceAccumulator()
        XCTAssertEqual(accumulator.take(from: "Hello"), [])
        XCTAssertEqual(accumulator.take(from: "Hello."), [])
        XCTAssertEqual(accumulator.take(from: "Hello. How"), ["Hello."])
        XCTAssertEqual(accumulator.take(from: "Hello. How are you?"), [])
        XCTAssertEqual(accumulator.take(from: "Hello. How are you?", final: true), ["How are you?"])
        XCTAssertEqual(accumulator.take(from: "Hello. How are you?", final: true), [])
    }

    func testDecimalsAndFinalFragment() {
        var accumulator = SentenceAccumulator()
        XCTAssertEqual(accumulator.take(from: "It costs 3.14 dollars. That helps"), ["It costs 3.14 dollars."])
        XCTAssertEqual(accumulator.take(from: "It costs 3.14 dollars. That helps", final: true), ["That helps"])
    }

    func testUnicodeAndWhitespace() {
        var accumulator = SentenceAccumulator()
        XCTAssertEqual(accumulator.take(from: "  Let’s talk!  I’m here. "), ["Let’s talk!", "I’m here."])
        XCTAssertEqual(accumulator.take(from: "  Let’s talk!  I’m here. ", final: true), [])
    }

    @MainActor func testInputBoundsAndClear() {
        let model = Conversation()
        model.phase = .idle
        model.languageIssue = nil
        model.draft = "   "
        XCTAssertFalse(model.canSend)
        model.draft = String(repeating: "a", count: 1501)
        XCTAssertFalse(model.canSend)
        model.draft = "Hello"
        XCTAssertTrue(model.canSend)
        model.phase = .thinking
        XCTAssertFalse(model.canSend)
        model.messages = [Message(role: .user, text: "Hello"), Message(role: .assistant, text: "Partial", delivery: .streaming)]
        model.stop()
        XCTAssertEqual(model.messages.last?.delivery, .interrupted)
        XCTAssertEqual(model.phase, .idle)
        model.clear()
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertTrue(model.draft.isEmpty)
    }
}
