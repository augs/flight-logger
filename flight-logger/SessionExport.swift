//
//  SessionExport.swift
//  flight-logger
//
//  Created by august huber on 9/8/26.
//

import Foundation

/// Serialises a flight session for analysis elsewhere.
///
/// Full fidelity and entirely local: this is the user's own data leaving on the
/// user's own instruction, distinct from the anonymised contribution described
/// in `DATA_SHARING.md`. Nothing here is minimised or withheld.
///
/// Every format carries the derived psychrometric columns alongside the raw
/// readings. Relative humidity alone is misleading — it is a ratio to
/// saturation, so it varies with cabin temperature — and asking every downstream
/// query to redo that conversion invites getting it wrong somewhere.
enum SessionExport {

    enum Format: String, CaseIterable, Identifiable {
        case csv
        case lineProtocol
        case json

        var id: String { rawValue }

        var label: String {
            switch self {
            case .csv: "CSV bundle"
            case .lineProtocol: "InfluxDB line protocol"
            case .json: "JSON"
            }
        }

        var detail: String {
            switch self {
            case .csv: "Universal — Grafana, Excel, pandas"
            case .lineProtocol: "Straight into an InfluxDB datasource"
            case .json: "Full fidelity, including the raw API payload"
            }
        }

        var fileExtension: String {
            switch self {
            case .csv: "csv"
            case .lineProtocol: "lp"
            case .json: "json"
            }
        }
    }

