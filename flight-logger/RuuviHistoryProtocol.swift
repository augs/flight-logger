//
//  RuuviHistoryProtocol.swift
//  flight-logger
//
//  Created by august huber on 9/7/26.
//

import Foundation

/// Wire format for RuuviTag's onboard log, read over the Nordic UART Service.
///
/// The tag records to its own flash continuously (roughly 10 days at the
/// default interval) regardless of whether a phone is listening. Downloading
/// that log is what gives us gap-free flight data — advertisement scanning
/// alone cannot, because iOS will not deliver advertisements to a backgrounded
/// app (see TODO.md P1 #5).
///
/// Protocol shape: 11-byte frames in both directions.
///
///     byte 0      destination endpoint
///     byte 1      source endpoint
///     byte 2      type
///     bytes 3-6   timestamp, big-endian UInt32, Unix seconds
///     bytes 7-10  value, big-endian Int32
///
/// A frame whose timestamp and value bytes are all `0xFF` terminates the
/// stream.
///
/// Constants below match Ruuvi's published specification:
/// https://docs.ruuvi.com/communication/bluetooth-connection/nordic-uart-service-nus/log-read
///
/// ✅ Verified against a physical RuuviTag on 2026-09-07: request bytes,
/// big-endian framing, all three scalings, and end-of-data detection were
/// confirmed against real captured traffic. Decoded values matched the tag's
/// live advertisement to within sensor drift. The captured frames are pinned as
/// regression tests in `RuuviHardwareCaptureTests`.
///
/// Observed log cadence on that tag was ~301s (5 minutes), which is the
/// effective resolution of any history download.
enum RuuviHistoryProtocol {

    // MARK: - Endpoints

    /// All environmental data — the destination used for a combined log read.
    static let environmental: UInt8 = 0x3A
    /// int32, 0.01 °C per LSB
    static let temperature: UInt8 = 0x30
    /// uint32, 0.01 RH-% per LSB
    static let humidity: UInt8 = 0x31
    /// uint32, 1 Pa per LSB
    static let pressure: UInt8 = 0x32

    // MARK: - Types

    /// Command type requesting a log read.
    static let logRead: UInt8 = 0x11
    /// Type on each streamed log entry coming back.
    static let logWrite: UInt8 = 0x10
    /// Tag-side error; payload is all `0xFF`.
    static let errorType: UInt8 = 0xF0

    /// 3-byte header (destination, source, type) + 8-byte payload.
    static let frameLength = 11

    // MARK: - Requests

    /// Builds the command asking the tag for all samples logged since `since`.
    ///
    /// The tag keeps time relative to the `now` value it is handed, so both
    /// timestamps must come from the same clock.
    static func logReadRequest(since: Date, now: Date = Date()) -> Data {
        var data = Data(capacity: frameLength)
        data.append(environmental)  // destination
        data.append(environmental)  // source
        data.append(logRead)        // type
        data.append(bigEndian: UInt32(max(0, now.timeIntervalSince1970)))
        data.append(bigEndian: UInt32(max(0, since.timeIntervalSince1970)))
        return data
    }

    // MARK: - Responses

    struct Sample: Equatable {
        /// Which measurement this frame carries (temperature/humidity/pressure).
        let endpoint: UInt8
        let timestamp: Date
        /// Raw fixed-point value, before scaling.
        let raw: Int32

        /// Temperature in °C, if this frame is a temperature sample.
        var celsius: Double? {
            endpoint == RuuviHistoryProtocol.temperature ? Double(raw) / 100.0 : nil
        }

        /// Relative humidity in %, if this frame is a humidity sample.
        var humidityPercent: Double? {
            endpoint == RuuviHistoryProtocol.humidity ? Double(raw) / 100.0 : nil
        }

        /// Pressure in hPa, if this frame is a pressure sample.
        /// The tag reports Pa; the app stores hPa.
        var pressureHPa: Double? {
            endpoint == RuuviHistoryProtocol.pressure ? Double(raw) / 100.0 : nil
        }
    }

    enum Frame: Equatable {
        case sample(Sample)
        case endOfData
        /// Tag reported an error (spec: header `[0x30, 0x30, 0xF0]`, payload all `0xFF`).
        case error
    }

    /// Parses one 11-byte frame. Returns nil for malformed or unrecognized input.
    static func parse(_ data: Data) -> Frame? {
        guard data.count >= frameLength else { return nil }
        let bytes = [UInt8](data)

        let source = bytes[1]
        let type = bytes[2]
        guard source == temperature || source == humidity || source == pressure else {
            return nil
        }

        let payload = bytes[3..<11]
        if payload.allSatisfy({ $0 == 0xFF }) {
            // Same all-0xFF payload for both; the type byte disambiguates.
            return type == errorType ? .error : .endOfData
        }

        let rawTime = UInt32(bytes[3]) << 24 | UInt32(bytes[4]) << 16
                    | UInt32(bytes[5]) << 8  | UInt32(bytes[6])
        let rawValue = Int32(bitPattern:
                      UInt32(bytes[7]) << 24 | UInt32(bytes[8]) << 16
                    | UInt32(bytes[9]) << 8  | UInt32(bytes[10]))

        guard rawTime > 0 else { return nil }

        return .sample(Sample(
            endpoint: source,
            timestamp: Date(timeIntervalSince1970: TimeInterval(rawTime)),
            raw: rawValue
        ))
    }

    // MARK: - Assembly

    /// A fully assembled log entry, once all three measurements for a given
    /// timestamp have arrived.
    struct Entry: Equatable {
        let timestamp: Date
        let temperatureCelsius: Double
        let humidityPercent: Double
        let pressureHPa: Double
    }

    /// Groups samples by timestamp into complete entries.
    ///
    /// The tag streams each measurement type as its own frame, so entries are
    /// only emitted once temperature, humidity, and pressure have all been seen
    /// for the same timestamp. Partial groups are dropped.
    static func assemble(_ samples: [Sample]) -> [Entry] {
        var byTime: [Date: (t: Double?, h: Double?, p: Double?)] = [:]

        for sample in samples {
            var slot = byTime[sample.timestamp] ?? (nil, nil, nil)
            if let value = sample.celsius { slot.t = value }
            if let value = sample.humidityPercent { slot.h = value }
            if let value = sample.pressureHPa { slot.p = value }
            byTime[sample.timestamp] = slot
        }

        return byTime.compactMap { timestamp, slot -> Entry? in
            guard let t = slot.t, let h = slot.h, let p = slot.p else { return nil }
            return Entry(timestamp: timestamp, temperatureCelsius: t, humidityPercent: h, pressureHPa: p)
        }
        .sorted { $0.timestamp < $1.timestamp }
    }
}

// MARK: - Helpers

private extension Data {
    mutating func append(bigEndian value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }
}
