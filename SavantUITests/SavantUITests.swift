import XCTest

final class SavantUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLaunchAndSearchSmokePath() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--skip-onboarding"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Personal"].waitForExistence(timeout: 5))

        let input = quickAddInput(in: app)
        XCTAssertTrue(input.waitForExistence(timeout: 5))

        app.buttons["space-search"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Recent"].waitForExistence(timeout: 5))
    }

    func testQuickAddSendAndManualTidyPath() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--skip-onboarding"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Personal"].waitForExistence(timeout: 5))

        sendQuickNote("home paint samples", in: app)
        XCTAssertTrue(app.buttons["home paint samples"].waitForExistence(timeout: 5))

        sendQuickNote("home repair quote", in: app)
        XCTAssertTrue(app.buttons["home repair quote"].waitForExistence(timeout: 5))

        let tidyButton = app.buttons["Tidy"].firstMatch
        XCTAssertTrue(tidyButton.waitForExistence(timeout: 5))
        tidyButton.tap()

        XCTAssertTrue(app.staticTexts["Tidy review"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Tidied 2 notes"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["0 archived · 1 folders created"].waitForExistence(timeout: 5))
    }

    func testKeyboardDismissesFromContentTapAndFieldSwipe() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--skip-onboarding"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Personal"].waitForExistence(timeout: 5))

        let input = quickAddInput(in: app)
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["quick-add-unfocused"].waitForExistence(timeout: 5))

        input.tap()
        XCTAssertTrue(app.descendants(matching: .any)["quick-add-focused"].waitForExistence(timeout: 5))

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.34)).tap()
        XCTAssertTrue(app.descendants(matching: .any)["quick-add-unfocused"].waitForExistence(timeout: 5))

        input.tap()
        XCTAssertTrue(app.descendants(matching: .any)["quick-add-focused"].waitForExistence(timeout: 5))
        let start = input.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = input.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 3.0))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(app.descendants(matching: .any)["quick-add-unfocused"].waitForExistence(timeout: 5))
    }

    func testMoveHandlePromotesNoteToPinned() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--skip-onboarding"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Personal"].waitForExistence(timeout: 5))

        sendQuickNote("drag me into pinned", in: app)
        let note = app.buttons["drag me into pinned"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 5))

        let handle = app.descendants(matching: .any)["note-drag-handle-drag me into pinned"].firstMatch
        XCTAssertTrue(handle.waitForExistence(timeout: 5))
        handle.tap()

        let pinnedDropTarget = app.descendants(matching: .any)["drop-target-pinned"].firstMatch
        XCTAssertTrue(pinnedDropTarget.waitForExistence(timeout: 5))
        handle.press(forDuration: 0.4, thenDragTo: pinnedDropTarget)

        XCTAssertTrue(app.staticTexts["PINNED"].waitForExistence(timeout: 5))
    }

    func testCaptureViewsForReview() throws {
        var app = launchSeededApp()
        capture("01-home")

        app = launchSeededApp()
        app.buttons["Review"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Tidied 6 notes"].waitForExistence(timeout: 5))
        capture("02-tidy-review")

        app = launchSeededApp()
        app.buttons["space-search"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Recent"].waitForExistence(timeout: 5))
        capture("03-search")

        app = launchSeededApp()
        openOverflowMenu(in: app)
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Private CloudKit database enabled"].waitForExistence(timeout: 5))
        capture("04-settings")

        app = launchSeededApp()
        openOverflowMenu(in: app)
        app.buttons["New space"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Custom"].waitForExistence(timeout: 5))
        capture("05-new-space")

        app = launchSeededApp()
        app.staticTexts["Renew passport before July"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 5))
        capture("06-note-read")

        app = launchSeededApp()
        app.staticTexts["Renew passport before July"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 5))
        app.buttons["Edit"].firstMatch.tap()
        XCTAssertTrue(app.textViews["note-body-editor"].waitForExistence(timeout: 5))
        capture("07-note-edit")
    }

    private func launchSeededApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--skip-onboarding", "--screenshot-data"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Personal"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Renew passport before July"].waitForExistence(timeout: 5))
        return app
    }

    private func openOverflowMenu(in app: XCUIApplication) {
        let menuButton = app.buttons["More actions"].firstMatch
        XCTAssertTrue(menuButton.waitForExistence(timeout: 5))
        menuButton.tap()
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func sendQuickNote(_ text: String, in app: XCUIApplication) {
        let input = quickAddInput(in: app)
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText(text)

        let sendButton = app.buttons["Send note"].firstMatch
        XCTAssertTrue(sendButton.waitForExistence(timeout: 5))
        sendButton.tap()
    }

    private func quickAddInput(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["quick-add-field"].firstMatch
    }
}