    // MARK: - Shared helpers

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Escapes a field for CSV. Values containing a comma, quote or newline are
    /// quoted with internal quotes doubled — aircraft models and flight status
    /// strings genuinely contain commas.
    static func csvField(_ value: String) -> String {
        guard value.contains(where: { ",\"\n\r".contains($0) }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Escapes a tag key/value for line protocol, where commas, spaces and
    /// equals signs are structural.
    static func lineProtocolTag(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: " ", with: "\\ ")
            .replacingOccurrences(of: "=", with: "\\=")
    }

    private static func number(_ value: Double?, _ places: Int = 2) -> String {
        guard let value, value.isFinite else { return "" }
        return String(format: "%.\(places)f", value)
    }

    // MARK: - CSV

    /// One CSV per stream plus a metadata file, since the streams have
    /// different columns and cadences. Merging them into one table would mean a
    /// row that is mostly empty columns.
    static func csvFiles(for session: FlightSession) -> [(name: String, contents: String)] {
        let stem = fileStem(for: session)
        var files: [(String, String)] = []

        // Readings, with derived columns computed once here rather than in
        // every downstream query.
        var readings = "timestamp,temp_c,humidity_pct,pressure_hpa,"
            + "mixing_ratio_gkg,abs_humidity_gm3,dew_point_c,cabin_alt_ft,source\n"
        for r in session.sensorReadings.sorted(by: { $0.timestamp < $1.timestamp }) {
            let w = CabinAir.mixingRatio(temperatureC: r.temperatureCelsius,
                                         humidityPercent: r.humidityPercent,
                                         pressureHPa: r.pressureHPa)
            let ah = CabinAir.absoluteHumidity(temperatureC: r.temperatureCelsius,
                                               humidityPercent: r.humidityPercent)
            let dp = CabinAir.dewPoint(temperatureC: r.temperatureCelsius,
                                       humidityPercent: r.humidityPercent)
            let alt = CabinAir.pressureAltitudeFeet(pressureHPa: r.pressureHPa)

            readings += [
                iso.string(from: r.timestamp),
                number(r.temperatureCelsius), number(r.humidityPercent), number(r.pressureHPa),
                number(w, 3), number(ah, 3), number(dp), number(alt, 0),
                r.readingSource.rawValue,
            ].joined(separator: ",") + "\n"
        }
        files.append(("\(stem)-readings.csv", readings))

        if !session.flightDataPoints.isEmpty {
            var flight = "timestamp,altitude_ft,ground_speed_mph,outside_air_temp_f,flight_status\n"
            for p in session.flightDataPoints.sorted(by: { $0.timestamp < $1.timestamp }) {
                flight += [
                    iso.string(from: p.timestamp),
                    number(p.altitudeFt, 0), number(p.groundSpeedMPH, 0),
                    number(p.outsideAirTempF), csvField(p.flightStatus),
                ].joined(separator: ",") + "\n"
            }
            files.append(("\(stem)-flightdata.csv", flight))
        }

        if !session.deviceReadings.isEmpty {
            var device = "timestamp,phone_pressure_hpa,phone_cabin_alt_ft,"
                + "relative_altitude_m,gps_altitude_m,gps_vertical_accuracy_m,gps_speed_mps\n"
            for d in session.deviceReadings.sorted(by: { $0.timestamp < $1.timestamp }) {
                let alt = d.pressureHPa.flatMap { CabinAir.pressureAltitudeFeet(pressureHPa: $0) }
                device += [
                    iso.string(from: d.timestamp),
                    number(d.pressureHPa), number(alt, 0),
                    number(d.relativeAltitudeMeters), number(d.gpsAltitudeMeters, 1),
                    number(d.gpsVerticalAccuracy, 1), number(d.gpsSpeedMPS),
                ].joined(separator: ",") + "\n"
            }
            files.append(("\(stem)-device.csv", device))
        }

        files.append(("\(stem)-flight.json", jsonMetadata(for: session)))
        return files
    }

    // MARK: - InfluxDB line protocol

    /// Tagged so Grafana can filter without a join: aircraft type and reading
    /// source are the two dimensions any comparison needs.
    static func lineProtocol(for session: FlightSession) -> String {
        var out = ""

        // Tagged by flight and date rather than a model identifier: a hash is
        // unstable across devices and meaningless in a Grafana query, whereas
        // this groups the series the way a person would ask for it.
        var tags = ["session=\(lineProtocolTag(fileStem(for: session)))"]
        if !session.aircraftModel.isEmpty { tags.append("aircraft=\(lineProtocolTag(session.aircraftModel))") }
        if !session.flightNumber.isEmpty { tags.append("flight=\(lineProtocolTag(session.flightNumber))") }
        if !session.origin.isEmpty { tags.append("origin=\(lineProtocolTag(session.origin))") }
        if !session.destination.isEmpty { tags.append("destination=\(lineProtocolTag(session.destination))") }
        let base = tags.joined(separator: ",")

        for r in session.sensorReadings.sorted(by: { $0.timestamp < $1.timestamp }) {
            var fields = [
                "temp_c=\(r.temperatureCelsius)",
                "humidity_pct=\(r.humidityPercent)",
                "pressure_hpa=\(r.pressureHPa)",
            ]
            if let w = CabinAir.mixingRatio(temperatureC: r.temperatureCelsius,
                                            humidityPercent: r.humidityPercent,
                                            pressureHPa: r.pressureHPa) {
                fields.append("mixing_ratio_gkg=\(w)")
            }
            fields.append("abs_humidity_gm3=\(CabinAir.absoluteHumidity(temperatureC: r.temperatureCelsius, humidityPercent: r.humidityPercent))")
            if let alt = CabinAir.pressureAltitudeFeet(pressureHPa: r.pressureHPa) {
                fields.append("cabin_alt_ft=\(alt)")
            }
            out += "cabin,\(base),src=\(r.readingSource.rawValue) "
                + fields.joined(separator: ",") + " \(nanos(r.timestamp))\n"
        }

        for p in session.flightDataPoints.sorted(by: { $0.timestamp < $1.timestamp }) {
            out += "flight,\(base) altitude_ft=\(p.altitudeFt),ground_speed_mph=\(p.groundSpeedMPH),"
                + "outside_air_temp_f=\(p.outsideAirTempF) \(nanos(p.timestamp))\n"
        }

        for d in session.deviceReadings.sorted(by: { $0.timestamp < $1.timestamp }) {
            var fields: [String] = []
            if let hpa = d.pressureHPa {
                fields.append("pressure_hpa=\(hpa)")
                if let alt = CabinAir.pressureAltitudeFeet(pressureHPa: hpa) {
                    fields.append("cabin_alt_ft=\(alt)")
                }
            }
            if let alt = d.gpsAltitudeMeters { fields.append("gps_altitude_m=\(alt)") }
            if let speed = d.gpsSpeedMPS { fields.append("gps_speed_mps=\(speed)") }
            guard !fields.isEmpty else { continue }
            out += "device,\(base) " + fields.joined(separator: ",") + " \(nanos(d.timestamp))\n"
        }

        return out
    }

    private static func nanos(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1_000_000_000)
    }

    // MARK: - JSON

    static func json(for session: FlightSession) -> String {
        jsonMetadata(for: session, includeSeries: true)
    }

