//
//  flight_loggerUITests.swift
//  flight-loggerUITests
//
//  Created by august huber on 4/4/26.
//

import XCTest

final class flight_loggerUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false

        // The app keeps running after a test ends whenever a recording session
        // is active — the location keep-alive and liveness task are doing
        // exactly what they're designed to do. `launch()` then fails with
        // "current state: Running Background", so start every test from a known
        // state. `terminate()` is a no-op if nothing is running.
        XCUIApplication().terminate()
    }

    override func tearDownWithError() throws {
        XCUIApplication().terminate()
    }

    @MainActor
    func testLaunchesToForeground() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 30),
            "App did not reach the foreground; state was \(app.state.rawValue)"
        )
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let app = XCUIApplication()
            app.launch()
            app.terminate()
        }
    }
}
