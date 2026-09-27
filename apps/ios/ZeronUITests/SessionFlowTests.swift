import XCTest

/// End-to-end flows over the Rust core's demo workspace (real registry,
/// session docs, command ledger and simulated host — no network).
final class SessionFlowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ args: [String] = [], fast: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo"] + (fast ? ["-fast"] : []) + args
        app.launch()
        return app
    }

    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testFrontPageShowsFoldersAndRecents() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Sessions"].waitForExistence(timeout: 10))
        let pinned = app.cells["section-pinned"]
        XCTAssertTrue(pinned.exists)
        snapshot(app, "front-page")
        // Sections fold in place, like the desktop sidebar.
        let wasCollapsed = pinned.value as? String == "Collapsed"
        pinned.tap()
        XCTAssertEqual(pinned.value as? String, wasCollapsed ? "Expanded" : "Collapsed")
        pinned.tap()
        XCTAssertEqual(pinned.value as? String, wasCollapsed ? "Collapsed" : "Expanded")
        // Long-press → Open drills into the folder (reorder lives there).
        pinned.press(forDuration: 0.8)
        app.buttons["Open"].tap()
        XCTAssertTrue(app.navigationBars["Pinned"].waitForExistence(timeout: 5))
        snapshot(app, "pinned-folder")
    }

    func testSendEchoesAndStreamsReply() {
        let app = launch(["-route", "chat:chat-deploy"])
        let input = app.textViews["composer-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        input.typeText("Summarize the launch post in three bullets.")
        app.buttons["composer-send"].tap()
        // Optimistic echo appears immediately, then the host streams a reply.
        let echo = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'You: Summarize the launch post'")).firstMatch
        XCTAssertTrue(echo.waitForExistence(timeout: 3))
        snapshot(app, "streaming")
        // The host's reply lands after the echo and the turn settles.
        let reply = app.staticTexts.matching(identifier: "row-markdown").element(boundBy: 0)
        XCTAssertTrue(reply.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Send message"].waitForExistence(timeout: 30))
        snapshot(app, "reply-complete")
    }

    func testQuestionPanelAnswersAndResumes() {
        let app = launch(["-route", "chat:chat-deploy"])
        let input = app.textViews["composer-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        input.typeText("Pick a tone for the post ?ask")
        app.buttons["composer-send"].tap()
        let option = app.buttons["question-option-0"]
        XCTAssertTrue(option.waitForExistence(timeout: 20))
        snapshot(app, "question")
        option.tap()
        XCTAssertTrue(input.waitForExistence(timeout: 10), "composer returns after answering")
    }

    func testQueueWhileWorking() {
        let app = launch(["-route", "chat:chat-home", "-longreply"], fast: false)
        let input = app.textViews["composer-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        input.typeText("Write a long reply please.")
        app.buttons["composer-send"].tap()
        XCTAssertTrue(app.buttons["Stop response"].waitForExistence(timeout: 5))
        input.typeText("Then add a TL;DR.")
        XCTAssertTrue(app.buttons["Queue message"].waitForExistence(timeout: 2))
        app.buttons["Queue message"].tap()
        XCTAssertTrue(app.buttons["More queue actions"].waitForExistence(timeout: 5))
        snapshot(app, "queued")
        // A second queued message, then the composer put away.
        input.typeText("And link the docs, with a much longer follow-up line that has to wrap or fade somewhere.")
        app.buttons["Queue message"].tap()
        // Regression: a long queued message pushed its row's buttons off the card.
        let second = app.buttons.matching(NSPredicate(format: "label == 'More queue actions'")).element(boundBy: 1)
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        XCTAssertTrue(second.isHittable, "the long row's actions stay on the card")
        XCTAssertLessThanOrEqual(second.frame.maxX, app.windows.firstMatch.frame.maxX)
        snapshot(app, "queued-two")
        app.scrollViews["transcript"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        sleep(1)
        snapshot(app, "queued-resting")
    }

    func testJumpToLatestAfterScrollingUp() {
        let app = launch(["-route", "chat:chat-veil", "-big"])
        let transcript = app.scrollViews["transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 10))
        transcript.swipeDown(velocity: .fast)
        transcript.swipeDown(velocity: .fast)
        let jump = app.buttons["jump-to-latest"]
        XCTAssertTrue(jump.waitForExistence(timeout: 5))
        snapshot(app, "scrolled-up")
        jump.tap()
    }

    func testTabsAndSearch() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Sessions"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        snapshot(app, "settings")
        app.tabBars.buttons["Sessions"].tap()
        XCTAssertTrue(app.navigationBars["Sessions"].waitForExistence(timeout: 5))
    }

    func testNewSessionFromAccessory() {
        let app = launch()
        let accessory = app.buttons["new-session"]
        XCTAssertTrue(accessory.waitForExistence(timeout: 10))
        accessory.tap()
        let input = app.textViews["composer-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        snapshot(app, "new-session")
        input.typeText("Add a dark mode toggle to settings")
        app.buttons["composer-send"].tap()
        XCTAssertTrue(app.scrollViews["transcript"].waitForExistence(timeout: 10), "pushes the new session")
        snapshot(app, "new-session-created")
    }

    func testFileMentionSuggestions() {
        let app = launch(["-route", "chat:chat-deploy"])
        let input = app.textViews["composer-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        input.typeText("Look at @lay")
        let first = app.buttons["mention-0"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        snapshot(app, "mentions")
        first.tap()
        XCTAssertTrue((input.value as? String ?? "").contains("@mod.rs"), "token inserted: \(input.value ?? "")")
    }

    func testArchiveWithUndo() {
        let app = launch()
        let cell = app.cells["session-chat-deploy"]
        XCTAssertTrue(cell.waitForExistence(timeout: 10))
        // Recent sits below the inline sections; bring the row clear of the accessory.
        app.collectionViews.firstMatch.swipeUp()
        cell.swipeLeft()
        app.buttons["Archive"].tap()
        let undo = app.buttons["toast-action"]
        XCTAssertTrue(undo.waitForExistence(timeout: 3))
        snapshot(app, "archive-undo")
        undo.tap()
        XCTAssertTrue(app.cells["session-chat-deploy"].waitForExistence(timeout: 5), "unarchived session returns")
    }

    func testNewProjectFolderBrowser() {
        // New projects are created from the new-session project picker.
        let app = launch(["-route", "new"])
        let chip = app.buttons["composer-chip-project"]
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        chip.tap()
        let add = app.buttons["New Project…"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        let use = app.buttons["use-folder"]
        XCTAssertTrue(use.waitForExistence(timeout: 5))
        let firstFolder = app.collectionViews.cells.element(boundBy: 0)
        XCTAssertTrue(firstFolder.waitForExistence(timeout: 5))
        snapshot(app, "new-project")
        firstFolder.tap()
        XCTAssertTrue(use.waitForExistence(timeout: 5))
        use.tap()
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "sheet dismissed after creating")
        XCTAssertFalse(use.exists)
    }

    func testToolGroupExpandsAndShowsDetail() {
        let app = launch(["-route", "chat:chat-veil"])
        let expand = app.buttons["Expand"].firstMatch
        XCTAssertTrue(expand.waitForExistence(timeout: 10))
        expand.tap()
        let detail = app.buttons["Show details"].firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        snapshot(app, "tools-expanded")
        // Details open inline under the row, like desktop.
        detail.tap()
        XCTAssertTrue(app.buttons["Hide details"].firstMatch.waitForExistence(timeout: 5))
        sleep(1)
        snapshot(app, "tool-detail")
    }

    /// Regression: picking a reasoning effort from the composer chip crashed.
    func testEffortPickerInSession() {
        let app = launch(["-route", "chat:chat-deploy"])
        let input = app.textViews["composer-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        let chip = app.buttons["composer-chip-effort"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        chip.tap()
        let item = app.collectionViews.buttons.element(boundBy: 0)
        XCTAssertTrue(item.waitForExistence(timeout: 5), "effort levels load")
        snapshot(app, "effort-menu")
        item.tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)
        chip.tap()
        XCTAssertTrue(app.collectionViews.buttons.element(boundBy: 0).waitForExistence(timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testEffortPickerInNewSession() {
        let app = launch(["-route", "new"])
        let chip = app.buttons["composer-chip-effort"]
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        chip.tap()
        let item = app.collectionViews.buttons.element(boundBy: 0)
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Regression: "+" in the resting capsule did nothing (the focus tap
    /// morphed the composer under the finger and cancelled the menu).
    func testAttachMenuOpens() {
        for route in [["-route", "chat:chat-deploy"], ["-route", "new"]] {
            let app = launch(route)
            let attach = app.buttons["composer-attach"]
            XCTAssertTrue(attach.waitForExistence(timeout: 10))
            attach.tap()
            XCTAssertTrue(app.buttons["Photo Library"].waitForExistence(timeout: 5), "attach menu opens (\(route))")
            snapshot(app, "attach-menu")
            app.terminate()
        }
        // Card state (focused, with a draft): the toolbar row must not cover "+".
        let app = launch(["-route", "chat:chat-deploy"])
        let input = app.textViews["composer-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        input.typeText("Draft")
        app.buttons["composer-attach"].tap()
        XCTAssertTrue(app.buttons["Photo Library"].waitForExistence(timeout: 5), "attach menu opens from the card")
    }

    /// Regression: the model chip's menu completed off the main thread.
    func testModelPickerInSession() {
        let app = launch(["-route", "chat:chat-deploy"])
        let input = app.textViews["composer-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        let chip = app.buttons["composer-chip-model"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        chip.tap()
        let item = app.collectionViews.buttons.element(boundBy: 0)
        XCTAssertTrue(item.waitForExistence(timeout: 5), "models load")
        item.tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Regression: a drag that starts at the tail re-latched follow at once,
    /// so the list sprang back to the bottom on release while streaming.
    func testScrollingUpWhileStreamingStaysPut() {
        let app = launch(["-route", "chat:chat-veil", "-big", "-longreply"], fast: false)
        let input = app.textViews["composer-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        input.typeText("Walk me through the veil")
        app.buttons["composer-send"].tap()
        let transcript = app.scrollViews["transcript"]
        sleep(2)
        let from = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        from.press(forDuration: 0.05, thenDragTo: transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)), withVelocity: .slow, thenHoldForDuration: 0.1)
        sleep(3)
        XCTAssertTrue(app.buttons["jump-to-latest"].isHittable, "stays scrolled up while the reply streams")
        snapshot(app, "scrolled-up-streaming")
    }

    /// Desktop tool rows: file badges, inline stats/diff detail, thoughts,
    /// and a live group streaming in.
    func testToolGroupsRenderLikeDesktop() {
        let app = launch(["-route", "chat:chat-veil", "-big"])
        let transcript = app.scrollViews["transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 10))
        for _ in 0..<1 {
            let expand = app.buttons["Expand"].firstMatch
            guard expand.exists, expand.isHittable else { break }
            expand.tap()
            sleep(1)
        }
        snapshot(app, "tool-groups")
        let details = app.buttons.matching(identifier: "Show details")
        if details.count > 1 {
            details.element(boundBy: 1).tap()
            sleep(1)
            snapshot(app, "tool-row-detail")
        }
        app.terminate()
        let live = launch(["-route", "chat:chat-home"], fast: false)
        let input = live.textViews["composer-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        input.typeText("Refactor the layout pass")
        live.buttons["composer-send"].tap()
        for k in 0..<6 {
            sleep(1)
            snapshot(live, "live-tools-\(k)")
        }
    }

    /// Regression: a half swipe-back (cancelled) detached the session, so the
    /// streaming reply froze until you left and came back; the cancelled pop
    /// could also leave "New session" showing over the session.
    func testCancelledSwipeBackKeepsStreaming() {
        let app = launch(["-route", "chat:chat-deploy"], fast: false)
        let input = app.textViews["composer-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        input.typeText("Summarize the launch post in three bullets.")
        app.buttons["composer-send"].tap()
        app.keyboards.firstMatch.swipeDown()
        sleep(1)
        // Drag from the left edge a third of the way and let go: the pop cancels.
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)), withVelocity: .slow, thenHoldForDuration: 0.3)
        sleep(1)
        XCTAssertTrue(input.exists, "still on the session")
        XCTAssertFalse(app.buttons["new-session"].isHittable, "no New session accessory over the session")
        // The reply keeps streaming to completion.
        XCTAssertTrue(app.staticTexts.matching(identifier: "row-markdown").element(boundBy: 0).waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["Send message"].waitForExistence(timeout: 40), "turn settles (updates still arriving)")
    }

    /// Tapping the transcript dismisses the keyboard and the composer rests
    /// as the capsule again (a draft stays in it).
    func testTapOutsideMinimizesComposer() {
        let app = launch(["-route", "chat:chat-deploy"])
        let input = app.textViews["composer-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        input.typeText("Half-written thought")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["composer-chip-model"].isHittable, "card toolbar while composing")
        app.scrollViews["transcript"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3), "keyboard dismissed")
        sleep(1)
        XCTAssertFalse(app.buttons["composer-chip-model"].isHittable, "composer rests as the capsule")
        // (The sim keyboard's autocorrect may append to the typed text.)
        XCTAssertTrue((input.value as? String ?? "").hasPrefix("Half-written"), "draft kept")
        snapshot(app, "composer-minimized")
    }
}
