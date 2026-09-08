//
//  flight_loggerTests.swift
//  flight-loggerTests
//
//  Created by august huber on 4/4/26.
//

import Testing
import Foundation
@testable import flight_logger

// MARK: - RAWv2 / Data Format 5 parsing

struct RAWv2ParsingTests {

    /// Official RuuviTag Data Format 5 "valid data" test vector.
    static let validVector = Data([
        0x05, 0x12, 0xFC, 0x53, 0x94, 0xC3, 0x7C, 0x00,
        0x04, 0xFF, 0xFC, 0x04, 0x0C, 0xAC, 0x36, 0x42,
        0x00, 0xCD, 0xCB, 0xB8, 0x33, 0x4C, 0x88, 0x4F,
    ])

    @Test func parsesOfficialTestVector() throws {
        let parsed = try #require(RuuviTagScanner.parseRAWv2(Self.validVector))

        #expect(abs(parsed.temperature - 24.3) < 0.001)
        #expect(abs(parsed.humidity - 53.49) < 0.001)
        #expect(abs(parsed.pressure - 1000.44) < 0.001)
    }

    @Test func rejectsInvalidSentinelValues() {
        // Temperature, humidity and pressure all set to their "invalid" markers.
        var bytes = [UInt8](repeating: 0x00, count: 24)
        bytes[0] = 0x05
        bytes[1] = 0x80; bytes[2] = 0x00   // temperature = -32768
        bytes[3] = 0xFF; bytes[4] = 0xFF   // humidity = 0xFFFF
        bytes[5] = 0xFF; bytes[6] = 0xFF   // pressure = 0xFFFF

        #expect(RuuviTagScanner.parseRAWv2(Data(bytes)) == nil)
    }

    @Test func rejectsWrongDataFormat() {
        var bytes = [UInt8](Self.validVector)
        bytes[0] = 0x03  // RAWv1, not supported
        #expect(RuuviTagScanner.parseRAWv2(Data(bytes)) == nil)
    }

    @Test func rejectsTruncatedPayload() {
        // 20 bytes is neither shape the tag emits: 24 (advertisement, with MAC)
        // nor 18 (NUS heartbeat, without). A loose `>= 18` guard would wrongly
        // accept this.
        #expect(RuuviTagScanner.parseRAWv2(Data(Self.validVector.prefix(20))) == nil)
        #expect(RuuviTagScanner.parseRAWv2(Data(Self.validVector.prefix(17))) == nil)
        #expect(RuuviTagScanner.parseRAWv2(Data(Self.validVector.prefix(23))) == nil)
    }
}

// MARK: - History protocol

struct RuuviHistoryProtocolTests {

    /// Builds an 11-byte response frame the way the tag would.
    static func frame(source: UInt8, timestamp: UInt32, value: Int32) -> Data {
        var bytes: [UInt8] = [RuuviHistoryProtocol.environmental, source, 0x10]
        let raw = UInt32(bitPattern: value)
        bytes += [
            UInt8((timestamp >> 24) & 0xFF), UInt8((timestamp >> 16) & 0xFF),
            UInt8((timestamp >> 8) & 0xFF), UInt8(timestamp & 0xFF),
            UInt8((raw >> 24) & 0xFF), UInt8((raw >> 16) & 0xFF),
            UInt8((raw >> 8) & 0xFF), UInt8(raw & 0xFF),
        ]
        return Data(bytes)
    }

    @Test func buildsLogReadRequest() {
        let now = Date(timeIntervalSince1970: 0x0000_0100)
        let since = Date(timeIntervalSince1970: 0x0000_0010)
        let request = RuuviHistoryProtocol.logReadRequest(since: since, now: now)

        #expect(request.count == RuuviHistoryProtocol.frameLength)
        #expect(request[0] == RuuviHistoryProtocol.environmental)
        #expect(request[1] == RuuviHistoryProtocol.environmental)
        #expect(request[2] == RuuviHistoryProtocol.logRead)
        // Timestamps are big-endian UInt32.
        #expect(Array(request[3...6]) == [0x00, 0x00, 0x01, 0x00])
        #expect(Array(request[7...10]) == [0x00, 0x00, 0x00, 0x10])
    }

    @Test func parsesTemperatureFrame() throws {
        let data = Self.frame(source: RuuviHistoryProtocol.temperature, timestamp: 1_700_000_000, value: 2430)
        let frame = try #require(RuuviHistoryProtocol.parse(data))

        guard case .sample(let sample) = frame else {
            Issue.record("Expected a sample frame")
            return
        }
        #expect(sample.timestamp == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(sample.celsius == 24.30)
        // Scaling accessors are endpoint-specific.
        #expect(sample.humidityPercent == nil)
        #expect(sample.pressureHPa == nil)
    }

