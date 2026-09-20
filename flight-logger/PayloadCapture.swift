//
//  PayloadCapture.swift
//  flight-logger
//
//  Created by august huber on 9/20/26.
//

import Foundation
import SwiftData

/// A complete airline API response, stored verbatim.
///
/// Opt-in, and off by default. One response captured at the start of a flight
/// answers "what shape is this API", but several questions this project cares
/// about can only be answered by watching a response *change*:
///
/// - **United's landing string is unknown** (bug B2). It has no on-ground
///   field, so auto-stop matches guessed substrings against free text like
///   `"In Flight - Estimated to Arrive 4 Minutes Early"`. The real arrival
///   wording only exists after wheels-down, and a single capture at the gate
///   before departure can never contain it.
/// - Fields appear and disappear by flight phase. A field that is null on the
///   ground may carry a value at cruise, and vice versa.
/// - Units are easiest to infer from a value that changes: an altitude that
///   climbs to 35,000 is feet, one that climbs to 10,668 is metres.
///
/// Captures stay on the device. Reporting them is a separate opt-in, and the
/// report redacts values unless the user says otherwise.
@Model
final class PayloadCapture {
    var timestamp: Date

    /// The full response body, exactly as received.
    var body: String = ""

    /// Which provider and endpoint produced it, recorded per capture so a
    /// session that somehow switched providers is still interpretable.
    var provider: String = ""
    var endpoint: String = ""

    /// Why this capture was kept — see `Reason`. Stored as a raw string so a
    /// new reason never breaks an existing store.
    var reason: String = ""

    /// Paths in this response that no config read, `path\ttype` per line.
    var unmappedFieldPaths: String = ""

    var session: FlightSession?

    init(
        timestamp: Date = Date(),
        body: String,
        provider: String,
        endpoint: String,
        reason: Reason,
        unmappedFieldPaths: String = "",
        session: FlightSession? = nil
    ) {
        self.timestamp = timestamp
        self.body = body
        self.provider = provider
        self.endpoint = endpoint
        self.reason = reason.rawValue
        self.unmappedFieldPaths = unmappedFieldPaths
        self.session = session
    }

    /// Why a capture was worth keeping.
    ///
    /// Recorded because it makes a capture set readable afterwards: the one
    /// marked `.statusChanged` immediately before `.landed` is where United's
    /// arrival wording will be.
    enum Reason: String, CaseIterable {
        case first              // the first response of the flight
        case newFields          // the set of unmapped paths changed
        case statusChanged      // flightStatus text differs from last capture
        case groundStateChanged // the on-ground flag flipped
        case periodic           // nothing changed, but time passed

        var label: String {
            switch self {
            case .first: "First response"
            case .newFields: "New fields appeared"
            case .statusChanged: "Status text changed"
            case .groundStateChanged: "On-ground flag changed"
            case .periodic: "Periodic"
            }
        }
    }

    var captureReason: Reason { Reason(rawValue: reason) ?? .periodic }

    var unmappedFields: [PayloadInspector.Leaf] {
        unmappedFieldPaths.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return PayloadInspector.Leaf(path: String(parts[0]), type: String(parts[1]))
        }
    }

    var json: [String: Any]? {
        guard let data = body.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

/// Decides which responses are worth keeping, and enforces the limits.
///
/// Pure and separate from the service so the policy can be tested against a
/// synthetic flight rather than a real one — the whole reason this feature
/// exists is that real ones are hard to come by.
enum CapturePolicy {

    /// Settings keys. Both default off: capturing is local but unbounded-ish,
    /// and reporting sends data off the device. They are deliberately separate
    /// decisions.
    static let captureEnabledKey = "payloadCaptureEnabled"
    static let reportingEnabledKey = "payloadReportingEnabled"

    /// Ceiling on captures per flight.
    ///
    /// A long-haul at one capture per five minutes is ~140; the cap allows for
    /// a busy flight with many changes while bounding a runaway. Responses are
    /// a few KB, so 500 is single-digit megabytes in the worst case.
    static let maxPerSession = 500

    /// Minimum gap between `.periodic` captures. Change-driven captures ignore
    /// this: a status change at 30 seconds matters more than a tidy interval.
    static let periodicInterval: TimeInterval = 300

    /// State carried between polls.
    struct State: Equatable {
        var lastCaptureAt: Date?
        var lastStatus: String?
        var lastOnGround: Bool?
        var lastUnmappedPaths: Set<String> = []
        var count: Int = 0
    }

    /// Whether to keep this response, and why.
    ///
    /// Change-driven first, then time. Ordering matters: a poll where the
    /// status changed *and* the interval elapsed should be recorded as the
    /// status change, because that is the fact worth finding later.
    static func decide(
        now: Date,
        status: String?,
        onGround: Bool?,
        unmappedPaths: Set<String>,
        state: State
    ) -> PayloadCapture.Reason? {
        guard state.count < maxPerSession else { return nil }

        if state.lastCaptureAt == nil { return .first }

        if unmappedPaths != state.lastUnmappedPaths { return .newFields }

        // Compared as optionals on purpose: a status that appears for the first
        // time, or disappears, is itself a change worth keeping.
        if status != state.lastStatus, status?.isEmpty == false { return .statusChanged }

        if onGround != state.lastOnGround, onGround != nil { return .groundStateChanged }

        if let last = state.lastCaptureAt, now.timeIntervalSince(last) >= periodicInterval {
            return .periodic
        }

        return nil
    }

    /// State after keeping a capture.
    static func advance(
        _ state: State,
        now: Date,
        status: String?,
        onGround: Bool?,
        unmappedPaths: Set<String>
    ) -> State {
        State(
            lastCaptureAt: now,
            lastStatus: status ?? state.lastStatus,
            lastOnGround: onGround ?? state.lastOnGround,
            lastUnmappedPaths: unmappedPaths,
            count: state.count + 1
        )
    }
}
