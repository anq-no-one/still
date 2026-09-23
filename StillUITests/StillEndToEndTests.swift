import XCTest

/// Drives the real app from a first launch. The microphone hears a recorded
/// meeting, so every run transcribes the same words: "Good morning everyone.
/// The quarterly budget review moves to Thursday. Maria will send the updated
/// forecast by Friday."
@MainActor
final class StillEndToEndTests: XCTestCase {
    private let app = XCUIApplication()
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    func testRecordTranscribeFindAndReopen() {
        launch(resetting: true)
        completeOnboarding()
        waitFor(app.staticTexts["No Recordings Yet"], "an empty, unlocked Library")

        app.toolbars.buttons["Record"].tap()
        if Self.canRecognizeSpeech {
            waitForText("budget", timeout: 45, "the live transcript to hear the meeting")
        } else {
            waitForText("live transcript stopped", timeout: 30, "the notice that recording continues without a live transcript")
            Thread.sleep(forTimeInterval: 8)
        }

        let save = app.buttons["Save Recording"]
        waitFor(save, "the Save button")
        save.tap()
        waitForAbsence(save, timeout: 120, "the final transcript to finish and the sheet to close")

        let recording = app.collectionViews.cells.firstMatch
        waitFor(recording, "the saved Recording in the Library")
        recording.tap()
        if Self.canRecognizeSpeech {
            waitForText("forecast", timeout: 20, "the saved transcript")
        } else {
            waitFor(app.staticTexts["No Transcript"], "the Recording kept without words")
        }
        navigateBack()

        if Self.canRecognizeSpeech {
            let search = app.searchFields["Search Recordings"]
            waitFor(search, "the search field")
            search.tap()
            search.typeText("Thursday")
            waitForText("Thursday", timeout: 10, "a search result for a spoken word", excluding: search)
        }

        app.terminate()
        launch(resetting: false)
        waitFor(app.collectionViews.cells.firstMatch, timeout: 30, "the encrypted Library to reopen after relaunch")
    }

    func testSettingsShowARecoveryCode() {
        launch(resetting: true)
        completeOnboarding()
        waitFor(app.staticTexts["No Recordings Yet"], "an empty, unlocked Library")

        app.buttons["Settings"].tap()
        app.staticTexts["Keys and Devices"].tap()
        app.buttons["Show Recovery Code"].tap()
        waitForText("Write this down now", timeout: 10, "the recovery code explanation")

        navigateBack()
        app.staticTexts["Audio and Deletion"].tap()
        waitFor(app.staticTexts["Keep Audio"], "the retention choices")
    }

    /// The simulator ships without on-device speech models, so there the run
    /// proves that a Recording survives a device that cannot transcribe.
    private static var canRecognizeSpeech: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }

    private func launch(resetting: Bool) {
        continueAfterFailure = false
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment = [
            "STILL_AUDIO_FIXTURE": "meeting",
            "STILL_UI_TEST_RESET": resetting ? "1" : "0",
        ]
        app.launch()
    }

    private func completeOnboarding() {
        tap("Continue")
        tap("Allow Microphone")
        tap("Not Now")
    }

    private func tap(_ label: String) {
        let button = app.buttons[label]
        waitFor(button, "the \(label) button")
        button.tap()
    }

    private func navigateBack() {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    private func waitForText(
        _ text: String,
        timeout: TimeInterval,
        _ what: String,
        excluding excluded: XCUIElement? = nil
    ) {
        let predicate = NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", text, text)
        let matches = app.descendants(matching: .any).matching(predicate)
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            allowSystemPrompts()
            let found = matches.allElementsBoundByIndex.contains { element in
                element.exists && element != excluded && element.elementType != .searchField
            }
            if found { return }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTFail("Timed out waiting for \(what): no element shows “\(text)”.")
    }

    private func waitFor(_ element: XCUIElement, timeout: TimeInterval = 15, _ what: String) {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            allowSystemPrompts()
            if element.exists { return }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTFail("Timed out waiting for \(what).")
    }

    private func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval, _ what: String) {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            allowSystemPrompts()
            if !element.exists { return }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTFail("Timed out waiting for \(what).")
    }

    /// Speech recognition asks once per install, in a system alert the app
    /// cannot answer for itself.
    private func allowSystemPrompts() {
        for label in ["Allow", "OK", "Allow While Using App"] {
            let button = springboard.alerts.buttons[label]
            if button.exists {
                button.tap()
                return
            }
        }
    }
}