    @Test func parsesNegativeTemperature() throws {
        let data = Self.frame(source: RuuviHistoryProtocol.temperature, timestamp: 1_700_000_000, value: -1550)
        let frame = try #require(RuuviHistoryProtocol.parse(data))

        guard case .sample(let sample) = frame else {
            Issue.record("Expected a sample frame")
            return
        }
        #expect(sample.celsius == -15.50)
    }

    @Test func parsesPressureAsHectopascals() throws {
        // Tag reports Pa; the app stores hPa.
        let data = Self.frame(source: RuuviHistoryProtocol.pressure, timestamp: 1_700_000_000, value: 100_044)
        let frame = try #require(RuuviHistoryProtocol.parse(data))

        guard case .sample(let sample) = frame else {
            Issue.record("Expected a sample frame")
            return
        }
        #expect(sample.pressureHPa == 1000.44)
    }

    @Test func detectsEndOfData() {
        var bytes: [UInt8] = [RuuviHistoryProtocol.environmental, RuuviHistoryProtocol.temperature, 0x10]
        bytes += [UInt8](repeating: 0xFF, count: 8)

        #expect(RuuviHistoryProtocol.parse(Data(bytes)) == .endOfData)
    }

    @Test func rejectsUnknownEndpointAndShortFrames() {
        let unknown = Self.frame(source: 0x7E, timestamp: 1_700_000_000, value: 1)
        #expect(RuuviHistoryProtocol.parse(unknown) == nil)

        let short = Self.frame(source: RuuviHistoryProtocol.temperature, timestamp: 1, value: 1).prefix(7)
        #expect(RuuviHistoryProtocol.parse(Data(short)) == nil)
    }

    @Test func assemblesCompleteEntriesOnly() {
        let t1: UInt32 = 1_700_000_000
        let t2: UInt32 = 1_700_000_060

        let samples: [RuuviHistoryProtocol.Sample] = [
            // t1 has all three measurements.
            .init(endpoint: RuuviHistoryProtocol.temperature, timestamp: Date(timeIntervalSince1970: TimeInterval(t1)), raw: 2430),
            .init(endpoint: RuuviHistoryProtocol.humidity, timestamp: Date(timeIntervalSince1970: TimeInterval(t1)), raw: 5349),
            .init(endpoint: RuuviHistoryProtocol.pressure, timestamp: Date(timeIntervalSince1970: TimeInterval(t1)), raw: 100_044),
            // t2 is missing pressure and must be dropped.
            .init(endpoint: RuuviHistoryProtocol.temperature, timestamp: Date(timeIntervalSince1970: TimeInterval(t2)), raw: 2400),
            .init(endpoint: RuuviHistoryProtocol.humidity, timestamp: Date(timeIntervalSince1970: TimeInterval(t2)), raw: 5300),
        ]

        let entries = RuuviHistoryProtocol.assemble(samples)

        #expect(entries.count == 1)
        #expect(entries[0].timestamp == Date(timeIntervalSince1970: TimeInterval(t1)))
        #expect(entries[0].temperatureCelsius == 24.30)
        #expect(entries[0].humidityPercent == 53.49)
        #expect(entries[0].pressureHPa == 1000.44)
    }

    @Test func assembleSortsChronologically() {
        let times: [UInt32] = [1_700_000_120, 1_700_000_000, 1_700_000_060]
        let samples = times.flatMap { t -> [RuuviHistoryProtocol.Sample] in
            let date = Date(timeIntervalSince1970: TimeInterval(t))
            return [
                .init(endpoint: RuuviHistoryProtocol.temperature, timestamp: date, raw: 2000),
                .init(endpoint: RuuviHistoryProtocol.humidity, timestamp: date, raw: 5000),
                .init(endpoint: RuuviHistoryProtocol.pressure, timestamp: date, raw: 100_000),
            ]
        }

        let entries = RuuviHistoryProtocol.assemble(samples)

        #expect(entries.map(\.timestamp) == times.sorted().map { Date(timeIntervalSince1970: TimeInterval($0)) })
    }
}

// MARK: - Spec conformance (docs.ruuvi.com log-read)

struct RuuviHistorySpecTests {

