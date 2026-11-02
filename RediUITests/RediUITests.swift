import XCTest

/// Smoke flows through the real app against a live Redis server. Run them with
/// `Scripts/ui-test-fixture.sh`, which starts a throwaway server with the fixture keys and passes
/// its port as `REDI_UI_TEST_PORT`.
///
/// The app runs with a throwaway data directory and in-memory secrets, so tests never touch the
/// user's saved connections or Keychain.
final class RediUITests: XCTestCase {
    private var app: XCUIApplication!
    private var port: String { ProcessInfo.processInfo.environment["REDI_UI_TEST_PORT"] ?? "6379" }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        let dataDirectory = FileManager.default.temporaryDirectory.appending(path: "redi-ui-\(UUID().uuidString)")
        app.launchEnvironment["REDI_DATA_DIR"] = dataDirectory.path
        app.launchEnvironment["REDI_IN_MEMORY_SECRETS"] = "1"
        // Start clean: don't restore windows from earlier runs.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
    }

    /// Captures only Redi's frontmost window, never the rest of the screen.
    private func screenshot(_ name: String) {
        let window = app.windows.firstMatch
        guard window.exists else { return }
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Creates a connection to the test server and returns its workspace window.
    private func connect(name: String = "UI Test") -> XCUIElement {
        let connections = app.windows["Connections"]
        XCTAssertTrue(connections.waitForExistence(timeout: 5), "Connections window should open at launch")
        connections.buttons["New Connection…"].firstMatch.click()

        let sheet = connections.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "Connection editor sheet should open")
        let nameField = sheet.textFields["connection.name"]
        nameField.click()
        nameField.typeText(name)
        let portField = sheet.textFields["connection.port"]
        portField.click()
        portField.typeKey("a", modifierFlags: .command)
        portField.typeText(port + "\t")
        screenshot("Connection editor")
        sheet.buttons["connection.save"].click()

        // The window title includes the subtitle ("UI Test – Redis 8.x · standalone · db0").
        let workspace = app.windows.matching(NSPredicate(format: "title BEGINSWITH %@", name)).firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: 5), "Workspace window should open")
        return workspace
    }

    @MainActor
    func testBrowseAndInspectKeys() throws {
        let workspace = connect()
        // Keys appear (the tree view groups the fixture's "ui:" namespace).
        XCTAssertTrue(workspace.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'ui'")).firstMatch.waitForExistence(timeout: 5))
        screenshot("Browser tree")

        let filter = workspace.textFields["browser.filter"]
        filter.click()
        filter.typeText("ui:hash\r")
        let row = workspace.staticTexts["ui:hash"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Exact-name filter should find the key")
        row.click()
        XCTAssertTrue(workspace.staticTexts["field-1"].waitForExistence(timeout: 5), "Hash fields should load in the detail pane")
        screenshot("Hash detail")

        filter.click()
        filter.typeKey("a", modifierFlags: .command)
        filter.typeText("ui:stream\r")
        let streamRow = workspace.staticTexts["ui:stream"].firstMatch
        XCTAssertTrue(streamRow.waitForExistence(timeout: 5))
        streamRow.click()
        XCTAssertTrue(workspace.staticTexts["1-1"].waitForExistence(timeout: 5), "Stream entries should load")
        screenshot("Stream detail")
    }

    /// MessagePack values (encoded by a Go service with vmihailenco/msgpack) show decoded.
    @MainActor
    func testMessagePackValues() throws {
        let workspace = connect(name: "MessagePack Test")
        let filter = workspace.textFields["browser.filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
        filter.click()
        filter.typeText("ui:msgpack\r")
        let stringRow = workspace.staticTexts["ui:msgpack"].firstMatch
        XCTAssertTrue(stringRow.waitForExistence(timeout: 5))
        stringRow.click()
        let decoded = workspace.textViews.matching(NSPredicate(format: "value CONTAINS %@", "\"created\": timestamp(2023-11-14T22:13:20Z)"))
        XCTAssertTrue(decoded.firstMatch.waitForExistence(timeout: 5), "The string should be detected as MessagePack and decoded")
        XCTAssertTrue(workspace.popUpButtons.matching(NSPredicate(format: "value == 'Automatic (MessagePack)'")).firstMatch.exists)
        screenshot("MessagePack string")

        filter.click()
        filter.typeKey("a", modifierFlags: .command)
        filter.typeText("ui:msgpack-hash\r")
        let hashRow = workspace.staticTexts["ui:msgpack-hash"].firstMatch
        XCTAssertTrue(hashRow.waitForExistence(timeout: 5))
        hashRow.click()
        let cell = workspace.staticTexts[#"{"sku": "A-1", "qty": 2, "price": 9.99}"#]
        XCTAssertTrue(cell.waitForExistence(timeout: 5), "Hash values should show decoded")
        XCTAssertTrue(workspace.staticTexts["plain text"].exists, "Text values in the same hash stay as they are")
        screenshot("MessagePack hash")

        cell.doubleClick()
        let note = workspace.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'Decoded from MessagePack'")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 5), "The editor should show the value decoded and read-only")
        screenshot("MessagePack field editor")
        workspace.sheets.firstMatch.buttons["Cancel"].click()
    }

    private func open(_ item: String, in workspace: XCUIElement) {
        let row = workspace.outlines.staticTexts[item]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Sidebar item \(item)")
        row.click()
    }

    @MainActor
    func testCLIAndWorkbench() throws {
        let workspace = connect(name: "Console Test")
        workspace.buttons["Bottom Panel"].click()
        let input = workspace.textFields["cli.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.click()
        input.typeText("SET ui:cli \"hello from the CLI\"\r")
        input.typeText("GET ui:cli\r")
        let console = workspace.textViews.firstMatch
        let predicate = NSPredicate(format: "value CONTAINS %@", "hello from the CLI")
        expectation(for: predicate, evaluatedWith: console)
        waitForExpectations(timeout: 5)
        screenshot("CLI")

        open("Workbench", in: workspace)
        let editor = workspace.textViews["workbench.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText("HGETALL ui:hash\nZRANGE ui:zset 0 -1 WITHSCORES")
        workspace.buttons["workbench.run"].click()
        XCTAssertTrue(workspace.staticTexts.matching(NSPredicate(format: "value CONTAINS 'field-1'")).firstMatch.waitForExistence(timeout: 5))
        screenshot("Workbench")
    }

    @MainActor
    func testPubSubAndAnalysis() throws {
        let workspace = connect(name: "Analysis Test")

        open("Pub/Sub", in: workspace)
        let channels = workspace.textFields["pubsub.subscriptions"]
        XCTAssertTrue(channels.waitForExistence(timeout: 5))
        channels.click()
        channels.typeText("news, alerts.*\r")
        let channel = workspace.textFields["pubsub.channel"]
        channel.click()
        channel.typeText("alerts.disk")
        let message = workspace.textFields["pubsub.message"]
        message.click()
        message.typeText("disk almost full\r")
        XCTAssertTrue(workspace.staticTexts["disk almost full"].waitForExistence(timeout: 5), "Published message should be received")
        screenshot("Pub/Sub")

        open("Overview", in: workspace)
        XCTAssertTrue(workspace.staticTexts["Operations per second"].waitForExistence(timeout: 10))
        sleep(3)
        screenshot("Overview")

        open("Slow Log", in: workspace)
        sleep(1)
        screenshot("Slow Log")

        open("Database Analysis", in: workspace)
        let analyze = workspace.buttons["Analyze"].firstMatch
        XCTAssertTrue(analyze.waitForExistence(timeout: 5))
        analyze.click()
        sleep(2)
        screenshot("Database Analysis")
        XCTAssertTrue(workspace.staticTexts["Memory by type"].waitForExistence(timeout: 15), "The analysis report should appear")
    }

    /// Scans a large keyspace end to end. Run with `REDI_PERF_PORT` pointing at a seeded server
    /// (e.g. `Scripts/seed.sh 1000000 6397`); skipped otherwise. Holds the window open afterwards so
    /// the app's footprint can be sampled externally.
    @MainActor
    func testScanAllLargeKeyspace() throws {
        guard let perfPort = ProcessInfo.processInfo.environment["REDI_PERF_PORT"] else {
            throw XCTSkip("Set REDI_PERF_PORT to run the large-keyspace scan.")
        }
        let connections = app.windows["Connections"]
        XCTAssertTrue(connections.waitForExistence(timeout: 5))
        connections.buttons["New Connection…"].firstMatch.click()
        let sheet = connections.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        let portField = sheet.textFields["connection.port"]
        portField.click()
        portField.typeKey("a", modifierFlags: .command)
        portField.typeText(perfPort + "\t")
        let nameField = sheet.textFields["connection.name"]
        nameField.click()
        nameField.typeText("Perf")
        sheet.buttons["connection.save"].click()
        let workspace = app.windows.matching(NSPredicate(format: "title BEGINSWITH 'Perf'")).firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: 10))

        let scanAll = workspace.buttons["Scan All"]
        XCTAssertTrue(scanAll.waitForExistence(timeout: 10))
        let started = Date()
        scanAll.click()
        let done = workspace.staticTexts.matching(NSPredicate(format: "value MATCHES '^([0-9,]+) of \\\\1 keys$'")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 300), "Scan All should finish")
        print("PERF: scanned everything in \(Date().timeIntervalSince(started)) s; status: \(done.value ?? "")")
        screenshot("Large keyspace")
        sleep(25)
    }

    @MainActor
    func testLaunchPerformance() throws {
        app.terminate()
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            app.launch()
        }
    }
}
