import XCTest

final class ConversationUITests: XCTestCase {
    @MainActor func testRealConversationAndInterruption() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let microphone = app.buttons["microphoneButton"]
        XCTAssertTrue(microphone.waitForExistence(timeout: 15))
        XCTAssertTrue(waitUntil(timeout: 30) { microphone.isEnabled })
        capture(app, "01-welcome")
        let input = app.textFields["messageInput"]
        XCTAssertTrue(input.exists, app.debugDescription)
        input.click()
        input.typeText("My name is Sam. Say hello in one short sentence.")
        app.buttons["sendButton"].click()
        let replies = app.descendants(matching: .any).matching(identifier: "assistantMessage")
        XCTAssertTrue(waitUntil(timeout: 45) { replies.firstMatch.exists && replies.firstMatch.label.lowercased().contains("sam") }, app.debugDescription)
        capture(app, "02-reply")
        XCTAssertTrue(waitUntil(timeout: 40) { !app.buttons["stopButton"].exists })
        input.click()
        input.typeText("What is my name? Answer with just my name.")
        app.buttons["sendButton"].click()
        XCTAssertTrue(waitUntil(timeout: 30) { !app.buttons["stopButton"].exists })
        XCTAssertEqual(replies.count, 2)
        XCTAssertTrue(replies.element(boundBy: 1).label.lowercased().contains("sam"))
        capture(app, "03-context")

        input.click()
        input.typeText("Tell me a short story about a fox who learns to paint.")
        app.buttons["sendButton"].click()
        let stop = app.buttons["stopButton"]
        XCTAssertTrue(stop.waitForExistence(timeout: 15))
        let status = app.descendants(matching: .any).matching(identifier: "conversationStatus").firstMatch
        XCTAssertTrue(waitUntil(timeout: 30) {
            status.label.contains("speaking") || (status.value as? String)?.contains("speaking") == true
        }, app.debugDescription)
        stop.click()
        XCTAssertFalse(stop.exists)
        capture(app, "04-interrupted")

        app.buttons["newConversationButton"].click()
        XCTAssertTrue(app.staticTexts["Where shall we start?"].waitForExistence(timeout: 5))
        app.buttons["muteButton"].click()
        XCTAssertEqual(app.buttons["muteButton"].label, "Unmute voice replies")
        app.buttons["muteButton"].click()
        XCTAssertEqual(app.buttons["muteButton"].label, "Mute voice replies")
        capture(app, "05-cleared")
    }

    @MainActor func testMicrophonePermissionAndStop() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let microphone = app.buttons["microphoneButton"]
        XCTAssertTrue(microphone.waitForExistence(timeout: 15))
        XCTAssertTrue(waitUntil(timeout: 30) { microphone.isEnabled })
        addUIInterruptionMonitor(withDescription: "Microphone access") { alert in
            for title in ["Allow", "OK"] where alert.buttons[title].exists { alert.buttons[title].click(); return true }
            return false
        }
        microphone.click()
        let permission = app.buttons["Allow"]
        if permission.waitForExistence(timeout: 2) { permission.click() }
        // A second click prompts XCTest to handle an OS permission interruption if present.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.06)).click()
        XCTAssertTrue(waitUntil(timeout: 30) {
            microphone.label == "Send what I said" || app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Allow Rona Voice")).count > 0
        })
        capture(app, "06-microphone")
        XCTAssertEqual(microphone.label, "Send what I said", "Microphone permission was not granted.")
        let stop = app.buttons["stopButton"]
        XCTAssertTrue(stop.exists)
        stop.click()
        XCTAssertEqual(microphone.label, "Start talking")
        capture(app, "07-microphone-stopped")
    }

    @MainActor private func waitUntil(timeout: TimeInterval, predicate: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
