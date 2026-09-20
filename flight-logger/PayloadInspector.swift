//
//  PayloadInspector.swift
//  flight-logger
//
//  Created by august huber on 9/20/26.
//

import Foundation

/// Finds fields in an airline response that no config maps, and prepares a
/// payload that can be shared publicly without identifying the passenger.
///
/// These APIs are only reachable in the air. A field we do not know about is
/// not merely unmapped — it is invisible, and rediscovering it means waiting
/// for someone else to take the same flight. Every config in this app is
/// derived from other people's clients rather than from a capture (see
/// `AIRLINE_APIS.md`), so the shape we expect may be stale or vary by fleet.
/// This closes that loop: the app notices what it did not recognise and offers
/// to report it.
///
/// **Values are not needed for that.** Mapping a new field requires its path,
/// its type and roughly what it looks like — not a passenger's actual flight
/// number, tail number or gate. Redaction here is therefore the default and
/// not a setting, because a public issue tracker is forever and a raw payload
/// publicly links its reporter to a specific flight they were on.
enum PayloadInspector {

    /// One leaf value found in a response.
    struct Leaf: Equatable, Hashable, Comparable {
        /// Dot path, in the same syntax configs use (`flifo.altitudeFt`).
        let path: String
        /// JSON type, as a word a human can read in an issue.
        let type: String

        static func < (a: Leaf, b: Leaf) -> Bool { a.path < b.path }
    }

    // MARK: - Flattening

    /// Every leaf path in a response, in config path syntax.
    ///
    /// Arrays are indexed (`legs.0.altitude`) to match the resolver, so a path
    /// reported here can be pasted straight into a config.
    static func leaves(_ json: Any, prefix: String = "") -> [Leaf] {
        switch json {
        case let dict as [String: Any]:
            return dict.keys.sorted().flatMap { key -> [Leaf] in
                leaves(dict[key] as Any, prefix: prefix.isEmpty ? key : "\(prefix).\(key)")
            }

        case let array as [Any]:
            // Only the first element. Portals that wrap the current leg in a
            // list repeat the same shape, and reporting fifty identical paths
            // buries the one field that is actually new.
            guard let first = array.first else {
                return [Leaf(path: prefix, type: "empty array")]
            }
            return leaves(first, prefix: "\(prefix).0")

        case is NSNull:
            // Worth reporting: a null here may be a field that carries a value
            // on another fleet, or at another point in the flight.
            return [Leaf(path: prefix, type: "null")]

        case let number as NSNumber:
            return [Leaf(path: prefix, type: isBool(number) ? "boolean" : "number")]

        case is String:
            return [Leaf(path: prefix, type: "string")]

        default:
            return [Leaf(path: prefix, type: "unknown")]
        }
    }

