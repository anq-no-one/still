import XCTest

@MainActor
final class StillEndToEndTests: XCTestCase {
    private let app = XCUIApplication()
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    func testRecordTranscribeFindAndReopen() {
        launch(resetting: true)
        completeOnboarding()
        waitFor(app.staticTexts["No Recordings Yet"], "an empty, unlocked Library")

        app.toolbars.buttons["Record"].tap()
        waitForText("budget", timeout: 60, "the live transcript to hear the meeting")
        keepScreenshot("1 Live transcript")

        let save = app.buttons["Save Recording"]
        waitFor(save, "the Save button")
        save.tap()
        waitForAbsence(save, timeout: 120, "the final transcript to finish and the sheet to close")

        let recording = app.collectionViews.cells.firstMatch
        waitFor(recording, "the saved Recording in the Library")
        recording.tap()
        waitForText("forecast", timeout: 20, "the saved transcript")
        keepScreenshot("2 Saved transcript")
        navigateBack()

        let search = app.searchFields["Search Recordings"]
        waitFor(search, "the search field")
        search.tap()
        search.typeText("Thursday")
        waitForText("Thursday", timeout: 10, "a search result for a spoken word", excluding: search)
        keepScreenshot("3 Search")

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

    private func launch(resetting: Bool) {
        continueAfterFailure = false
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        var environment = [
            "STILL_AUDIO_FIXTURE": "meeting",
            "STILL_UI_TEST_RESET": resetting ? "1" : "0",
        ]
        if let modelRoot = ProcessInfo.processInfo.environment["STILL_MODEL_ROOT"] {
            environment["STILL_MODEL_ROOT"] = modelRoot
        }
        app.launchEnvironment = environment
        app.launch()
    }

    private func keepScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func completeOnboarding() {
        tap("Continue")
        tapIfShown("Allow Microphone")
        tapIfShown("Not Now")
        tapIfShown(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Download'")).firstMatch)
        let setupStep = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Step '")).firstMatch
        waitForAbsence(setupStep, timeout: 1_800, "setup to finish, including the Model Pack download")
    }

    private func tapIfShown(_ label: String) {
        tapIfShown(app.buttons[label])
    }

    private func tapIfShown(_ button: XCUIElement, timeout: TimeInterval = 10) {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            allowSystemPrompts()
            if button.exists {
                button.tap()
                return
            }
            Thread.sleep(forTimeInterval: 1)
        }
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
