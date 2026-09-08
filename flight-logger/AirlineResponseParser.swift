//
//  AirlineResponseParser.swift
//  flight-logger
//
//  Created by august huber on 9/8/26.
//

import Foundation

/// Turns an airline WiFi API response into typed values, given a config's field
/// mappings.
///
/// Extracted from `AirlineAPIService` so it can be tested against recorded
/// responses without a network, a database, or a flight. This is the part most
/// likely to be wrong for any given airline: portals are inconsistent about
/// whether numbers arrive as JSON numbers or strings, and about how they spell
/// booleans — and a silent coercion failure means a field is simply missing
/// from a recording that cannot be taken again.
enum AirlineResponseParser {

    /// One poll's worth of extracted values. Everything is optional because
    /// airlines differ in what they expose, and a missing field should narrow
    /// the record rather than invalidate it.
    struct Reading: Equatable {
        var flightNumber: String?
        var origin: String?
        var destination: String?
        var aircraftModel: String?
        var flightStatus: String?

        var altitudeFt: Double?
        var groundSpeedMPH: Double?
        var airTempF: Double?
        var timeRemainingMinutes: Double?

        var onGround: Bool?

        /// True when nothing at all could be extracted — usually a sign the
        /// config's paths don't match this portal's shape.
        var isEmpty: Bool {
            self == Reading()
        }
    }

    // MARK: - Unit conversion

    /// Provider units, normalised to what the app stores (feet, MPH, °F).
    ///
    /// Defaults match the field names — a config that omits these is assumed to
    /// already be in the app's units, which is what the original United config
    /// does.
    static func altitudeInFeet(_ value: Double, unit: String?) -> Double {
        switch unit?.lowercased() {
        case "m", "meter", "meters", "metres": value / 0.3048
        default: value
        }
    }

    static func speedInMPH(_ value: Double, unit: String?) -> Double {
        switch unit?.lowercased() {
        case "kt", "kts", "knot", "knots": value * 1.15078
        case "kph", "kmh", "km/h", "kmph": value * 0.621371
        case "mps", "m/s": value * 2.23694
        default: value
        }
    }

    static func temperatureInFahrenheit(_ value: Double, unit: String?) -> Double {
        switch unit?.lowercased() {
        case "c", "celsius", "centigrade": value * 9 / 5 + 32
        case "k", "kelvin": (value - 273.15) * 9 / 5 + 32
        default: value
        }
    }

    static func parse(json: [String: Any], fields: AirlineConfig.FieldMappings) -> Reading {
        Reading(
            flightNumber: string(json, fields.flightNumber),
            origin: string(json, fields.origin),
            destination: string(json, fields.destination),
            aircraftModel: string(json, fields.aircraftModel),
            flightStatus: string(json, fields.flightStatus),
            altitudeFt: double(json, fields.altitudeFt)
                .map { altitudeInFeet($0, unit: fields.altitudeUnit) },
            groundSpeedMPH: double(json, fields.groundSpeedMPH)
                .map { speedInMPH($0, unit: fields.speedUnit) },
            airTempF: double(json, fields.airTempF)
                .map { temperatureInFahrenheit($0, unit: fields.temperatureUnit) },
            timeRemainingMinutes: double(json, fields.timeRemainingMinutes),
            onGround: bool(json, fields.onGround)
        )
    }

    // MARK: - Path resolution

    /// Resolves a dot-separated key path such as `flifo.altitudeFt`.
    ///
    /// Also indexes into arrays with numeric components (`legs.0.altitude`),
    /// because some portals wrap the current leg in a list.
    static func resolve(_ json: [String: Any], _ path: String?) -> Any? {
        guard let path, !path.isEmpty else { return nil }

        var current: Any = json
        for key in path.split(separator: ".") {
            if let dict = current as? [String: Any], let next = dict[String(key)] {
                current = next
            } else if let array = current as? [Any], let index = Int(key), array.indices.contains(index) {
                current = array[index]
            } else {
                return nil
            }
        }
        // NSNull is JSON's null; treat it as absent rather than as a value.
        return current is NSNull ? nil : current
    }

    static func string(_ json: [String: Any], _ path: String?) -> String? {
        guard let value = resolve(json, path) else { return nil }
        if let s = value as? String {
            // Portals pad and blank fields inconsistently; an empty string is
            // absence, not a value.
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if value is [Any] || value is [String: Any] { return nil }
        return "\(value)"
    }

    static func double(_ json: [String: Any], _ path: String?) -> Double? {
        guard let value = resolve(json, path) else { return nil }
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String {
            // Seen in the wild: thousands separators, units, and leading plus.
            let cleaned = s
                .replacingOccurrences(of: ",", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "+ \t\n"))
            return Double(cleaned)
        }
        return nil
    }

    static func bool(_ json: [String: Any], _ path: String?) -> Bool? {
        guard let value = resolve(json, path) else { return nil }
        if let b = value as? Bool { return b }
        if let i = value as? Int { return i != 0 }
        if let d = value as? Double { return d != 0 }
        if let s = value as? String {
            switch s.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "1", "yes", "y", "t": return true
            case "false", "0", "no", "n", "f": return false
            default: return nil
            }
        }
        return nil
    }
}