    /// `NSNumber` does not distinguish booleans by type, only by its encoding.
    private static func isBool(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    // MARK: - What a config already covers

    /// Every path a config maps, including the ones it reads but does not store
    /// as a field of its own.
    static func mappedPaths(_ fields: AirlineConfig.FieldMappings) -> Set<String> {
        let paths = [
            fields.flightNumber, fields.origin, fields.destination,
            fields.altitudeFt, fields.groundSpeedMPH, fields.airTempF,
            fields.onGround, fields.aircraftModel, fields.flightStatus,
            fields.scheduledDepartureTimeLocal, fields.scheduledArrivalTimeLocal,
            fields.timeRemainingMinutes, fields.originCity, fields.destinationCity,
            fields.originICAO, fields.destinationICAO,
            fields.departureGate, fields.departureTerminal,
            fields.arrivalGate, fields.arrivalTerminal,
            fields.tailNumber, fields.equipmentCode, fields.scheduledDurationMinutes,
        ]
        return Set(paths.compactMap { $0 }.filter { !$0.isEmpty })
    }

    /// Paths present in the response that the config does not read.
    ///
    /// Sorted, so a report is stable and two flights on the same fleet produce
    /// comparable issues.
    static func unmapped(json: [String: Any], fields: AirlineConfig.FieldMappings) -> [Leaf] {
        let mapped = mappedPaths(fields)
        return leaves(json)
            .filter { !mapped.contains($0.path) }
            .filter { !isNoise($0.path) }
            .sorted()
    }

    /// Paths not worth reporting.
    ///
    /// Portal plumbing — session identifiers, connectivity state, advertising —
    /// is both useless for flight data and the most identifying part of the
    /// payload. Excluding it here means it never reaches a draft report in the
    /// first place, rather than relying on redaction to catch it.
    static func isNoise(_ path: String) -> Bool {
        let lower = path.lowercased()
        let fragments = [
            "session", "token", "cookie", "auth", "password", "secret",
            "macaddress", "mac_address", "ipaddress", "ip_address", "clientip",
            "advert", "banner", "promo", "offer", "product", "price", "cart",
            "portal", "captive", "sso", "login", "account", "subscriber",
            "deviceid", "device_id", "useragent", "user_agent",
        ]
        return fragments.contains { lower.contains($0) }
    }

    // MARK: - Redaction

    /// Keys whose *values* identify a person or their itinerary.
    ///
    /// The key names stay in the report — they are what makes it useful — but
    /// the values are replaced. Someone reading the issue learns that
    /// `flifo.tailNumber` exists and is a string; they do not learn which
    /// aircraft the reporter was sitting in.
    static let identifyingKeyFragments = [
        "flightnumber", "flight_number", "flightno", "flt",
        "tail", "registration", "nose", "aircraftreg",
        "gate", "terminal", "concourse", "seat", "pnr", "recordlocator",
        "name", "email", "phone", "passenger", "loyalty", "frequentflyer",
        "latitude", "longitude", "lat", "lon", "lng", "coordinate", "position",
        "uuid", "guid",
    ]

    /// A copy of the payload safe to attach to a public issue.
    ///
    /// Structure, keys and types are preserved exactly, because that is what a
    /// field map is built from. Numbers are kept — a value of 35000 versus
    /// 10668 is how you tell feet from metres, and that ambiguity has already
    /// caused one class of bug here — except where the key says it is a
    /// coordinate. Strings are kept only when short enough to be an enum-like
    /// status (`"cruise"`, `"In Flight"`) and not named as identifying.
    static func redacted(_ json: Any) -> Any {
        switch json {
        case let dict as [String: Any]:
            var out: [String: Any] = [:]
            for (key, value) in dict {
                if isNoise(key) { continue }
                out[key] = isIdentifying(key) ? placeholder(for: value) : redacted(value)
            }
            return out

        case let array as [Any]:
            return array.prefix(1).map { redacted($0) }

        case let string as String:
            // A long string is free-text or an encoded blob; either way its
            // content is not what makes the field worth mapping.
            return string.count <= 32 ? string : "<string, \(string.count) chars>"

        default:
            return json
        }
    }

    /// What an identifying value is replaced with: its type and shape only.
    static func placeholder(for value: Any) -> Any {
        switch value {
        case is NSNull: return NSNull()
        case let s as String: return "<redacted string, \(s.count) chars>"
        case let n as NSNumber: return isBool(n) ? n : "<redacted number>"
        default: return "<redacted>"
        }
    }

    static func isIdentifying(_ key: String) -> Bool {
        let lower = key.lowercased()
        return identifyingKeyFragments.contains { lower.contains($0) }
    }

    /// Redacted payload as pretty JSON, ready to paste into an issue.
    static func redactedJSONText(_ json: [String: Any]) -> String {
        let safe = redacted(json)
        guard JSONSerialization.isValidJSONObject(safe),
              let data = try? JSONSerialization.data(
                withJSONObject: safe, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return "(payload could not be serialised)" }
        return text
    }
}
