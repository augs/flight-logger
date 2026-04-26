//
//  SensorReading.swift
//  flight-logger
//
//  Created by august huber on 4/4/26.
//

import Foundation
import SwiftData

@Model
final class SensorReading {
    var timestamp: Date
    /// Cabin temperature in °C
    var temperatureCelsius: Double
    /// Relative humidity in %
    var humidityPercent: Double
    /// Atmospheric pressure in hPa
    var pressureHPa: Double

    var session: FlightSession?

    init(
        timestamp: Date = Date(),
        temperatureCelsius: Double,
        humidityPercent: Double,
        pressureHPa: Double,
        session: FlightSession? = nil
    ) {
        self.timestamp = timestamp
        self.temperatureCelsius = temperatureCelsius
        self.humidityPercent = humidityPercent
        self.pressureHPa = pressureHPa
        self.session = session
    }
}
