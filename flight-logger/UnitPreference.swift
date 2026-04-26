//
//  UnitPreference.swift
//  flight-logger
//
//  Created by august huber on 4/5/26.
//

import Foundation

/// User preference for measurement unit display.
enum UnitPreference: String, CaseIterable, Identifiable {
    case system
    case imperial
    case metric

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "System Default"
        case .imperial: "Imperial"
        case .metric: "Metric"
        }
    }

    var description: String {
        switch self {
        case .system: "Use your device's region settings"
        case .imperial: "ft, mph, °F"
        case .metric: "m, km/h, °C"
        }
    }

    var usesMetric: Bool {
        switch self {
        case .system: Locale.current.measurementSystem != .us
        case .imperial: false
        case .metric: true
        }
    }

    // MARK: - Formatting

    func formatAltitude(_ feet: Double) -> String {
        if usesMetric {
            let meters = feet * 0.3048
            return String(format: "%.0f m", meters)
        }
        return String(format: "%.0f ft", feet)
    }

    func formatSpeed(_ mph: Double) -> String {
        if usesMetric {
            let kmh = mph * 1.60934
            return String(format: "%.0f km/h", kmh)
        }
        return String(format: "%.0f mph", mph)
    }

    /// Format outside air temperature (stored as °F).
    func formatOutsideTemp(_ fahrenheit: Double) -> String {
        if usesMetric {
            let celsius = (fahrenheit - 32) * 5.0 / 9.0
            return String(format: "%.0f°C", celsius)
        }
        return String(format: "%.0f°F", fahrenheit)
    }

    /// Format cabin sensor temperature (stored as °C).
    func formatCabinTemp(_ celsius: Double) -> String {
        if usesMetric {
            return String(format: "%.1f°C", celsius)
        }
        let fahrenheit = celsius * 9.0 / 5.0 + 32
        return String(format: "%.1f°F", fahrenheit)
    }

    // MARK: - Chart Values

    /// Convert altitude for chart Y-axis.
    func altitudeValue(_ feet: Double) -> Double {
        usesMetric ? feet * 0.3048 : feet
    }

    /// Convert outside air temp for chart Y-axis.
    func outsideTempValue(_ fahrenheit: Double) -> Double {
        usesMetric ? (fahrenheit - 32) * 5.0 / 9.0 : fahrenheit
    }

    /// Convert cabin temp for chart Y-axis.
    func cabinTempValue(_ celsius: Double) -> Double {
        usesMetric ? celsius : celsius * 9.0 / 5.0 + 32
    }

    // MARK: - Chart Labels

    var altitudeLabel: String { usesMetric ? "Altitude (m)" : "Altitude (ft)" }
    var speedLabel: String { usesMetric ? "Speed (km/h)" : "Speed (mph)" }
    var outsideTempLabel: String { usesMetric ? "Outside Temp (°C)" : "Outside Temp (°F)" }
    var cabinTempLabel: String { usesMetric ? "Cabin Temp (°C)" : "Cabin Temp (°F)" }
}