    /// Spec: error frame is header [0x30, 0x30, 0xF0] with an all-0xFF payload,
    /// which must not be mistaken for a normal end-of-data terminator.
    @Test func distinguishesErrorFrameFromEndOfData() {
        var errorFrame: [UInt8] = [0x30, 0x30, RuuviHistoryProtocol.errorType]
        errorFrame += [UInt8](repeating: 0xFF, count: 8)
        #expect(RuuviHistoryProtocol.parse(Data(errorFrame)) == .error)

        var endFrame: [UInt8] = [0x3A, 0x30, RuuviHistoryProtocol.logWrite]
        endFrame += [UInt8](repeating: 0xFF, count: 8)
        #expect(RuuviHistoryProtocol.parse(Data(endFrame)) == .endOfData)
    }

    /// Spec: request header is [destination, destination, 0x11].
    @Test func requestUsesDestinationTwiceInHeader() {
        let req = RuuviHistoryProtocol.logReadRequest(since: Date(), now: Date())
        #expect(req[0] == req[1])
        #expect(req[0] == RuuviHistoryProtocol.environmental)
        #expect(req[2] == RuuviHistoryProtocol.logRead)
    }
}

// MARK: - Golden data captured from a physical RuuviTag (2026-09-07)

/// Real traffic recorded from tag "Ruuvi ED2A" over NUS. These bytes are the
/// ground truth for the log-read protocol — if a change breaks these, it breaks
/// against real hardware.
struct RuuviHardwareCaptureTests {

    static func bytes(_ s: String) -> Data {
        Data(s.split(separator: " ").map { UInt8($0, radix: 16)! })
    }

    /// The exact request the probe sent, which the tag accepted and answered.
    @Test func matchesCapturedRequestBytes() {
        let now = Date(timeIntervalSince1970: 1_788_831_512)
        let since = Date(timeIntervalSince1970: 1_788_827_912)  // now - 3600

        let built = RuuviHistoryProtocol.logReadRequest(since: since, now: now)

        #expect(built == Self.bytes("3A 3A 11 6A 9F 67 18 6A 9F 59 08"))
    }

    /// Frames as they came off the wire, one per measurement, sharing a timestamp.
    @Test func decodesCapturedFrames() throws {
        let captured: [(hex: String, endpoint: UInt8, value: Double)] = [
            ("3A 31 10 6A 9F 5A B0 00 00 15 A7", RuuviHistoryProtocol.humidity, 55.43),
            ("3A 32 10 6A 9F 5A B0 00 01 88 AA", RuuviHistoryProtocol.pressure, 1005.22),
            ("3A 30 10 6A 9F 5A B0 00 00 08 D2", RuuviHistoryProtocol.temperature, 22.58),
        ]

        var samples: [RuuviHistoryProtocol.Sample] = []
        for entry in captured {
            let frame = try #require(RuuviHistoryProtocol.parse(Self.bytes(entry.hex)))
            guard case .sample(let sample) = frame else {
                Issue.record("Expected sample for \(entry.hex)")
                return
            }
            #expect(sample.endpoint == entry.endpoint)
            #expect(sample.timestamp == Date(timeIntervalSince1970: 1_788_828_336))

            let scaled = sample.celsius ?? sample.humidityPercent ?? sample.pressureHPa
            #expect(abs(try #require(scaled) - entry.value) < 0.001)
            samples.append(sample)
        }

        // The three frames must assemble into exactly one complete entry.
        let entries = RuuviHistoryProtocol.assemble(samples)
        #expect(entries.count == 1)
        #expect(entries[0].temperatureCelsius == 22.58)
        #expect(entries[0].humidityPercent == 55.43)
        #expect(entries[0].pressureHPa == 1005.22)
    }

    /// Observed on-device log cadence was 301s between entries.
    @Test func assemblesConsecutiveLogEntriesFiveMinutesApart() {
        let first: UInt32 = 1_788_828_336
        let second: UInt32 = 1_788_828_637

        let samples = [first, second].flatMap { t -> [RuuviHistoryProtocol.Sample] in
            let d = Date(timeIntervalSince1970: TimeInterval(t))
            return [
                .init(endpoint: RuuviHistoryProtocol.humidity, timestamp: d, raw: 5543),
                .init(endpoint: RuuviHistoryProtocol.pressure, timestamp: d, raw: 100_522),
                .init(endpoint: RuuviHistoryProtocol.temperature, timestamp: d, raw: 2258),
            ]
        }

        let entries = RuuviHistoryProtocol.assemble(samples)
        #expect(entries.count == 2)
        #expect(entries[1].timestamp.timeIntervalSince(entries[0].timestamp) == 301)
    }
}

// MARK: - NUS heartbeat frames (captured from hardware 2026-09-07)

/// While connected over NUS the tag streams its current reading as an 18-byte
/// Data Format 5 payload — the advertisement format minus the trailing 6-byte
/// MAC. These were previously rejected on length alone.
struct RuuviHeartbeatTests {

