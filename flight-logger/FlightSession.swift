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
