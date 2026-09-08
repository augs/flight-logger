//
//  SensorReading.swift
//  flight-logger
//
//  Created by august huber on 4/4/26.
//

import Foundation
import SwiftData

/// Where a reading came from. The three paths have very different resolution
/// and reliability, and until this existed they were indistinguishable in the
/// store — the only way to tell a backfilled row from a live one was to notice
/// its spacing was exactly 300s.
enum ReadingSource: String, CaseIterable {
    /// NUS heartbeat over the persistent link. ~2s at source, throttled on save.
    case heartbeat
    /// BLE advertisement. Foreground only; iOS delivers none in the background.
    case advertisement
    /// Backfilled from the tag's onboard log. Fixed ~5 min cadence.
    case history
    case unknown

    var label: String {
        switch self {
        case .heartbeat: "Live (linked)"
        case .advertisement: "Live (broadcast)"
        case .history: "Backfilled"
        case .unknown: "Unknown"
        }
    }

    /// Backfilled data is coarse; live data is not. Used to describe coverage.
    var isHighResolution: Bool { self != .history }
}

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

    /// Raw `ReadingSource`. Stored as a String with a property-level default so
    /// SwiftData lightweight migration can backfill existing rows — a mandatory
    /// attribute without one fails to migrate and the app won't launch.
    var source: String = ""

    var readingSource: ReadingSource {
        ReadingSource(rawValue: source) ?? .unknown
    }

    init(
        timestamp: Date = Date(),
        temperatureCelsius: Double,
        humidityPercent: Double,
        pressureHPa: Double,
        session: FlightSession? = nil,
        source: ReadingSource = .unknown
    ) {
        self.timestamp = timestamp
        self.temperatureCelsius = temperatureCelsius
        self.humidityPercent = humidityPercent
        self.pressureHPa = pressureHPa
        self.session = session
        self.source = source.rawValue
    }
}
