import AppKit
import XCTest

/// UI tests for OpenShokz.
///
/// Default suite uses launch arguments so CI needs neither USB nor network:
/// - `-ui-testing` disables auto-quit on disconnect
/// - `-ui-testing-connected` fakes a Shokz volume (temp dir)
/// - `-ui-testing-disconnected` forces connect-guide UI even if USB is present
/// - `-ui-testing-auto-disconnect` starts connected then flips to disconnected
/// - `-ui-testing-skip-preview` skips remote metadata fetches
///
/// Set `OPENSHOKZ_UITEST_USB=1` to exercise a real mounted Shokz disk.
final class OpenShokzUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Always-safe (no USB / no network)

    func testAppLaunches() throws {
        launchUITesting()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(statusRoot.waitForExistence(timeout: 5))
    }

    func testConnectGuideWhenDisconnected() throws {
        launchUITesting(forceDisconnected: true)
        XCTAssertTrue(statusRoot.waitForExistence(timeout: 5))
        XCTAssertFalse(addButton.exists, "Add should be hidden while disconnected")
        XCTAssertTrue(connectGuide.waitForExistence(timeout: 5))
        XCTAssertTrue(
            statusText.contains("Not connected"),
            "Expected disconnected status label, got: \(statusText)"
        )
    }

    func testAddURLFieldAndSendButtonStayVisible() throws {
        launchUITesting(connected: true, skipPreview: true)
        XCTAssertTrue(addButton.waitForExistence(timeout: 5), "Add (+) should appear when connected")

        addButton.click()

        let field = addURLField
        XCTAssertTrue(field.waitForExistence(timeout: 5), "URL field should appear after opening add")

        // Field sits in the bottom add bar (bottom-anchored chrome).
        let windowFrame = app.windows.firstMatch.frame
        XCTAssertFalse(windowFrame.isEmpty)
        let fieldFrame = field.frame
        XCTAssertGreaterThan(
            fieldFrame.minY - windowFrame.minY,
            windowFrame.height * 0.55,
            "URL field should appear in the bottom add bar"
        )

        field.click()
        field.typeText("https://www.youtube.com/watch?v=dQw4w9WgXcQ")

        let send = sendButton
        XCTAssertTrue(send.waitForExistence(timeout: 3), "Send should appear once the field is non-empty")
        XCTAssertTrue(send.isHittable, "Send must stay hittable (not replaced by loading spinner)")

        // Give the skipped preview path a moment to pulse isLoadingPreview.
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertTrue(send.exists, "Send must remain after preview loading starts")
        XCTAssertTrue(send.isHittable, "Send must remain hittable while loading")
    }

    func testEmptyStateOrListWhenConnected() throws {
        launchUITesting(connected: true, skipPreview: true)
        XCTAssertTrue(statusRoot.waitForExistence(timeout: 5))
        XCTAssertTrue(addButton.waitForExistence(timeout: 5), "Connected chrome should expose +")

        // Mock volume skips the FAT walk; still allow a brief scanning flash.
        let deadline = Date().addingTimeInterval(6)
        var sawLibrarySurface = false
        while Date() < deadline {
            if emptyState.exists || videoList.exists || libraryReadProblem.exists {
                sawLibrarySurface = true
                break
            }
            if libraryScanning.exists {
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                continue
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }

        XCTAssertTrue(
            sawLibrarySurface || emptyState.waitForExistence(timeout: 2) || videoList.exists,
            "Connected UI should settle on empty state, list, or read-problem (got scanning=\(libraryScanning.exists))"
        )
        XCTAssertTrue(
            statusText.contains("OpenSwim"),
            "Expected connected status, got: \(statusText)"
        )
    }

    func testDisconnectUpdatesStatusToNotConnected() throws {
        launchUITesting(connected: true, autoDisconnect: true, skipPreview: true)
        XCTAssertTrue(statusRoot.waitForExistence(timeout: 5))
        XCTAssertTrue(
            addButton.waitForExistence(timeout: 5),
            "Should start connected so disconnect transition is observable"
        )

        // Auto-disconnect flips the mock volume shortly after launch.
        let deadline = Date().addingTimeInterval(9)
        var sawDisconnected = false
        while Date() < deadline {
            if statusText.contains("Not connected") {
                sawDisconnected = true
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        XCTAssertTrue(sawDisconnected, "Status should flip to Not connected after disconnect")
        XCTAssertTrue(connectGuide.waitForExistence(timeout: 3), "Connect guide should appear")
        XCTAssertFalse(addButton.exists, "Add button should hide when disconnected")
    }

    func testDeleteTrackFromSeededMockLibrary() throws {
        launchUITesting(connected: true, skipPreview: true, seedLibrary: true)
        XCTAssertTrue(statusRoot.waitForExistence(timeout: 5))
        XCTAssertTrue(videoList.waitForExistence(timeout: 8), "Seeded mock volume should show the library list")

        let rows = videoRows
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 8), "Seeded tracks should appear")
        let initialCount = rows.count
        XCTAssertGreaterThanOrEqual(initialCount, 1, "Expected at least one seeded track")

        let target = rows.firstMatch
        let deletedTitle = target.label
        XCTAssertFalse(deletedTitle.isEmpty)

        target.rightClick()
        XCTAssertTrue(
            app.menuItems["Open Original"].firstMatch.waitForExistence(timeout: 3),
            "Row context menu should appear after right-click"
        )

        var deleteItem = app.menuItems[AccessibilityID.videoRowDelete].firstMatch
        if !deleteItem.waitForExistence(timeout: 1) {
            // Fallback: disambiguate from system Edit/Delete by requiring hittable + sibling menu.
            deleteItem = app.menuItems.matching(
                NSPredicate(format: "title == %@ AND isHittable == true", "Delete")
            ).firstMatch
        }
        XCTAssertTrue(deleteItem.waitForExistence(timeout: 3), "Delete should appear in the row context menu")
        deleteItem.click()

        // Optimistic UI: row vanishes immediately without freezing.
        let goneDeadline = Date().addingTimeInterval(3)
        while Date() < goneDeadline {
            if rows.count < initialCount { break }
            if !target.exists { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertLessThan(rows.count, initialCount, "Deleted track should disappear from the list immediately")

        // Background delete on the simulated volume (temp dir, not /Volumes).
        let remainingNames = UITestingSupport.mockLibraryFileNames.filter { name in
            mockVolumeCandidates.contains {
                FileManager.default.fileExists(atPath: $0.appendingPathComponent(name).path)
            }
        }
        XCTAssertLessThan(
            remainingNames.count,
            UITestingSupport.mockLibraryFileNames.count,
            "At least one seeded mock file should be removed from the simulated volume"
        )
    }

    func testConnectGuideCopyAndLearnMore() throws {
        launchUITesting(forceDisconnected: true)
        XCTAssertTrue(connectGuide.waitForExistence(timeout: 5))

        // App-wide label lookups: identifier-scoped descendants can be hidden by
        // accessibility flattening inside the guide's combined elements.
        XCTAssertTrue(
            elementWithLabel(containing: "Plug in your Shokz to load videos and podcasts")
                .waitForExistence(timeout: 3),
            "Connect guide subtitle should be visible"
        )
        XCTAssertFalse(elementWithLabel(containing: "over USB").exists)

        XCTAssertTrue(
            elementWithLabel(containing: "Connect to get started").waitForExistence(timeout: 3)
        )
        XCTAssertTrue(elementWithLabel(containing: "Attach the magnetic charging cable").exists)
        XCTAssertTrue(elementWithLabel(containing: "Plug the USB end into your Mac").exists)
        XCTAssertTrue(
            elementWithLabel(containing: "Wait for the disk to appear (e.g. OpenSwim, SWIM PRO)").exists
        )

        var learnMore = connectGuideLearnMore
        if !learnMore.waitForExistence(timeout: 3) {
            learnMore = elementWithLabel(containing: "Learn more")
        }
        XCTAssertTrue(learnMore.waitForExistence(timeout: 3))
        XCTAssertTrue(learnMore.label.localizedCaseInsensitiveContains("Learn more"))

        // Regression: the link grabbed the window's initial key focus and
        // rendered a highlight on every launch.
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let isFocused = (learnMore.value(forKey: "hasKeyboardFocus") as? Bool) ?? false
        XCTAssertFalse(
            isFocused,
            "Learn more must not be focused/highlighted by default on launch"
        )
    }

    func testAddBarHasNoCloseButton() throws {
        launchUITesting(connected: true, skipPreview: true)
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.click()
        XCTAssertTrue(addURLField.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons[AccessibilityID.addBarCloseButton].exists)
        XCTAssertTrue(sendButton.waitForExistence(timeout: 2))
    }

    func testAddBarDismissesOnEscapeAndClearsField() throws {
        launchUITesting(connected: true, skipPreview: true)
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.click()
        let field = addURLField
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeText("https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        XCTAssertTrue(sendButton.waitForExistence(timeout: 3))

        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))

        XCTAssertTrue(addButton.waitForExistence(timeout: 3))
        XCTAssertFalse(addURLField.exists)

        addButton.click()
        XCTAssertTrue(addURLField.waitForExistence(timeout: 3))
        let clearedValue = addURLField.value as? String ?? ""
        XCTAssertTrue(
            clearedValue.isEmpty || clearedValue == "Paste a video or podcast link",
            "Field should be empty after Esc, got: \(clearedValue)"
        )
    }

    func testEmptyStateWhenConnectedWithoutTracks() throws {
        launchUITesting(connected: true, skipPreview: true)
        XCTAssertTrue(statusRoot.waitForExistence(timeout: 5))
        XCTAssertTrue(emptyState.waitForExistence(timeout: 8))
        // The title Text overrides its accessibility label to "No videos", so
        // match by label content rather than the visual string.
        XCTAssertTrue(
            elementWithLabel(containing: "No videos").waitForExistence(timeout: 3)
        )
        XCTAssertTrue(elementWithLabel(containing: "Tap + to add a video or podcast").exists)
    }

    func testSeededLibraryShowsVideoList() throws {
        launchUITesting(connected: true, skipPreview: true, seedLibrary: true)
        XCTAssertTrue(statusRoot.waitForExistence(timeout: 5))
        XCTAssertTrue(videoList.waitForExistence(timeout: 8))
        XCTAssertGreaterThanOrEqual(videoRows.count, 1)
    }

    func testAddBarOpensWithVisibleField() throws {
        launchUITesting(connected: true, skipPreview: true)
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.click()
        XCTAssertTrue(addURLField.waitForExistence(timeout: 3), "Add field should appear quickly (fade-in)")
    }

    // MARK: - Reliability: instant paint, reconnect, delete persistence

    /// Sandbox: a connected volume without its one-time grant shows the grant
    /// guide (and hides the add chrome) until access is approved.
    func testGrantAccessGuideAppearsWhenSandboxBlocksVolume() throws {
        launchUITesting(connected: true, skipPreview: true, needsGrant: true)
        XCTAssertTrue(statusRoot.waitForExistence(timeout: 5))
        XCTAssertTrue(grantAccess.waitForExistence(timeout: 5), "Grant guide should appear")
        // Parent identifiers propagate over children on current macOS — find
        // the button by its label.
        XCTAssertTrue(
            elementWithLabel(containing: "Grant Access…").waitForExistence(timeout: 3),
            "Grant Access button should be present"
        )
        XCTAssertFalse(addButton.exists, "Add chrome hides until access is granted")
        XCTAssertTrue(
            statusText.contains("OpenSwim"),
            "Device still reads as connected while awaiting the grant"
        )
    }

    /// The library must render from the persistent cache immediately — long
    /// before a slow (6s simulated) USB listing returns.
    func testLibraryPaintsFromCacheBeforeListingCompletes() throws {
        launchUITesting(
            connected: true,
            skipPreview: true,
            seedLibrary: true,
            seedCache: true,
            slowListing: true
        )
        XCTAssertTrue(statusRoot.waitForExistence(timeout: 5))
        XCTAssertTrue(addButton.waitForExistence(timeout: 5), "Connected chrome should appear")

        // Deadline is well under the simulated 6s listing delay: rows on screen
        // now can only have come from the cache paint.
        XCTAssertTrue(
            videoRows.firstMatch.waitForExistence(timeout: 4),
            "Cached rows must paint before the slow listing completes"
        )
        XCTAssertGreaterThanOrEqual(videoRows.count, 1)
        let titles = (0..<videoRows.count).map { videoRows.element(boundBy: $0).label }
        XCTAssertTrue(
            titles.contains { $0.contains("Devin AI Guide") },
            "Cache-painted row should show the parsed title, got: \(titles)"
        )
    }

    /// Yank + replug: status flips both ways and the library repaints from
    /// cache immediately on reconnect, while the slow listing is still running.
    func testReconnectRepaintsLibraryInstantly() throws {
        launchUITesting(
            connected: true,
            autoDisconnect: true,
            autoReconnect: true,
            skipPreview: true,
            seedLibrary: true,
            seedCache: true,
            slowListing: true
        )
        XCTAssertTrue(statusRoot.waitForExistence(timeout: 5))

        // Phase 1: simulated yank ~4s after launch.
        var sawDisconnected = false
        let disconnectDeadline = Date().addingTimeInterval(9)
        while Date() < disconnectDeadline {
            if statusText.contains("Not connected") {
                sawDisconnected = true
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(sawDisconnected, "Status should flip to Not connected on the yank")

        // Phase 2: simulated replug ~800ms later. Rows must be back well before
        // the 6s listing completes — that is the cache repaint.
        XCTAssertTrue(
            addButton.waitForExistence(timeout: 4),
            "Reconnect should restore connected chrome quickly"
        )
        XCTAssertTrue(
            videoRows.firstMatch.waitForExistence(timeout: 4),
            "Library must repaint from cache immediately on reconnect"
        )
    }

    /// A deleted row must never resurrect — not from a later listing pass and
    /// not from the persistent cache.
    func testDeletedTrackDoesNotResurrect() throws {
        launchUITesting(connected: true, skipPreview: true, seedLibrary: true, seedCache: true)
        XCTAssertTrue(videoList.waitForExistence(timeout: 8))
        let rows = videoRows
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 8))
        let initialCount = rows.count
        XCTAssertGreaterThanOrEqual(initialCount, 1)

        let target = rows.firstMatch
        target.rightClick()
        XCTAssertTrue(
            app.menuItems["Open Original"].firstMatch.waitForExistence(timeout: 3)
        )
        var deleteItem = app.menuItems[AccessibilityID.videoRowDelete].firstMatch
        if !deleteItem.waitForExistence(timeout: 1) {
            deleteItem = app.menuItems.matching(
                NSPredicate(format: "title == %@ AND isHittable == true", "Delete")
            ).firstMatch
        }
        XCTAssertTrue(deleteItem.waitForExistence(timeout: 3))
        deleteItem.click()

        let goneDeadline = Date().addingTimeInterval(3)
        while Date() < goneDeadline {
            if rows.count < initialCount { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertLessThan(rows.count, initialCount, "Row should vanish optimistically")

        // Reliability window: any stray rescan or cache repaint would restore
        // the row within a few seconds — it must stay gone.
        RunLoop.current.run(until: Date().addingTimeInterval(3.0))
        XCTAssertLessThan(
            rows.count,
            initialCount,
            "Deleted track must not resurrect from listing or cache"
        )
    }

    /// The connected empty state still renders (no cache, no files) — guards
    /// against the cache layer inventing rows.
    func testEmptyVolumeShowsEmptyStateNotGhostRows() throws {
        launchUITesting(connected: true, skipPreview: true)
        XCTAssertTrue(statusRoot.waitForExistence(timeout: 5))
        XCTAssertTrue(emptyState.waitForExistence(timeout: 8))
        XCTAssertEqual(videoRows.count, 0, "No cache seed and no files → no rows, ever")
    }

    /// Closing the window quits the app entirely (widget-style behavior).
    func testCloseButtonQuitsApp() throws {
        launchUITesting(forceDisconnected: true)
        XCTAssertTrue(statusRoot.waitForExistence(timeout: 5))

        let close = app.windows.firstMatch.buttons[XCUIIdentifierCloseWindow]
        XCTAssertTrue(close.waitForExistence(timeout: 3))
        close.click()

        XCTAssertTrue(
            app.wait(for: .notRunning, timeout: 5),
            "App should terminate when its window closes"
        )
    }

    // MARK: - Optional real device

    func testRealUSBConnectedStatus() throws {
        try requireRealUSB()
        launchUITesting()
        XCTAssertTrue(statusRoot.waitForExistence(timeout: 5))
        XCTAssertTrue(
            addButton.waitForExistence(timeout: 8),
            "Real Shokz disk should expose the add button"
        )
    }

    // MARK: - Helpers

    private func launchUITesting(
        connected: Bool = false,
        forceDisconnected: Bool = false,
        autoDisconnect: Bool = false,
        autoReconnect: Bool = false,
        skipPreview: Bool = false,
        seedLibrary: Bool = false,
        seedCache: Bool = false,
        slowListing: Bool = false,
        needsGrant: Bool = false
    ) {
        // Avoid openAddBar auto-pasting a media URL from the host clipboard.
        NSPasteboard.general.clearContents()

        var args = [UITestingSupport.uiTestingArgument]
        if connected {
            args.append(UITestingSupport.connectedArgument)
        }
        if forceDisconnected {
            args.append(UITestingSupport.disconnectedArgument)
        }
        if autoDisconnect {
            args.append(UITestingSupport.autoDisconnectArgument)
        }
        if autoReconnect {
            args.append(UITestingSupport.autoReconnectArgument)
        }
        if skipPreview {
            args.append(UITestingSupport.skipPreviewArgument)
        }
        if seedLibrary {
            args.append(UITestingSupport.seedLibraryArgument)
        }
        if seedCache {
            args.append(UITestingSupport.seedCacheArgument)
        }
        if slowListing {
            args.append(UITestingSupport.slowListingArgument)
        }
        if needsGrant {
            args.append(UITestingSupport.needsGrantArgument)
        }
        app.launchArguments = args
        app.launch()
    }

    private func requireRealUSB() throws {
        let enabled = ProcessInfo.processInfo.environment["OPENSHOKZ_UITEST_USB"] == "1"
        if !enabled {
            throw XCTSkip("Set OPENSHOKZ_UITEST_USB=1 with a mounted Shokz disk to run this test")
        }
    }

    private var statusRoot: XCUIElement { app.descendants(matching: .any)[AccessibilityID.statusRoot] }
    private var statusLabel: XCUIElement { app.descendants(matching: .any)[AccessibilityID.statusLabel] }

    /// Combined status text, tolerant of either element being flattened away.
    private var statusText: String {
        if statusRoot.exists { return statusRoot.label }
        if statusLabel.exists { return statusLabel.label }
        return ""
    }

    /// App-wide lookup by accessibility text. SwiftUI Texts surface their
    /// string via `value` (with `label` empty) on current macOS, and parent
    /// identifiers propagate over children — so match either attribute
    /// app-wide instead of identifier-scoped descendants.
    private func elementWithLabel(containing text: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text))
            .firstMatch
    }
    private var addButton: XCUIElement { app.buttons[AccessibilityID.addButton] }
    private var addURLField: XCUIElement {
        let field = app.textFields[AccessibilityID.addURLField]
        if field.exists { return field }
        return app.descendants(matching: .any)[AccessibilityID.addURLField]
    }
    private var sendButton: XCUIElement { app.buttons[AccessibilityID.sendButton] }
    private var emptyState: XCUIElement { app.descendants(matching: .any)[AccessibilityID.emptyState] }
    private var videoList: XCUIElement { app.descendants(matching: .any)[AccessibilityID.videoList] }
    private var libraryScanning: XCUIElement {
        app.descendants(matching: .any)[AccessibilityID.libraryScanning]
    }
    private var libraryReadProblem: XCUIElement {
        app.descendants(matching: .any)[AccessibilityID.libraryReadProblem]
    }
    private var connectGuide: XCUIElement { app.descendants(matching: .any)[AccessibilityID.connectGuide] }
    private var connectGuideSubtitle: XCUIElement {
        connectGuide.descendants(matching: .any)[AccessibilityID.connectGuideSubtitle]
    }
    private var connectGuideLearnMore: XCUIElement {
        connectGuide.descendants(matching: .any)[AccessibilityID.connectGuideLearnMore]
    }
    private var grantAccess: XCUIElement { app.descendants(matching: .any)[AccessibilityID.grantAccess] }
    private var videoRows: XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: AccessibilityID.videoRow)
    }

    /// The sandboxed app's mock volume lives in its container temp dir; the
    /// (unsandboxed) runner checks both candidates.
    private var mockVolumeCandidates: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(
                "Library/Containers/app.openshokz.OpenShokz/Data/tmp/OpenShokzUITestVolume",
                isDirectory: true
            ),
            FileManager.default.temporaryDirectory
                .appendingPathComponent("OpenShokzUITestVolume", isDirectory: true)
        ]
    }
}

