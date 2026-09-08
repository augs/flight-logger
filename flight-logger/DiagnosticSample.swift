//
//  DiagnosticSample.swift
//  flight-logger
//
//  Created by august huber on 9/7/26.
//

import Foundation
import SwiftData

/// A periodic proof-of-life record written while a session is recording.
///
/// Once the screen locks, nothing about the app's behaviour is observable: logs
/// can't be streamed from a normally-launched app, and attaching a debugger
/// changes the very suspension behaviour under test. These rows are the
/// evidence trail — the gaps between timestamps show exactly when iOS stopped
/// executing the app, and the network fields show whether background requests
/// still complete and how often.
///
/// Diagnostic only; safe to stop writing these once background behaviour is
/// settled.
@Model
final class DiagnosticSample {
    var timestamp: Date

    /// "active", "inactive" or "background" at the moment of sampling.
    var appState: String
    /// Seconds since the previous sample — the observed cadence, which reveals
    /// throttling that a fixed sleep interval would hide.
    var secondsSincePrevious: Double

    /// Whether SwiftData could be read; false means data protection blocked it.
    var storeReadable: Bool
    var storeError: String

    var readingCount: Int
    var bleStatus: String
    var locationStatus: String

    /// Whether an HTTP request completed, and how long it took.
    var networkOK: Bool
    var networkMilliseconds: Double
    var networkError: String

    /// Current history-sync state and the outcome of the last one, so periodic
    /// sync can be verified from a run with no debugger attached.
    ///
    /// Property-level defaults are required, not optional style: SwiftData's
    /// lightweight migration cannot backfill a mandatory attribute that has no
    /// default, and adding these without one made the app fail to launch
    /// against an existing store. A default in `init` does not count.
    var historySyncState: String = ""
    var historySyncResult: String = ""
    /// GATT stage trace of the last sync attempt, e.g. "retrieved@0.1s connected@16.2s".
    var historySyncTrace: String = ""

    /// Whether the persistent NUS link was up at sample time. The single most
    /// important field for verifying the link design from an unattended run.
    var linkReady: Bool = false

    init(
        timestamp: Date = Date(),
        appState: String,
        secondsSincePrevious: Double,
        storeReadable: Bool,
        storeError: String = "",
        readingCount: Int,
        bleStatus: String,
        locationStatus: String,
        networkOK: Bool,
        networkMilliseconds: Double,
        networkError: String = "",
        historySyncState: String = "",
        historySyncResult: String = "",
        historySyncTrace: String = "",
        linkReady: Bool = false
    ) {
        self.timestamp = timestamp
        self.appState = appState
        self.secondsSincePrevious = secondsSincePrevious
        self.storeReadable = storeReadable
        self.storeError = storeError
        self.readingCount = readingCount
        self.bleStatus = bleStatus
        self.locationStatus = locationStatus
        self.networkOK = networkOK
        self.networkMilliseconds = networkMilliseconds
        self.networkError = networkError
        self.historySyncState = historySyncState
        self.historySyncResult = historySyncResult
        self.historySyncTrace = historySyncTrace
        self.linkReady = linkReady
    }
}
