//
//  FlightDataPoint.swift
//  flight-logger
//
//  Created by august huber on 4/4/26.
//

import Foundation
import SwiftData

@Model
final class FlightDataPoint {
    var timestamp: Date
    /// Altitude in feet (as reported by airline API)
    var altitudeFt: Double
    /// Ground speed in MPH
    var groundSpeedMPH: Double
    /// Outside air temperature in °F
    var outsideAirTempF: Double
    /// Flight status string from airline API
    var flightStatus: String

    var session: FlightSession?

    init(
        timestamp: Date = Date(),
        altitudeFt: Double = 0,
        groundSpeedMPH: Double = 0,
        outsideAirTempF: Double = 0,
        flightStatus: String = "",
        session: FlightSession? = nil
    ) {
        self.timestamp = timestamp
        self.altitudeFt = altitudeFt
        self.groundSpeedMPH = groundSpeedMPH
        self.outsideAirTempF = outsideAirTempF
        self.flightStatus = flightStatus
        self.session = session
    }
}
