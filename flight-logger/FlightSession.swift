//
//  FlightSession.swift
//  flight-logger
//
//  Created by august huber on 4/4/26.
//

import Foundation
import SwiftData

@Model
final class FlightSession {
    var flightNumber: String
    var airline: String
    var origin: String
    var destination: String
    var scheduledDeparture: Date?
    var scheduledArrival: Date?
    var aircraftModel: String
    var recordingStartedAt: Date
    var recordingEndedAt: Date?

    /// "api-auto" or "manual"
    var recordingMode: String

    @Relationship(deleteRule: .cascade, inverse: \SensorReading.session)
    var sensorReadings: [SensorReading] = []

    @Relationship(deleteRule: .cascade, inverse: \FlightDataPoint.session)
    var flightDataPoints: [FlightDataPoint] = []

    init(
        flightNumber: String = "",
        airline: String = "",
        origin: String = "",
        destination: String = "",
        scheduledDeparture: Date? = nil,
        scheduledArrival: Date? = nil,
        aircraftModel: String = "",
        recordingStartedAt: Date = Date(),
        recordingEndedAt: Date? = nil,
        recordingMode: String = "manual"
    ) {
        self.flightNumber = flightNumber
        self.airline = airline
        self.origin = origin
        self.destination = destination
        self.scheduledDeparture = scheduledDeparture
        self.scheduledArrival = scheduledArrival
        self.aircraftModel = aircraftModel
        self.recordingStartedAt = recordingStartedAt
        self.recordingEndedAt = recordingEndedAt
        self.recordingMode = recordingMode
    }

    // MARK: - Quality

    /// Summary of how well a session actually captured data.
    ///
    /// The app can log nothing at all for long stretches — a dropped tag link,
    /// a denied permission — and until this existed the only way to find out
    /// was to open the charts and squint, or query the store by hand. That is
    /// the wrong time to discover a flight wasn't recorded.
    struct Coverage {
        let readings: Int
        let highResolution: Int
        let backfilled: Int
        /// Longest interval between consecutive readings.
        let largestGap: TimeInterval
        /// Fraction of the session covered at better than the tag's log cadence.
        let liveFraction: Double

        var isEmpty: Bool { readings == 0 }
    }

    var coverage: Coverage {
        let sorted = sensorReadings.sorted { $0.timestamp < $1.timestamp }
        guard !sorted.isEmpty else {
            return Coverage(readings: 0, highResolution: 0, backfilled: 0, largestGap: 0, liveFraction: 0)
        }

        var largestGap: TimeInterval = 0
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            largestGap = max(largestGap, b.timestamp.timeIntervalSince(a.timestamp))
        }

        let high = sorted.filter { $0.readingSource.isHighResolution }.count
        return Coverage(
            readings: sorted.count,
            highResolution: high,
            backfilled: sorted.count - high,
            largestGap: largestGap,
            liveFraction: Double(high) / Double(sorted.count)
        )
    }

    /// Range of cabin pressure seen, the most legible one-glance summary of a
    /// flight — it tracks the cabin altitude profile directly.
    var pressureRange: (low: Double, high: Double)? {
        let values = sensorReadings.map(\.pressureHPa)
        guard let low = values.min(), let high = values.max() else { return nil }
        return (low, high)
    }

    var hasFlightData: Bool { !flightDataPoints.isEmpty }

        var displayTitle: String {
        if flightNumber.isEmpty {
            return "Flight on \(recordingStartedAt.formatted(date: .abbreviated, time: .shortened))"
        }
        return flightNumber
    }

    var routeDescription: String {
        if origin.isEmpty && destination.isEmpty { return "" }
        return "\(origin) → \(destination)"
    }

    var isRecording: Bool {
        recordingEndedAt == nil
    }

    var duration: TimeInterval? {
        guard let end = recordingEndedAt else { return nil }
        return end.timeIntervalSince(recordingStartedAt)
    }
}
