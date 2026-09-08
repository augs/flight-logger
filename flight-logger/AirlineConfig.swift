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

    struct FieldMappings: Codable {
        // All optional: providers expose very different subsets. Panasonic's
        // feed carries altitude and speed but no flight number or on-ground
        // flag, and requiring those would make it impossible to describe.
        let flightNumber: String?
        let origin: String?
        let destination: String?
        let altitudeFt: String?
        let groundSpeedMPH: String?
        let airTempF: String?
        let onGround: String?

        let aircraftModel: String?
        let flightStatus: String?
        let scheduledDepartureTimeLocal: String?
        let scheduledArrivalTimeLocal: String?
        let timeRemainingMinutes: String?

        // Units the *provider* uses. The app stores feet, MPH and Fahrenheit
        // throughout, so anything else is converted on the way in.
        //
        // This is not optional polish: Panasonic reports ground speed in knots
        // and UGO in km/h, so treating a provider's number as MPH because the
        // field is named that way would record speeds wrong by 15-60%.
        let altitudeUnit: String?
        let speedUnit: String?
        let temperatureUnit: String?

        /// Substrings of `flightStatus` that mean the aircraft is down.
        ///
        /// United has no on-ground boolean — its `flifo` object carries 40
        /// fields and none of them is one (verified against a captured sample
        /// in `bogo/1K`). Text status is the only signal it offers, so this
        /// lets a config express that without special-casing an airline in
        /// code. Matched case-insensitively as a substring.
        let onGroundStatusValues: [String]?
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