/// Mirror of app-side identifiers / launch args (UI test bundle cannot import the app module).
private enum AccessibilityID {
    static let statusRoot = "statusRoot"
    static let statusLabel = "statusLabel"
    static let addButton = "addButton"
    static let addURLField = "addURLField"
    static let sendButton = "sendButton"
    static let videoList = "videoList"
    static let emptyState = "emptyState"
    static let libraryScanning = "libraryScanning"
    static let libraryReadProblem = "libraryReadProblem"
    static let connectGuide = "connectGuide"
    static let connectGuideLearnMore = "connectGuideLearnMore"
    static let connectGuideSubtitle = "connectGuideSubtitle"
    static let videoRow = "videoRow"
    static let videoRowDelete = "videoRowDelete"
    static let grantAccess = "grantAccess"
    static let addBarCloseButton = "addBarCloseButton"
}

private enum UITestingSupport {
    static let uiTestingArgument = "-ui-testing"
    static let connectedArgument = "-ui-testing-connected"
    static let disconnectedArgument = "-ui-testing-disconnected"
    static let autoDisconnectArgument = "-ui-testing-auto-disconnect"
    static let autoReconnectArgument = "-ui-testing-auto-reconnect"
    static let skipPreviewArgument = "-ui-testing-skip-preview"
    static let seedLibraryArgument = "-ui-testing-seed-library"
    static let seedCacheArgument = "-ui-testing-seed-cache"
    static let slowListingArgument = "-ui-testing-slow-listing"
    static let needsGrantArgument = "-ui-testing-needs-grant"

    static let mockLibraryFileNames: [String] = [
        "Devin AI Guide [Vyyrvna-hUY].m4a",
        "Training Composer 2 [uTgqYeVxy2c].mp3"
    ]
}
