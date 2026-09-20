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

    // Optional, and deliberately so. Providers differ in what they expose --
    // United reports no outside air temperature, several configs are
    // position-only -- and the parser is careful to distinguish "absent" from
    // "zero". Storing these as non-optional Doubles threw that away one line
    // later: a missing OAT became 0 degrees F, a plausible-looking cruise
    // reading, and a missing altitude became 0 ft, indistinguishable from
    // being on the ground. nil means the provider did not say.

    /// Altitude in feet (as reported by airline API).
    var altitudeFt: Double?
    /// Ground speed in MPH.
    var groundSpeedMPH: Double?
    /// Outside air temperature in °F.
    var outsideAirTempF: Double?
    /// Flight status string from airline API. Empty means not reported --
    /// unlike the numerics there is no plausible false value to guard against.
    var flightStatus: String = ""

    var session: FlightSession?

    init(
        timestamp: Date = Date(),
        altitudeFt: Double? = nil,
        groundSpeedMPH: Double? = nil,
        outsideAirTempF: Double? = nil,
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
