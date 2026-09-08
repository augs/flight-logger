//
//  AirlineConfig.swift
//  flight-logger
//
//  Created by august huber on 4/4/26.
//

import Foundation

/// JSON-driven airline API field mapping configuration.
/// Each config tells the app how to reach an airline's WiFi API
/// and where to find each data field in the JSON response.
struct AirlineConfig: Codable, Identifiable {
    var id: String { airline }

    let airline: String
    let url: String
    let fields: FieldMappings

    /// Every member defaults to nil, so a config maps only what its provider
    /// offers and adding a new field here does not break existing call sites —
    /// which it did once, across every test, before the defaults existed.
    ///
    /// These are `var`, not `let`, and that is load-bearing: a `let` with a
    /// default is a constant, which Swift omits from both the memberwise
    /// initializer *and* Decodable synthesis. Declared as `let ... = nil` every
    /// field would silently decode as nil and every airline config would stop
    /// working — invisibly, until someone was airborne.
    struct FieldMappings: Codable {
        // All optional: providers expose very different subsets. Panasonic's
        // feed carries altitude and speed but no flight number or on-ground
        // flag, and requiring those would make it impossible to describe.
        var flightNumber: String? = nil
        var origin: String? = nil
        var destination: String? = nil
        var altitudeFt: String? = nil
        var groundSpeedMPH: String? = nil
        var airTempF: String? = nil
        var onGround: String? = nil

        var aircraftModel: String? = nil
        var flightStatus: String? = nil
        var scheduledDepartureTimeLocal: String? = nil
        var scheduledArrivalTimeLocal: String? = nil
        var timeRemainingMinutes: String? = nil

        // Units the *provider* uses. The app stores feet, MPH and Fahrenheit
        // throughout, so anything else is converted on the way in.
        //
        // This is not optional polish: Panasonic reports ground speed in knots
        // and UGO in km/h, so treating a provider's number as MPH because the
        // field is named that way would record speeds wrong by 15-60%.
        var altitudeUnit: String? = nil
        var speedUnit: String? = nil
        var temperatureUnit: String? = nil

        // Static metadata. Recorded once and never recoverable afterwards, so
        // it is worth mapping even where nothing displays it yet.
        var originCity: String? = nil
        var destinationCity: String? = nil
        var originICAO: String? = nil
        var destinationICAO: String? = nil
        var departureGate: String? = nil
        var departureTerminal: String? = nil
        var arrivalGate: String? = nil
        var arrivalTerminal: String? = nil
        var tailNumber: String? = nil
        var equipmentCode: String? = nil
        var scheduledDurationMinutes: String? = nil

        /// Substrings of `flightStatus` that mean the aircraft is down.
        ///
        /// United has no on-ground boolean — its `flifo` object carries 40
        /// fields and none of them is one (verified against a captured sample
        /// in `bogo/1K`). Text status is the only signal it offers, so this
        /// lets a config express that without special-casing an airline in
        /// code. Matched case-insensitively as a substring.
        var onGroundStatusValues: [String]? = nil
    }
}

/// Loads all bundled airline configs from the app bundle.
enum AirlineConfigLoader {

    /// User-set URL of a mock or captured API, probed ahead of the bundled
    /// configs. Without this the only way to exercise the polling path is to
    /// board an aircraft, which makes every change to it untestable.
    static let testURLKey = "testAPIBaseURL"

    /// A config pointing at whatever the user put in Settings.
    ///
    /// Uses United's field mappings because `Tools-MockAirlineAPI.py` serves
    /// that shape by default — including its habit of sending every number as
    /// a string, which is the case most likely to break parsing.
    static func testConfig() -> AirlineConfig? {
        let raw = UserDefaults.standard.string(forKey: testURLKey) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, URL(string: trimmed) != nil else { return nil }

        return AirlineConfig(
            airline: "Test API",
            url: trimmed,
            fields: .init(
                flightNumber: "flifo.flightNumber",
                origin: "flifo.originAirportCode",
                destination: "flifo.destinationAirportCode",
                altitudeFt: "flifo.altitudeFt",
                groundSpeedMPH: "flifo.groundSpeedMPH",
                airTempF: "flifo.airTemperatureF",
                onGround: "flifo.onGround",
                aircraftModel: "flifo.aircraftModel",
                flightStatus: "flifo.flightStatus",
                scheduledDepartureTimeLocal: nil,
                scheduledArrivalTimeLocal: nil,
                timeRemainingMinutes: "flifo.timeRemainingToDestination",
                altitudeUnit: nil,
                speedUnit: nil,
                temperatureUnit: nil,
                originCity: nil, destinationCity: nil,
                originICAO: nil, destinationICAO: nil,
                departureGate: nil, departureTerminal: nil,
                arrivalGate: nil, arrivalTerminal: nil,
                tailNumber: nil, equipmentCode: nil,
                scheduledDurationMinutes: nil,
                onGroundStatusValues: nil
            )
        )
    }

    static func loadAll() -> [AirlineConfig] {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: "AirlineConfigs") else {
            return []
        }
        let bundled = urls.compactMap { url -> AirlineConfig? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(AirlineConfig.self, from: data)
        }
        // Test config first: when set, it is deliberately what you want probed,
        // and probing a real airline URL from the ground just wastes a timeout.
        return [testConfig()].compactMap { $0 } + bundled
    }

    static func loadConfig(named airline: String) -> AirlineConfig? {
        loadAll().first { $0.airline.lowercased() == airline.lowercased() }
    }
}
