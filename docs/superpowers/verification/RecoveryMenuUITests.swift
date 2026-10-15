import XCTest

@MainActor final class RecoveryMenuUITests: XCTestCase {
    private var app: XCUIApplication!
    private var output: URL!
    override func setUp() async throws {
        continueAfterFailure = false
        output = FileManager.default.temporaryDirectory.appendingPathComponent("BopifyRecoveryMenuUI-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        app = XCUIApplication(url: URL(fileURLWithPath: ProcessInfo.processInfo.environment["MENU_APP"]!))
        app.launchArguments = ["--output", output.path]
    }
    override func tearDown() async throws {
        app?.terminate()
        if let data = try? Data(contentsOf: output.appendingPathComponent("state.json")) {
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "final-action-counts"; attachment.lifetime = .keepAlways; add(attachment)
        }
    }
    private func launch(integrated: Bool = false) {
        if integrated { app.launchArguments.append("--integrated") }
        app.launch()
        app.activate()
        XCTAssertTrue(app.dialogs["Recovery Menu Test"].waitForExistence(timeout: 5))
    }
    private func state() -> [String: Any] {
        guard let data = try? Data(contentsOf: output.appendingPathComponent("state.json")),
            let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }
    private func wait(_ predicate: @escaping () -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in MainActor.assumeIsolated { predicate() } }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }
    private func command(_ value: String) throws {
        try value.write(to: output.appendingPathComponent("command.txt"), atomically: true, encoding: .utf8)
        wait { self.state()["command"] as? String == value }
    }
    private var menu: XCUIElement { app.descendants(matching: .menuButton).firstMatch }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.dialogs["Recovery Menu Test"].screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func captureMenu(_ explanation: String, _ name: String) {
        let presented = app.menus.containing(NSPredicate(format: "title == %@ OR label == %@", explanation, explanation)).firstMatch
        XCTAssertTrue(presented.exists)
        let attachment = XCTAttachment(screenshot: presented.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testMouseSelectionDispatchesOnlyExpectedRecovery() throws {
        launch()
        for (status, label, retries, reconnects, explanation) in [
            ("offline", "Retry now", 1, 0, "You're offline"),
            ("restoration", "Retry restoration", 2, 0, "Playback couldn't be restored."),
            ("reauthentication", "Reconnect Spotify", 2, 1, "Reconnect Spotify"),
            ("corrupt", "Reconnect Spotify", 2, 2, "Your saved sign-in couldn’t be read. Sign in again to replace it."),
            ("credentials", "Retry saved sign-in", 3, 2, "Bopify couldn’t save your sign-in. Check Keychain access, then try again.")] {
            app.activate()
            try command(status)
            XCTAssertTrue(menu.waitForExistence(timeout: 3))
            let attributes = try menu.snapshot().dictionaryRepresentation
            XCTAssertTrue([attributes[.title] as? String, attributes[.label] as? String].contains(explanation), "Exported menu name must contain the full explanation")
            capture(status + "-closed")
            menu.click()
            let action = app.menuItems[label]
            XCTAssertTrue(action.waitForExistence(timeout: 3))
            XCTAssertTrue(app.menuItems.matching(NSPredicate(format: "title == %@ OR label == %@", explanation, explanation)).firstMatch.exists)
            captureMenu(explanation, status + "-menu")
            action.click()
            wait { self.state()["retries"] as? Int == retries && self.state()["reconnects"] as? Int == reconnects }
        }
    }
    func testKeyboardSelectionAndEscape() throws {
        launch()
        menu.click()
        app.typeKey(.escape, modifierFlags: [])
        wait { !self.app.menuItems["Retry now"].exists }
        XCTAssertEqual(state()["retries"] as? Int, 0)
        XCTAssertEqual(state()["reconnects"] as? Int, 0)
        menu.click()
        XCTAssertTrue(app.menuItems["Retry now"].waitForExistence(timeout: 3))
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        wait { self.state()["retries"] as? Int == 1 }
        XCTAssertEqual(state()["reconnects"] as? Int, 0)
    }
    func testKeyboardOpeningWhenNavigationEnabled() throws {
        launch()
        guard state()["keyboardNavigationEnabled"] as? Bool == true else {
            throw XCTSkip("All-controls keyboard navigation is disabled; its system preference is not changed by this test")
        }
        app.dialogs["Recovery Menu Test"].typeKey(.tab, modifierFlags: [])
        let attributes = try menu.snapshot().dictionaryRepresentation
        XCTAssertEqual(attributes[.hasFocus] as? Bool, true)
        menu.typeKey(.space, modifierFlags: [])
        XCTAssertTrue(app.menuItems["Retry now"].waitForExistence(timeout: 3))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(state()["retries"] as? Int, 0)
    }
    func testOutsideDismissalDoesNotRecover() throws {
        launch()
        menu.click()
        XCTAssertTrue(app.menuItems["Retry now"].waitForExistence(timeout: 3))
        app.dialogs["Recovery Menu Test"].coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.1)).click()
        wait { !self.app.menuItems["Retry now"].exists }
        XCTAssertEqual(state()["retries"] as? Int, 0)
        XCTAssertEqual(state()["reconnects"] as? Int, 0)
    }
    private func recordState(_ name: String) throws {
        let data = try Data(contentsOf: output.appendingPathComponent("state.json"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testStateChangesCannotReinterpretPendingRetry() throws {
        launch()
        menu.click()
        let retry = app.menuItems["Retry now"]
        XCTAssertTrue(retry.waitForExistence(timeout: 3))
        wait { self.state()["menuOpen"] as? Bool == true }
        let frame = retry.frame, dialog = app.dialogs["Recovery Menu Test"]
        let origin = dialog.frame.origin
        let pendingPoint = dialog.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX - origin.x, dy: frame.midY - origin.y))
        try recordState("retry-tracking-before-change")
        try command("reauthentication")
        let updated = app.descendants(matching: .menuButton).matching(NSPredicate(format: "title == %@ OR label == %@", "Reconnect Spotify", "Reconnect Spotify")).firstMatch
        XCTAssertTrue(updated.waitForExistence(timeout: 3))
        let revision = state()["snapshotNumber"] as! Int
        wait { (self.state()["snapshotNumber"] as? Int ?? 0) > revision }
        if state()["menuOpen"] as? Bool == true {
            let titles = state()["menuTitles"] as! [String]
            XCTAssertTrue(titles.contains("Retry now"), "A pending retry must keep its original command")
            XCTAssertFalse(titles.contains("Reconnect Spotify"), "Authorization must not replace retry under the pointer")
            try recordState("original-retry-retained-after-action-change")
            pendingPoint.click()
            wait { self.state()["menuOpen"] as? Bool == false }
        } else {
            try recordState("retry-automatically-dismissed-after-action-change")
        }
        XCTAssertEqual(state()["reconnects"] as? Int, 0)
        XCTAssertTrue((state()["retries"] as? Int ?? -1) <= 1)
    }
    func testRecoveredConnectionDoesNotReplacePendingReconnect() throws {
        launch()
        try command("reauthentication")
        menu.click()
        let reconnect = app.menuItems["Reconnect Spotify"]
        XCTAssertTrue(reconnect.waitForExistence(timeout: 3))
        wait { self.state()["menuOpen"] as? Bool == true }
        let frame = reconnect.frame, dialog = app.dialogs["Recovery Menu Test"]
        let origin = dialog.frame.origin
        let pendingPoint = dialog.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX - origin.x, dy: frame.midY - origin.y))
        try command("ready")
        wait { !self.menu.exists }
        if state()["menuOpen"] as? Bool == true {
            XCTAssertEqual(state()["menuTitles"] as? [String], ["Reconnect Spotify"])
            try recordState("original-reconnect-retained-after-ready")
            pendingPoint.click()
            wait { self.state()["menuOpen"] as? Bool == false }
        }
        // The headless AppEnvironment regression separately proves recovered/signed-out callbacks cannot authorize.
        XCTAssertEqual(state()["retries"] as? Int, 0)
        XCTAssertTrue((state()["reconnects"] as? Int ?? -1) <= 1)
        try recordState("pending-reconnect-finished-after-ready")
    }
    func testPendingRetryStaysRetryWhenActionIsUnchanged() throws {
        launch()
        menu.click()
        XCTAssertTrue(app.menuItems["Retry now"].waitForExistence(timeout: 3))
        wait { self.state()["menuOpen"] as? Bool == true }
        try command("reconnecting")
        XCTAssertTrue(app.menuItems["Retry now"].exists)
        app.menuItems["Retry now"].click()
        wait { self.state()["retries"] as? Int == 1 }
        XCTAssertEqual(state()["reconnects"] as? Int, 0)
        try recordState("unchanged-action-selected-once")
    }
    func testPermanentAndLongestExplanation() throws {
        launch()
        for (status, explanation) in [
            ("permanent", "A Spotify Premium account is required."),
            ("long", "Bopify stopped playback, but could not save your sign-out request. Saved sign-in may return after restarting. Check free disk space and file access, then retry removal.")] {
            try command(status)
            menu.click()
            XCTAssertFalse(app.menuItems["Retry now"].exists)
            XCTAssertFalse(app.menuItems["Reconnect Spotify"].exists)
            XCTAssertTrue(app.menuItems.matching(NSPredicate(format: "title == %@ OR label == %@", explanation, explanation)).firstMatch.exists)
            XCTAssertFalse(app.menuItems.matching(NSPredicate(format: "title == %@ OR label == %@", explanation, explanation)).firstMatch.isEnabled)
            captureMenu(explanation, status + "-menu")
            app.typeKey(.escape, modifierFlags: [])
        }
        XCTAssertEqual(state()["retries"] as? Int, 0)
        XCTAssertEqual(state()["reconnects"] as? Int, 0)
    }
    func testRealPanelFocusExpandsAndKeepsRecoveryReachable() throws {
        launch(integrated: true)
        wait { self.state()["mode"] as? String == "expanded" }
        XCTAssertFalse(menu.exists)
        let retry = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Retry now")).firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 3))
        retry.click()
        wait { self.state()["retries"] as? Int == 1 }
        capture("expanded-recovery")
    }
}
