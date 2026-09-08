//
//  flight_loggerUITestsLaunchTests.swift
//  flight-loggerUITests
//
//  Created by august huber on 4/4/26.
//

import XCTest

final class flight_loggerUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        // See flight_loggerUITests: an active recording session keeps the app
        // alive between tests, and `launch()` fails against a lingering
        // background instance.
        Self.terminateAndWait()
    }

    override func tearDownWithError() throws {
        Self.terminateAndWait()
    }

    /// Terminate and *wait for it to actually stop*.
    ///
    /// `terminate()` returns before the process is gone, and a recording
    /// session keeps this app alive on purpose — the location keep-alive and
    /// liveness task are doing their job. Without the wait, the next `launch()`
    /// races a still-dying instance and fails with "current state: Running
    /// Background". Assuming terminate() was synchronous is what made these
    /// tests flaky rather than fixed the first time.
    static func terminateAndWait(timeout: TimeInterval = 15) {
        let app = XCUIApplication()
        guard app.state != .notRunning else { return }
        app.terminate()
        _ = app.wait(for: .notRunning, timeout: timeout)
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launch()

        // Insert steps here to perform after app launch but before taking a screenshot,
        // such as logging into a test account or navigating somewhere in the app
        // XCUIAutomation Documentation
        // https://developer.apple.com/documentation/xcuiautomation

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
