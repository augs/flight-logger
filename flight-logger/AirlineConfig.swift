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
        let flightNumber: String
        let origin: String
        let destination: String
        let altitudeFt: String
        let groundSpeedMPH: String
        let airTempF: String
        let onGround: String

        // Optional extended fields
        let aircraftModel: String?
        let flightStatus: String?
        let scheduledDepartureTimeLocal: String?
        let scheduledArrivalTimeLocal: String?
        let timeRemainingMinutes: String?
    }
}

/// Loads all bundled airline configs from the app bundle.
enum AirlineConfigLoader {
    static func loadAll() -> [AirlineConfig] {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: "AirlineConfigs") else {
            return []
        }
        return urls.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(AirlineConfig.self, from: data)
        }
    }

    static func loadConfig(named airline: String) -> AirlineConfig? {
        loadAll().first { $0.airline.lowercased() == airline.lowercased() }
    }
}