    static func bytes(_ s: String) -> Data {
        Data(s.split(separator: " ").map { UInt8($0, radix: 16)! })
    }

    @Test func parsesCapturedHeartbeatFrames() throws {
        let captured: [(hex: String, degC: Double, rh: Double, hPa: Double)] = [
            ("05 11 95 56 82 C5 71 FF EC 02 CC FD 44 AC B6 79 E7 29", 22.50, 55.365, 1005.45),
            ("05 11 9E 56 8F C5 73 FF E8 02 CC FD 3C AC B6 79 E7 2A", 22.55, 55.3975, 1005.47),
            ("05 11 98 56 8B C5 75 FF EC 02 CC FD 48 AC B6 79 E7 2B", 22.52, 55.3875, 1005.49),
        ]

        for entry in captured {
            let data = Self.bytes(entry.hex)
            #expect(data.count == 18)

            let parsed = try #require(
                RuuviTagScanner.parseRAWv2(data),
                "18-byte heartbeat must parse; a >= 24 length guard silently dropped these"
            )
            #expect(abs(parsed.temperature - entry.degC) < 0.005)
            #expect(abs(parsed.humidity - entry.rh) < 0.005)
            #expect(abs(parsed.pressure - entry.hPa) < 0.005)
        }
    }

    /// A heartbeat must not be mistaken for a log frame, and vice versa.
    @Test func heartbeatIsNotALogFrame() {
        let heartbeat = Self.bytes("05 11 95 56 82 C5 71 FF EC 02 CC FD 44 AC B6 79 E7 29")
        #expect(RuuviHistoryProtocol.parse(heartbeat) == nil)

        // ...and a log frame is not valid DF5: byte 0 is the destination
        // endpoint 0x3A, not the 0x05 format marker.
        let logFrame = Self.bytes("3A 31 10 6A 9F 6C 5B 00 00 15 AB")
        #expect(RuuviTagScanner.parseRAWv2(logFrame) == nil)
    }

    /// Still parses full-length advertisement payloads.
    @Test func stillParsesFullAdvertisementPayload() throws {
        let parsed = try #require(RuuviTagScanner.parseRAWv2(RAWv2ParsingTests.validVector))
        #expect(abs(parsed.temperature - 24.3) < 0.001)
    }
}

// MARK: - Session coverage

/// Coverage is what answers "did this flight actually record?" — the question
/// that previously required querying the store by hand.
struct FlightSessionCoverageTests {

    static func session(with readings: [(offset: TimeInterval, source: ReadingSource)]) -> FlightSession {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let session = FlightSession(recordingStartedAt: start)
        session.sensorReadings = readings.map {
            SensorReading(
                timestamp: start.addingTimeInterval($0.offset),
                temperatureCelsius: 22, humidityPercent: 55, pressureHPa: 1000,
                source: $0.source
            )
        }
        return session
    }

    @Test func emptySessionReportsNoData() {
        let coverage = Self.session(with: []).coverage
        #expect(coverage.isEmpty)
        #expect(coverage.readings == 0)
        #expect(coverage.largestGap == 0)
    }

    @Test func separatesLiveFromBackfilled() {
        let coverage = Self.session(with: [
            (0, .heartbeat), (60, .heartbeat), (120, .advertisement), (420, .history),
        ]).coverage

        #expect(coverage.readings == 4)
        #expect(coverage.highResolution == 3)
        #expect(coverage.backfilled == 1)
        #expect(abs(coverage.liveFraction - 0.75) < 0.001)
    }

    /// The largest gap must be the worst hole, not an average — a single long
    /// outage inside otherwise dense data is exactly what needs surfacing.
    @Test func reportsWorstGapNotAverage() {
        let coverage = Self.session(with: [
            (0, .heartbeat), (60, .heartbeat), (120, .heartbeat),
            (1320, .heartbeat),   // 20-minute outage
            (1380, .heartbeat), (1440, .heartbeat),
        ]).coverage

        #expect(coverage.largestGap == 1200)
        #expect(coverage.readings == 6)
    }

    @Test func readingSourceRoundTripsThroughStorage() {
        for source in ReadingSource.allCases {
            let reading = SensorReading(
                temperatureCelsius: 0, humidityPercent: 0, pressureHPa: 0, source: source
            )
            #expect(reading.readingSource == source)
        }
        // Rows written before the field existed migrate to "" and must not crash.
        let legacy = SensorReading(temperatureCelsius: 0, humidityPercent: 0, pressureHPa: 0)
        legacy.source = ""
        #expect(legacy.readingSource == .unknown)
    }
}
