import XCTest

/// Settings and provider Accounts & Usage over the Rust core's demo host
/// (seeded logins: two Claude Code accounts, Codex, Cursor, Grok).
final class SettingsTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ args: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-fast"] + args
        app.launch()
        return app
    }

    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func openSettings(_ app: XCUIApplication) {
        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }

    /// Settings summarizes each provider's account in use with its fullest
    /// usage window.
    func testSettingsOverview() {
        for (style, name) in [("2", "settings-dark"), ("1", "settings-light")] {
            let app = launch(["-appearance", style])
            openSettings(app)
            let claude = app.cells["settings-provider:claude-code"]
            XCTAssertTrue(claude.waitForExistence(timeout: 10), "provider summary loads")
            XCTAssertTrue(app.cells["settings-provider:codex"].exists)
            XCTAssertTrue(app.staticTexts["42%"].exists || claude.label.contains("42"), "Claude Code's session window: \(claude.debugDescription)")
            sleep(1)
            snapshot(app, name)
            app.swipeUp()
            sleep(1)
            snapshot(app, name + "-lower")
            app.terminate()
        }
    }

    /// Tapping a login makes it the one in use; swipe removes one.
    func testProviderAccountsSwitchAndRemove() {
        let app = launch()
        openSettings(app)
        let claude = app.cells["settings-provider:claude-code"]
        XCTAssertTrue(claude.waitForExistence(timeout: 10))
        claude.tap()
        XCTAssertTrue(app.navigationBars["Accounts & Usage"].waitForExistence(timeout: 5))
        let work = app.cells["account-a1c0de0000000001"]
        let personal = app.cells["account-a1c0de0000000002"]
        XCTAssertTrue(personal.waitForExistence(timeout: 5))
        XCTAssertEqual(work.value as? String, "In use", "first login in use")
        sleep(1)
        snapshot(app, "accounts")

        personal.tap()
        XCTAssertTrue(app.staticTexts["Claude Code now uses wing.lee@gmail.com"].waitForExistence(timeout: 5), "switch confirmed")
        XCTAssertEqual(personal.value as? String, "In use")
        XCTAssertNotEqual(work.value as? String, "In use", "one login in use per provider")
        snapshot(app, "accounts-switched")

        work.swipeLeft()
        app.buttons["Remove"].tap()
        let confirm = app.buttons["Remove Account"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(work.waitForNonExistence(timeout: 5), "removed")
    }

    /// Theme and wallpaper choices open in place as menus.
    func testThemeMenu() {
        let app = launch()
        openSettings(app)
        let theme = app.cells["settings-theme"]
        for _ in 0..<4 where !theme.isHittable || theme.frame.maxY > app.windows.firstMatch.frame.height * 0.7 { app.swipeUp() }
        theme.tap()
        let light = app.buttons["Light"]
        XCTAssertTrue(light.waitForExistence(timeout: 5))
        snapshot(app, "theme-menu")
        light.tap()
        XCTAssertTrue(app.cells.matching(NSPredicate(format: "identifier == 'settings-theme' AND (label CONTAINS 'Light' OR value CONTAINS 'Light')")).firstMatch.waitForExistence(timeout: 5))
        // Back to the system theme for the tests after this one.
        theme.tap()
        app.buttons["System"].tap()
    }

    /// A session opens the accounts on its computer at its own agent.
    func testAccountsFromSession() {
        let app = launch(["-route", "chat:chat-deploy"])
        XCTAssertTrue(app.scrollViews["transcript"].waitForExistence(timeout: 10))
        app.navigationBars.buttons["More"].firstMatch.tap()
        let item = app.buttons["Account & Usage"]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
        XCTAssertTrue(app.navigationBars["Accounts & Usage"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'account-'")).firstMatch.waitForExistence(timeout: 10))
        sleep(1)
        snapshot(app, "accounts-from-session")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.scrollViews["transcript"].waitForExistence(timeout: 5))
    }

    /// Near a plan limit, the composer says so, and its menu switches logins.
    func testUsageChipWarnsNearLimit() {
        let app = launch()
        openSettings(app)
        let claude = app.cells["settings-provider:claude-code"]
        XCTAssertTrue(claude.waitForExistence(timeout: 10))
        claude.tap()
        // The personal login is at 88% of its session window.
        let personal = app.cells["account-a1c0de0000000002"]
        XCTAssertTrue(personal.waitForExistence(timeout: 5))
        personal.tap()
        XCTAssertTrue(app.staticTexts["Claude Code now uses wing.lee@gmail.com"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Sessions"].tap()
        let row = app.cells["session-chat-veil"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        // Chips ride in the open composer (where the next message is written).
        let input = app.textViews["composer-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        let chip = app.buttons["composer-chip-usage"]
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "near-limit chip")
        sleep(1)
        snapshot(app, "usage-chip")
        XCTAssertTrue(chip.label.contains("88%"), chip.label)
        chip.tap()
        sleep(1)
        snapshot(app, "usage-chip-menu")
        let back = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Switch to wing@zeron.sh'")).firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), app.debugDescription)
        back.tap()
        XCTAssertTrue(chip.waitForNonExistence(timeout: 5), "back on the login with headroom")
    }
}