    private static func jsonMetadata(for session: FlightSession, includeSeries: Bool = false) -> String {
        let coverage = session.coverage
        var root: [String: Any] = [
            "flightNumber": session.flightNumber,
            "airline": session.airline,
            "origin": session.origin,
            "destination": session.destination,
            "originCity": session.originCity,
            "destinationCity": session.destinationCity,
            "originICAO": session.originICAO,
            "destinationICAO": session.destinationICAO,
            "aircraftModel": session.aircraftModel,
            "tailNumber": session.tailNumber,
            "equipmentCode": session.equipmentCode,
            "departureGate": session.departureGate,
            "departureTerminal": session.departureTerminal,
            "arrivalGate": session.arrivalGate,
            "arrivalTerminal": session.arrivalTerminal,
            "recordingMode": session.recordingMode,
            "apiProvider": session.apiProvider,
            "scheduledDurationMinutes": session.scheduledDurationMinutes,
            "recordingStartedAt": iso.string(from: session.recordingStartedAt),
            "coverage": [
                "readings": coverage.readings,
                "highResolution": coverage.highResolution,
                "backfilled": coverage.backfilled,
                "unclassified": coverage.unclassified,
                "largestGapSeconds": coverage.largestGap,
                "liveFraction": coverage.liveFraction,
            ],
        ]
        if let ended = session.recordingEndedAt { root["recordingEndedAt"] = iso.string(from: ended) }
        if let interval = session.backfillInterval { root["tagLogIntervalSeconds"] = interval }
        // The raw payload is the record of anything this schema has no field
        // for, so a full-fidelity export must carry it.
        if !session.rawFirstResponse.isEmpty { root["rawFirstResponse"] = session.rawFirstResponse }

        if includeSeries {
            root["readings"] = session.sensorReadings
                .sorted { $0.timestamp < $1.timestamp }
                .map { r -> [String: Any] in
                    var row: [String: Any] = [
                        "timestamp": iso.string(from: r.timestamp),
                        "temperatureC": r.temperatureCelsius,
                        "humidityPercent": r.humidityPercent,
                        "pressureHPa": r.pressureHPa,
                        "source": r.readingSource.rawValue,
                        "absoluteHumidityGM3": CabinAir.absoluteHumidity(
                            temperatureC: r.temperatureCelsius, humidityPercent: r.humidityPercent),
                    ]
                    if let w = CabinAir.mixingRatio(temperatureC: r.temperatureCelsius,
                                                    humidityPercent: r.humidityPercent,
                                                    pressureHPa: r.pressureHPa) {
                        row["mixingRatioGKg"] = w
                    }
                    if let alt = CabinAir.pressureAltitudeFeet(pressureHPa: r.pressureHPa) {
                        row["cabinAltitudeFt"] = alt
                    }
                    return row
                }

            root["flightData"] = session.flightDataPoints
                .sorted { $0.timestamp < $1.timestamp }
                .map { [
                    "timestamp": iso.string(from: $0.timestamp),
                    "altitudeFt": $0.altitudeFt,
                    "groundSpeedMPH": $0.groundSpeedMPH,
                    "outsideAirTempF": $0.outsideAirTempF,
                    "flightStatus": $0.flightStatus,
                ] }

            root["deviceReadings"] = session.deviceReadings
                .sorted { $0.timestamp < $1.timestamp }
                .map { d -> [String: Any] in
                    var row: [String: Any] = ["timestamp": iso.string(from: d.timestamp)]
                    if let v = d.pressureHPa { row["pressureHPa"] = v }
                    if let v = d.relativeAltitudeMeters { row["relativeAltitudeM"] = v }
                    if let v = d.gpsAltitudeMeters { row["gpsAltitudeM"] = v }
                    if let v = d.gpsVerticalAccuracy { row["gpsVerticalAccuracyM"] = v }
                    if let v = d.gpsSpeedMPS { row["gpsSpeedMPS"] = v }
                    return row
                }
        }

        guard let data = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    // MARK: - Naming

    /// Filenames need to be distinguishable in a Files app listing, so they
    /// carry the flight and date rather than an opaque identifier.
    static func fileStem(for session: FlightSession) -> String {
        let date = DateFormatter()
        date.dateFormat = "yyyy-MM-dd"
        let flight = session.flightNumber.isEmpty ? "flight" : session.flightNumber
        let safe = flight.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "")
        return "\(safe)-\(date.string(from: session.recordingStartedAt))"
    }

    /// Writes the chosen format to a temporary directory and returns the URLs
    /// for the share sheet.
    static func write(_ session: FlightSession, as format: Format) throws -> [URL] {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let stem = fileStem(for: session)
        switch format {
        case .csv:
            return try csvFiles(for: session).map { file in
                let url = directory.appending(path: file.name)
                try file.contents.write(to: url, atomically: true, encoding: .utf8)
                return url
            }
        case .lineProtocol:
            let url = directory.appending(path: "\(stem).lp")
            try lineProtocol(for: session).write(to: url, atomically: true, encoding: .utf8)
            return [url]
        case .json:
            let url = directory.appending(path: "\(stem).json")
            try json(for: session).write(to: url, atomically: true, encoding: .utf8)
            return [url]
        }
    }
}
