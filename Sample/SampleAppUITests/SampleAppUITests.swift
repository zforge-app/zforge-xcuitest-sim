import XCTest

/// Ordinary XCUITests. They must pass unchanged in a real run and in an offscreen run.
final class SampleAppUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        XCTAssertTrue(app.windows["Sample"].waitForExistence(timeout: 10), app.debugDescription)
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    @MainActor
    func testButtonClick() {
        app.buttons["increment-button"].click()
        app.buttons["increment-button"].click()
        XCTAssertTrue(app.staticTexts["Clicks: 2"].waitForExistence(timeout: 3), app.debugDescription)
    }

    @MainActor
    func testKeyboardShortcut() {
        app.typeKey("k", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.staticTexts["Shortcuts: 1"].waitForExistence(timeout: 3), app.debugDescription)
    }

    @MainActor
    func testTextFieldFocusAndTyping() {
        let field = app.textFields["name-field"]
        app.textFields["other-field"].click()
        XCTAssertTrue(app.staticTexts["Field focused: no"].waitForExistence(timeout: 3), app.debugDescription)
        field.click()
        XCTAssertTrue(app.staticTexts["Field focused: yes"].waitForExistence(timeout: 3), app.debugDescription)
        field.typeText("Hello")
        XCTAssertTrue(app.staticTexts["Echo: Hello"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertEqual(field.value as? String, "Hello")
    }

    @MainActor
    func testContextMenu() {
        app.staticTexts["context-target"].rightClick()
        let item = app.menuItems["Mark Item"]
        XCTAssertTrue(item.waitForExistence(timeout: 3), app.debugDescription)
        item.click()
        XCTAssertTrue(app.staticTexts["Context actions: 1"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertFalse(item.exists)
    }

    @MainActor
    func testContextMenuEscapeCloses() {
        app.staticTexts["context-target"].rightClick()
        let item = app.menuItems["Mark Item"]
        XCTAssertTrue(item.waitForExistence(timeout: 3), app.debugDescription)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(item.waitForNonExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Context actions: 0"].exists)
    }

    @MainActor
    func testMenuBar() {
        app.menuBars.menuBarItems["Sample"].click()
        app.menuItems["Run Menu Action"].click()
        XCTAssertTrue(app.staticTexts["Menu actions: 1"].waitForExistence(timeout: 3), app.debugDescription)
    }

    @MainActor
    func testModifierClick() {
        let target = app.groups["modifier-target"]
        XCUIElement.perform(withKeyModifiers: .shift) { target.click() }
        XCTAssertTrue(app.staticTexts["Modifier click: shift"].waitForExistence(timeout: 3), app.debugDescription)
        target.click()
        XCTAssertTrue(app.staticTexts["Modifier click: plain"].waitForExistence(timeout: 3), app.debugDescription)
    }

    @MainActor
    func testHover() {
        app.groups["modifier-target"].hover()
        XCTAssertTrue(app.staticTexts["Hover: inside"].waitForExistence(timeout: 3), app.debugDescription)
        app.buttons["increment-button"].hover()
        XCTAssertTrue(app.staticTexts["Hover: outside"].waitForExistence(timeout: 3), app.debugDescription)
    }
}
