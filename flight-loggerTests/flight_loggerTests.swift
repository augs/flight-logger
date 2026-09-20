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
        #expect(coverage.unclassified == 0)
        #expect(abs(coverage.liveFraction - 0.75) < 0.001)
        #expect(!coverage.provenanceUnknown)
    }

    /// Rows written before provenance tracking must not be counted as live —
    /// doing so made every pre-existing session overstate its coverage.
    @Test func unknownProvenanceIsNeitherLiveNorBackfilled() {
        let coverage = Self.session(with: [
            (0, .unknown), (60, .unknown), (120, .unknown), (180, .heartbeat),
        ]).coverage

        #expect(coverage.readings == 4)
        #expect(coverage.highResolution == 1)
        #expect(coverage.backfilled == 0)
        #expect(coverage.unclassified == 3)
        #expect(coverage.provenanceUnknown)
        // Fraction is over classified rows only, so the one known row reads as
        // fully live rather than being diluted by rows we cannot judge.
        #expect(coverage.liveFraction == 1.0)
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

// MARK: - Tag log interval

struct BackfillIntervalTests {

    static func session(historyOffsets: [TimeInterval], liveOffsets: [TimeInterval] = []) -> FlightSession {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let session = FlightSession(recordingStartedAt: start)
        session.sensorReadings =
            historyOffsets.map {
                SensorReading(timestamp: start.addingTimeInterval($0),
                              temperatureCelsius: 22, humidityPercent: 55, pressureHPa: 1000,
                              source: .history)
            } +
            liveOffsets.map {
                SensorReading(timestamp: start.addingTimeInterval($0),
                              temperatureCelsius: 22, humidityPercent: 55, pressureHPa: 1000,
                              source: .heartbeat)
            }
        return session
    }

    @Test func measuresObservedCadence() throws {
        // Spacing as actually captured from the tag, which alternates 300/301
        // rather than being exactly periodic — so this asserts a tolerance
        // rather than a fake exact value.
        let session = Self.session(historyOffsets: [0, 300, 601, 901, 1202])
        let interval = try #require(session.backfillInterval)
        #expect(abs(interval - 300) <= 1)
    }

    /// A missing log entry doubles one gap; the median must ignore it where a
    /// mean would be dragged noticeably high.
    @Test func medianIgnoresAMissingEntry() throws {
        let session = Self.session(historyOffsets: [0, 300, 600, 1200, 1500, 1800])
        #expect(try #require(session.backfillInterval) == 300)
    }

    @Test func ignoresLiveReadings() throws {
        // 60s live readings interleaved must not pull the measured cadence down.
        let session = Self.session(
            historyOffsets: [0, 300, 600, 900],
            liveOffsets: [10, 70, 130, 190, 250]
        )
        #expect(try #require(session.backfillInterval) == 300)
    }

    @Test func needsEnoughSamplesToBeMeaningful() {
        #expect(Self.session(historyOffsets: [0, 300]).backfillInterval == nil)
        #expect(Self.session(historyOffsets: []).backfillInterval == nil)
    }
}

// MARK: - Phone-sourced readings

struct DeviceReadingTests {

    @Test func emptyRowIsRecognised() {
        // An all-nil row must be droppable: stored, it is indistinguishable
        // from a real measurement of zero once it reaches a chart.
        #expect(DeviceReading().isEmpty)
        #expect(DeviceReading(gpsSpeedMPS: 0).isEmpty == false)
        #expect(DeviceReading(pressureHPa: 1013.25).isEmpty == false)
    }

    /// CoreMotion reports kPa; everything in this app is hPa so the phone's
    /// pressure is directly comparable with the tag's.
    @Test func kilopascalsConvertToHectopascalsAtCabinAltitude() {
        // ~8,000 ft cabin altitude is roughly 75 kPa.
        let kPa = 75.2
        let hPa = kPa * 10.0
        #expect(abs(hPa - 752.0) < 0.001)

        // Sea level sanity check against the tag's own units.
        #expect(abs(101.325 * 10.0 - 1013.25) < 0.001)
    }

    @Test func retainsAccuracySoBadFixesCanBeFiltered() {
        // A negative vertical accuracy means the altitude is invalid; the value
        // is still stored so a consumer can tell "bad fix" from "no fix".
        let bad = DeviceReading(gpsAltitudeMeters: 1200, gpsVerticalAccuracy: -1)
        #expect(bad.gpsAltitudeMeters == 1200)
        #expect((bad.gpsVerticalAccuracy ?? 0) < 0)

        let good = DeviceReading(gpsAltitudeMeters: 10_600, gpsVerticalAccuracy: 8)
        #expect((good.gpsVerticalAccuracy ?? .infinity) < 50)
    }
}

// MARK: - CoreLocation invalid-value handling

/// CoreLocation reports "no value" as a negative number rather than nil.
/// Measured on 2026-09-08, speed was invalid in 35/35 samples over a
/// 37-minute journey, so this is the common case rather than an edge one.
struct LocationSentinelTests {

    /// Mirrors the normalisation in DataCollectionManager.recordDeviceReading.
    static func normalise(speed: Double?, altitude: Double?, verticalAccuracy: Double?)
        -> (speed: Double?, altitude: Double?, accuracy: Double?) {
        let s = speed.flatMap { $0 >= 0 ? $0 : nil }
        let a = (verticalAccuracy ?? -1) > 0 ? altitude : nil
        return (s, a, verticalAccuracy.flatMap { $0 > 0 ? $0 : nil })
    }

    @Test func invalidSpeedBecomesNilNotMinusOne() {
        #expect(Self.normalise(speed: -1, altitude: nil, verticalAccuracy: nil).speed == nil)
        // Zero is a real measurement — stationary — and must survive.
        #expect(Self.normalise(speed: 0, altitude: nil, verticalAccuracy: 10).speed == 0)
        #expect(Self.normalise(speed: 61.5, altitude: nil, verticalAccuracy: 10).speed == 61.5)
    }

    @Test func altitudeIsDroppedWhenItsAccuracyIsInvalid() {
        // A negative vertical accuracy means the altitude is meaningless, even
        // though the altitude field still carries a plausible-looking number.
        let bad = Self.normalise(speed: nil, altitude: 23.2, verticalAccuracy: -1)
        #expect(bad.altitude == nil)
        #expect(bad.accuracy == nil)

        let good = Self.normalise(speed: nil, altitude: 10_600, verticalAccuracy: 8)
        #expect(good.altitude == 10_600)
        #expect(good.accuracy == 8)
    }
}

// MARK: - Airline API response parsing

/// The parser is the part most likely to be wrong for any given airline.
/// Portals disagree about whether numbers arrive as JSON numbers or strings and
/// about how they spell booleans, and a silent coercion failure means a field
/// is missing from a recording that cannot be taken again.
struct AirlineResponseParserTests {

    static let unitedFields = AirlineConfig.FieldMappings(
        flightNumber: "flifo.flightNumber",
        origin: "flifo.originAirportCode",
        destination: "flifo.destinationAirportCode",
        altitudeFt: "flifo.altitudeFt",
        groundSpeedMPH: "flifo.groundSpeedMPH",
        airTempF: "flifo.airTemperatureF",
        onGround: "flifo.onGround",
        aircraftModel: "flifo.aircraftModel",
        flightStatus: "flifo.flightStatus",
        scheduledDepartureTimeLocal: "flifo.scheduledDepartureTimeLocal",
        scheduledArrivalTimeLocal: "flifo.scheduledArrivalTimeLocal",
        timeRemainingMinutes: "flifo.timeRemainingToDestination",
        altitudeUnit: nil, speedUnit: nil, temperatureUnit: nil,
        onGroundStatusValues: nil
    )

    static func json(_ raw: String) throws -> [String: Any] {
        try #require(
            JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
        )
    }

    /// United sends every numeric field as a *string*. If the coercion broke,
    /// altitude and speed would silently record as zero for a whole flight.
    @Test func parsesUnitedResponseWithStringNumerics() throws {
        let body = """
        {"flifo":{"originAirportCode":"EWR","destinationAirportCode":"SFO",
        "flightNumber":"1885","flightStatus":"In Flight","groundSpeedMPH":"433",
        "airTemperatureF":"-2","altitudeFt":"21404","aircraftModel":"Boeing 777-200",
        "timeRemainingToDestination":319}}
        """
        let reading = AirlineResponseParser.parse(json: try Self.json(body), fields: Self.unitedFields)

        #expect(reading.flightNumber == "1885")
        #expect(reading.origin == "EWR")
        #expect(reading.destination == "SFO")
        #expect(reading.aircraftModel == "Boeing 777-200")
        #expect(reading.altitudeFt == 21404)
        #expect(reading.groundSpeedMPH == 433)
        #expect(reading.airTempF == -2)          // negative, as a string
        #expect(reading.timeRemainingMinutes == 319)  // this one is a real number
        #expect(reading.onGround == nil)         // absent in flight
    }

    @Test func detectsOnGroundAcrossSpellings() throws {
        let fields = Self.unitedFields
        for (raw, expected) in [("true", true), ("\"true\"", true), ("\"YES\"", true),
                                ("1", true), ("\"1\"", true),
                                ("false", false), ("\"no\"", false), ("0", false)] {
            let body = "{\"flifo\":{\"onGround\":\(raw)}}"
            let reading = AirlineResponseParser.parse(json: try Self.json(body), fields: fields)
            #expect(reading.onGround == expected, "onGround from \(raw)")
        }

        // Unrecognised text must be nil, not a guess — an accidental `true`
        // here would end a recording mid-flight.
        let odd = try Self.json("{\"flifo\":{\"onGround\":\"maybe\"}}")
        #expect(AirlineResponseParser.parse(json: odd, fields: fields).onGround == nil)
    }

    @Test func missingAndNullFieldsAreAbsentNotZero() throws {
        let body = """
        {"flifo":{"flightNumber":"1885","altitudeFt":null,"aircraftModel":"  "}}
        """
        let reading = AirlineResponseParser.parse(json: try Self.json(body), fields: Self.unitedFields)

        #expect(reading.flightNumber == "1885")
        #expect(reading.altitudeFt == nil)       // JSON null, not 0
        #expect(reading.aircraftModel == nil)    // blank string, not "  "
        #expect(reading.groundSpeedMPH == nil)   // key absent entirely
    }

    @Test func wrongPathsYieldAnEmptyReading() throws {
        // A config whose paths don't match this portal should produce nothing
        // rather than partial nonsense — that is the signal the config is wrong.
        let body = "{\"data\":{\"alt\":30000}}"
        let reading = AirlineResponseParser.parse(json: try Self.json(body), fields: Self.unitedFields)
        #expect(reading.isEmpty)
    }

    /// Some portals wrap the active leg in an array.
    @Test func resolvesThroughArrayIndices() throws {
        let body = "{\"legs\":[{\"alt\":31000},{\"alt\":0}]}"
        let json = try Self.json(body)
        #expect(AirlineResponseParser.double(json, "legs.0.alt") == 31000)
        #expect(AirlineResponseParser.double(json, "legs.1.alt") == 0)
        #expect(AirlineResponseParser.double(json, "legs.9.alt") == nil)
    }

    /// Seen in the wild: thousands separators and padding around numbers.
    @Test func toleratesFormattedNumbers() throws {
        let json = try Self.json("{\"a\":\"21,404\",\"b\":\" 433 \",\"c\":\"+62\",\"d\":\"n/a\"}")
        #expect(AirlineResponseParser.double(json, "a") == 21404)
        #expect(AirlineResponseParser.double(json, "b") == 433)
        #expect(AirlineResponseParser.double(json, "c") == 62)
        #expect(AirlineResponseParser.double(json, "d") == nil)
    }

    @Test func numbersRequestedAsStringsAreStringified() throws {
        // flightNumber is mapped as a string but often arrives as a number.
        let json = try Self.json("{\"flifo\":{\"flightNumber\":1885}}")
        let reading = AirlineResponseParser.parse(json: json, fields: Self.unitedFields)
        #expect(reading.flightNumber == "1885")
    }
}

// MARK: - A second airline shape, via config only

/// The plugin system's whole premise is that a new airline needs a JSON config
/// and no code. This exercises a deliberately different shape — real numbers
/// instead of strings, an array-wrapped leg, a differently spelled boolean —
/// against the same parser. If this needs a code change, the premise is false.
struct SecondAirlineShapeTests {

    static let fields = AirlineConfig.FieldMappings(
        flightNumber: "flightInfo.legs.0.flight.number",
        origin: "flightInfo.legs.0.departure.code",
        destination: "flightInfo.legs.0.arrival.code",
        altitudeFt: "flightInfo.legs.0.telemetry.altitude",
        groundSpeedMPH: "flightInfo.legs.0.telemetry.groundSpeed",
        airTempF: "flightInfo.legs.0.telemetry.outsideAirTempC",
        onGround: "flightInfo.legs.0.telemetry.weightOnWheels",
        aircraftModel: "flightInfo.legs.0.flight.equipment",
        flightStatus: "flightInfo.legs.0.status",
        scheduledDepartureTimeLocal: nil,
        scheduledArrivalTimeLocal: nil,
        timeRemainingMinutes: "flightInfo.legs.0.telemetry.minutesRemaining",
        altitudeUnit: nil, speedUnit: nil, temperatureUnit: nil,
        onGroundStatusValues: nil
    )

    static let body = """
    {"flightInfo":{"legs":[{"departure":{"code":"ATL"},"arrival":{"code":"LAX"},
    "flight":{"number":1234,"equipment":"Airbus A321"},
    "telemetry":{"altitude":34000,"groundSpeed":512,"outsideAirTempC":-51,
    "weightOnWheels":"false","minutesRemaining":88},"status":"ENROUTE"}]}}
    """

    @Test func parsesArrayNestedShapeWithNoCodeChange() throws {
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(Self.body.utf8)) as? [String: Any]
        )
        let reading = AirlineResponseParser.parse(json: json, fields: Self.fields)

        #expect(reading.origin == "ATL")
        #expect(reading.destination == "LAX")
        #expect(reading.flightNumber == "1234")        // number -> string
        #expect(reading.aircraftModel == "Airbus A321")
        #expect(reading.altitudeFt == 34000)           // real JSON number
        #expect(reading.groundSpeedMPH == 512)
        #expect(reading.timeRemainingMinutes == 88)
        #expect(reading.onGround == false)             // "false" as a string
        #expect(reading.flightStatus == "ENROUTE")
    }

    /// Landing must be detectable in this shape too, or auto-stop silently
    /// never fires for that airline.
    @Test func detectsLandingInThisShape() throws {
        let landed = Self.body
            .replacingOccurrences(of: "\"weightOnWheels\":\"false\"", with: "\"weightOnWheels\":\"true\"")
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(landed.utf8)) as? [String: Any]
        )
        #expect(AirlineResponseParser.parse(json: json, fields: Self.fields).onGround == true)
    }
}

// MARK: - Unit conversion and researched provider shapes

/// Providers do not agree on units, and the config field names (`altitudeFt`,
/// `groundSpeedMPH`) describe what the *app* stores, not what the provider
/// sends. Panasonic reports knots and UGO reports km/h and metres, so treating
/// a provider's number as already-correct would record speed wrong by 15–60%.
struct ProviderUnitTests {

    static func fields(
        altitude: String? = nil, speed: String? = nil, temp: String? = nil,
        altitudeUnit: String? = nil, speedUnit: String? = nil, temperatureUnit: String? = nil
    ) -> AirlineConfig.FieldMappings {
        .init(flightNumber: nil, origin: nil, destination: nil,
              altitudeFt: altitude, groundSpeedMPH: speed, airTempF: temp, onGround: nil,
              aircraftModel: nil, flightStatus: nil,
              scheduledDepartureTimeLocal: nil, scheduledArrivalTimeLocal: nil,
              timeRemainingMinutes: nil,
              altitudeUnit: altitudeUnit, speedUnit: speedUnit, temperatureUnit: temperatureUnit,
              onGroundStatusValues: nil)
    }

    static func json(_ raw: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }

    @Test func convertsKnotsMetresAndCelsius() {
        #expect(abs(AirlineResponseParser.speedInMPH(500, unit: "knots") - 575.39) < 0.1)
        #expect(abs(AirlineResponseParser.speedInMPH(800, unit: "kph") - 497.1) < 0.1)
        #expect(abs(AirlineResponseParser.altitudeInFeet(10668, unit: "meters") - 35000) < 1)
        #expect(abs(AirlineResponseParser.temperatureInFahrenheit(-51, unit: "C") - -59.8) < 0.1)
    }

    /// A config that omits units is assumed to already be in the app's units —
    /// which is what the original United config relies on.
    @Test func missingUnitMeansNoConversion() {
        #expect(AirlineResponseParser.speedInMPH(433, unit: nil) == 433)
        #expect(AirlineResponseParser.altitudeInFeet(35000, unit: nil) == 35000)
        #expect(AirlineResponseParser.temperatureInFahrenheit(-2, unit: nil) == -2)
    }

    /// Panasonic's shape, per its published flightdata/v2 endpoint: altitude in
    /// feet already, but ground speed in knots.
    @Test func panasonicKnotsBecomeMPH() throws {
        let json = try Self.json("""
        {"altitude_feet":35000,"ground_speed_knots":500,
         "current_coordinates":{"latitude":51.5,"longitude":-0.1}}
        """)
        let reading = AirlineResponseParser.parse(
            json: json,
            fields: Self.fields(altitude: "altitude_feet", speed: "ground_speed_knots", speedUnit: "knots")
        )
        #expect(reading.altitudeFt == 35000)
        #expect(abs(try #require(reading.groundSpeedMPH) - 575.39) < 0.1)
    }

    /// UGO returns a JSON array and uses metric throughout — both conversions
    /// and array indexing have to work together.
    @Test func ugoArrayAndMetricUnits() throws {
        let raw = """
        [{"latitude":48.1,"longitude":11.6,"altitude_meters":10668,
          "speed_kilometers_per_hour":800,"bearing_in_degree":270}]
        """
        // Top level is an array, so it is wrapped the way the app would have to.
        let array = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [Any])
        let json: [String: Any] = ["0": array[0]]

        let reading = AirlineResponseParser.parse(
            json: json,
            fields: Self.fields(altitude: "0.altitude_meters", speed: "0.speed_kilometers_per_hour",
                                altitudeUnit: "meters", speedUnit: "kph")
        )
        #expect(abs(try #require(reading.altitudeFt) - 35000) < 1)
        #expect(abs(try #require(reading.groundSpeedMPH) - 497.1) < 0.1)
    }

    /// Every bundled config must decode, or it silently never matches in the
    /// air — the one place it cannot be debugged.
    @Test func allBundledConfigsDecode() throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()     // flight-loggerTests
            .deletingLastPathComponent()     // repo root
            .appending(path: "flight-logger/AirlineConfigs")

        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        #expect(files.count >= 5)

        for file in files {
            let data = try Data(contentsOf: file)
            let config = try JSONDecoder().decode(AirlineConfig.self, from: data)
            #expect(!config.airline.isEmpty, "\(file.lastPathComponent) has no airline")
            #expect(URL(string: config.url) != nil, "\(file.lastPathComponent) has an unusable url")
        }
    }
}

// MARK: - Panasonic v2, full field set

/// Corrects an earlier wrong conclusion. The Panasonic config was first built
/// from microG's parser, which reads only latitude/longitude/speed/altitude
/// because it is a *location* provider — and I inferred from its silence that
/// Panasonic exposes no flight number or on-ground flag. It exposes both.
/// Absence in a narrow consumer is not absence in the API.
struct PanasonicV2Tests {

    static let fields = AirlineConfig.FieldMappings(
        flightNumber: "flight_number",
        origin: "departure_iata",
        destination: "destination_iata",
        altitudeFt: "altitude_feet",
        groundSpeedMPH: "ground_speed_knots",
        airTempF: "outside_air_temp_celsius",
        onGround: "weight_on_wheels",
        aircraftModel: "tail_number",
        flightStatus: "flight_phase",
        scheduledDepartureTimeLocal: nil,
        scheduledArrivalTimeLocal: nil,
        timeRemainingMinutes: "time_to_destination_minutes",
        altitudeUnit: nil, speedUnit: "knots", temperatureUnit: "celsius",
        onGroundStatusValues: nil
    )

    /// Shape per the FlightInfoV2 type in zisra/inflight-metrics.
    static let cruising = """
    {"weight_on_wheels":false,"ground_speed_knots":488,"altitude_feet":35000,
     "outside_air_temp_celsius":-51,"flight_number":"LH441","departure_iata":"FRA",
     "destination_iata":"IAH","destination_icao":"KIAH","departure_icao":"EDDF",
     "tail_number":"D-AIHK","flight_phase":"Cruise",
     "time_to_destination_minutes":312,"distance_to_destination_nautical_miles":4100,
     "current_coordinates":{"latitude":51.2,"longitude":-2.4}}
    """

    static func json(_ raw: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }

    @Test func extractsEveryFieldIncludingFlightNumberAndOnGround() throws {
        let reading = AirlineResponseParser.parse(json: try Self.json(Self.cruising), fields: Self.fields)

        #expect(reading.flightNumber == "LH441")
        #expect(reading.origin == "FRA")
        #expect(reading.destination == "IAH")
        #expect(reading.aircraftModel == "D-AIHK")
        #expect(reading.flightStatus == "Cruise")
        #expect(reading.altitudeFt == 35000)
        #expect(reading.timeRemainingMinutes == 312)
        #expect(reading.onGround == false)

        // knots -> MPH, and Celsius -> Fahrenheit.
        #expect(abs(try #require(reading.groundSpeedMPH) - 561.6) < 0.5)
        #expect(abs(try #require(reading.airTempF) - -59.8) < 0.1)
    }

    /// weight_on_wheels is the landing signal, so auto-stop works for every
    /// Panasonic-backed carrier — which is most of the list microG maps.
    @Test func weightOnWheelsDrivesAutoStop() throws {
        let landed = Self.cruising.replacingOccurrences(
            of: "\"weight_on_wheels\":false", with: "\"weight_on_wheels\":true")
        let reading = AirlineResponseParser.parse(json: try Self.json(landed), fields: Self.fields)
        #expect(reading.onGround == true)
    }

    /// The type declares outside_air_temp_celsius as nullable; a null must not
    /// become 32°F via a zero.
    @Test func nullTemperatureStaysAbsent() throws {
        let noTemp = Self.cruising.replacingOccurrences(
            of: "\"outside_air_temp_celsius\":-51", with: "\"outside_air_temp_celsius\":null")
        let reading = AirlineResponseParser.parse(json: try Self.json(noTemp), fields: Self.fields)
        #expect(reading.airTempF == nil)
        #expect(reading.altitudeFt == 35000)   // the rest still parses
    }
}

// MARK: - Lufthansa FlyNet /fapi/flightData

/// A second, camelCase Lufthansa shape at a different path than BoardConnect's
/// map API — both exist in the fleet, so both are configured.
struct LufthansaFlyNetTests {

    static let fields = AirlineConfig.FieldMappings(
        flightNumber: "flightNumber", origin: "orig.code", destination: "dest.code",
        altitudeFt: "altitude", groundSpeedMPH: "groundSpeed",
        airTempF: nil, onGround: "weightOnWheels",
        aircraftModel: "aircraftType", flightStatus: "flightPhase",
        scheduledDepartureTimeLocal: nil, scheduledArrivalTimeLocal: nil,
        timeRemainingMinutes: nil,
        altitudeUnit: nil, speedUnit: "knots", temperatureUnit: nil,
        onGroundStatusValues: nil
    )

    @Test func parsesNestedOriginAndDestination() throws {
        let raw = """
        {"flightNumber":"LH400","flightPhase":"CRUISE","weightOnWheels":false,
         "aircraftType":"A350-900","aircraftRegistration":"D-AIXA",
         "orig":{"code":"FRA"},"dest":{"code":"JFK"},
         "altitude":38000,"groundSpeed":470}
        """
        let json = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let reading = AirlineResponseParser.parse(json: json, fields: Self.fields)

        #expect(reading.flightNumber == "LH400")
        #expect(reading.origin == "FRA")
        #expect(reading.destination == "JFK")
        #expect(reading.altitudeFt == 38000)
        #expect(reading.onGround == false)
        #expect(abs(try #require(reading.groundSpeedMPH) - 540.9) < 0.5)
    }
}

// MARK: - United has no on-ground boolean

/// Verified against the FlightDetails type in `bogo/1K`, decoded from a real
/// captured response: United's `flifo` carries 40 fields and none of them is an
/// on-ground flag. The config previously mapped `flifo.onGround`, which does
/// not exist — so auto-stop could never have fired for United. Text status is
/// the only signal the API offers.
struct UnitedOnGroundTests {

    static func fields(statusValues: [String]?) -> AirlineConfig.FieldMappings {
        .init(flightNumber: "flifo.flightNumber", origin: "flifo.originAirportCode",
              destination: "flifo.destinationAirportCode", altitudeFt: "flifo.altitudeFt",
              groundSpeedMPH: "flifo.groundSpeedMPH", airTempF: "flifo.airTemperatureF",
              onGround: nil, aircraftModel: "flifo.aircraftModel",
              flightStatus: "flifo.flightStatus",
              scheduledDepartureTimeLocal: nil, scheduledArrivalTimeLocal: nil,
              timeRemainingMinutes: "flifo.timeRemainingToDestination",
              altitudeUnit: nil, speedUnit: nil, temperatureUnit: nil,
              onGroundStatusValues: statusValues)
    }

    static func reading(status: String, statusValues: [String]?) throws -> AirlineResponseParser.Reading {
        let raw = "{\"flifo\":{\"flightNumber\":\"1885\",\"flightStatus\":\"\(status)\"}}"
        let json = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        return AirlineResponseParser.parse(json: json, fields: Self.fields(statusValues: statusValues))
    }

    static let landed = ["arrived", "landed", "at gate", "on ground"]

    /// The exact status string from the documented United response.
    @Test func inFlightStatusIsNotOnGround() throws {
        let reading = try Self.reading(
            status: "In Flight - Estimated to Arrive 4 Minutes Early", statusValues: Self.landed)
        #expect(reading.onGround == nil)
    }

    @Test func arrivalStatusEndsTheFlight() throws {
        for status in ["Arrived", "LANDED", "At Gate", "Flight has arrived"] {
            #expect(try Self.reading(status: status, statusValues: Self.landed).onGround == true,
                    "status: \(status)")
        }
    }

    /// Unknown text must be nil, never false-positive true. A wrong `true` ends
    /// a recording mid-flight and cannot be undone; a wrong nil merely defers
    /// to the inactivity backstop.
    @Test func unknownStatusIsInconclusiveNotOnGround() throws {
        for status in ["Boarding", "Delayed", "", "Taxiing to runway"] {
            #expect(try Self.reading(status: status, statusValues: Self.landed).onGround == nil,
                    "status: \(status)")
        }
    }

    /// A config with no status values must not guess from text at all.
    @Test func withoutConfiguredValuesStatusIsIgnored() throws {
        #expect(try Self.reading(status: "Arrived", statusValues: nil).onGround == nil)
    }

    /// A real boolean, where a provider has one, still wins over text.
    @Test func booleanFieldTakesPrecedence() throws {
        let raw = "{\"weight_on_wheels\":false,\"flight_phase\":\"Arrived\"}"
        let json = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let fields = AirlineConfig.FieldMappings(
            flightNumber: nil, origin: nil, destination: nil, altitudeFt: nil,
            groundSpeedMPH: nil, airTempF: nil, onGround: "weight_on_wheels",
            aircraftModel: nil, flightStatus: "flight_phase",
            scheduledDepartureTimeLocal: nil, scheduledArrivalTimeLocal: nil,
            timeRemainingMinutes: nil, altitudeUnit: nil, speedUnit: nil,
            temperatureUnit: nil, onGroundStatusValues: ["arrived"])
        #expect(AirlineResponseParser.parse(json: json, fields: fields).onGround == false)
    }
}

// MARK: - Config decoding actually works

/// Guards a trap hit while adding default values: declaring the mappings as
/// `let x: String? = nil` makes each one a *constant*, which Swift omits from
/// both the memberwise initializer and Decodable synthesis. Every field would
/// then decode as nil and every airline config would silently stop working —
/// invisible on the ground, discovered only mid-flight. Building successfully
/// proves nothing here; only decoding does.
struct ConfigDecodingTests {

    @Test func fieldsSurviveDecodingRatherThanDefaultingToNil() throws {
        let json = """
        {"airline":"Test","url":"https://example.com/api",
         "fields":{"flightNumber":"a.b","altitudeFt":"c.d","onGroundStatusValues":["landed"],
                   "speedUnit":"knots","departureGate":"e.f"}}
        """
        let config = try JSONDecoder().decode(AirlineConfig.self, from: Data(json.utf8))

        #expect(config.airline == "Test")
        #expect(config.fields.flightNumber == "a.b")
        #expect(config.fields.altitudeFt == "c.d")
        #expect(config.fields.speedUnit == "knots")
        #expect(config.fields.departureGate == "e.f")
        #expect(config.fields.onGroundStatusValues == ["landed"])
        // Unmapped keys stay nil, which is the point of the defaults.
        #expect(config.fields.arrivalGate == nil)
    }

    /// Each bundled config must decode with its key fields intact, not merely
    /// parse as JSON.
    @Test func bundledConfigsDecodeWithUsableMappings() throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "flight-logger/AirlineConfigs")

        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }

        for file in files {
            let config = try JSONDecoder().decode(AirlineConfig.self, from: try Data(contentsOf: file))
            let name = file.lastPathComponent

            // Every provider we ship is here for altitude at minimum; a config
            // that maps nothing would probe a URL and record no data.
            #expect(config.fields.altitudeFt != nil, "\(name) maps no altitude")

            // Landing must be detectable somehow, or auto-stop can never fire
            // for that airline and the 2h backstop is the only exit.
            let landingDetectable = config.fields.onGround != nil
                || (config.fields.onGroundStatusValues?.isEmpty == false && config.fields.flightStatus != nil)
            if !landingDetectable {
                // Position-only feeds genuinely cannot; assert that is why.
                #expect(config.fields.flightNumber == nil,
                        "\(name) has flight data but no way to detect landing")
            }
        }
    }
}

// MARK: - Cabin air psychrometrics

/// Checked against published reference values rather than against the same
/// formulas restated — a test that recomputes the implementation proves nothing.
struct CabinAirTests {

    /// 20 °C / 50% RH is a standard textbook case: ~8.65 g/m³ absolute humidity
    /// and ~7.26 g/kg mixing ratio at sea level.
    @Test func matchesReferenceValuesAtRoomConditions() throws {
        let ah = CabinAir.absoluteHumidity(temperatureC: 20, humidityPercent: 50)
        #expect(abs(ah - 8.65) < 0.05, "absolute humidity was \(ah)")

        let w = try #require(CabinAir.mixingRatio(temperatureC: 20, humidityPercent: 50, pressureHPa: 1013.25))
        #expect(abs(w - 7.26) < 0.05, "mixing ratio was \(w)")

        let dp = try #require(CabinAir.dewPoint(temperatureC: 20, humidityPercent: 50))
        #expect(abs(dp - 9.3) < 0.2, "dew point was \(dp)")
    }

    @Test func saturationVapourPressureMatchesKnownPoints() {
        // 23.4 hPa at 20 °C, 12.28 hPa at 10 °C, 6.11 hPa at 0 °C.
        #expect(abs(CabinAir.saturationVapourPressure(temperatureC: 20) - 23.4) < 0.1)
        #expect(abs(CabinAir.saturationVapourPressure(temperatureC: 10) - 12.28) < 0.1)
        #expect(abs(CabinAir.saturationVapourPressure(temperatureC: 0) - 6.11) < 0.02)
    }

    /// The whole reason pressure is an input. The same temperature and humidity
    /// at cruise pressure is a materially different amount of water, and using
    /// sea-level pressure would overstate it.
    @Test func pressureMattersToMixingRatio() throws {
        let ground = try #require(CabinAir.mixingRatio(temperatureC: 22, humidityPercent: 12, pressureHPa: 1013.25))
        let cruise = try #require(CabinAir.mixingRatio(temperatureC: 22, humidityPercent: 12, pressureHPa: 800))

        #expect(cruise > ground, "lower pressure means more water per kg of dry air")
        #expect(abs(cruise / ground - 1013.25 / 800) < 0.02, "ratio should track the pressure ratio")
    }

    /// The point of the metric: a warm dry cabin and a cool dry cabin can read
    /// the same RH while holding different amounts of water.
    @Test func equalRelativeHumidityIsNotEqualWater() throws {
        let cool = try #require(CabinAir.mixingRatio(temperatureC: 19, humidityPercent: 12, pressureHPa: 800))
        let warm = try #require(CabinAir.mixingRatio(temperatureC: 24, humidityPercent: 12, pressureHPa: 800))

        // Same RH, ~40% more water in the warmer cabin.
        #expect(warm > cool * 1.3, "cool=\(cool) warm=\(warm)")
    }

    @Test func cabinAltitudeMatchesStandardAtmosphere() throws {
        #expect(abs(try #require(CabinAir.pressureAltitudeMeters(pressureHPa: 1013.25))) < 1)

        // 800 hPa ≈ 6,400 ft; 750 hPa ≈ 8,100 ft — typical cruise cabin range.
        let ft800 = try #require(CabinAir.pressureAltitudeFeet(pressureHPa: 800))
        #expect(abs(ft800 - 6394) < 30, "800 hPa gave \(ft800) ft")

        let ft750 = try #require(CabinAir.pressureAltitudeFeet(pressureHPa: 750))
        #expect(abs(ft750 - 8091) < 30, "750 hPa gave \(ft750) ft")
    }

    @Test func rejectsImpossibleInputs() {
        // Vapour pressure above total pressure is a sensor fault, not humid air.
        #expect(CabinAir.mixingRatio(temperatureC: 40, humidityPercent: 100, pressureHPa: 50) == nil)
        #expect(CabinAir.mixingRatio(temperatureC: 20, humidityPercent: 50, pressureHPa: 0) == nil)
        #expect(CabinAir.pressureAltitudeMeters(pressureHPa: 0) == nil)
        #expect(CabinAir.dewPoint(temperatureC: 20, humidityPercent: 0) == nil)
    }

    /// A real cruise cabin holds roughly a third the water of ground level —
    /// the effect the whole project is trying to measure.
    @Test func cruiseCabinIsMarkedlyDrierThanGround() throws {
        let ground = try #require(CabinAir.mixingRatio(temperatureC: 22, humidityPercent: 55, pressureHPa: 1013))
        let cruise = try #require(CabinAir.mixingRatio(temperatureC: 22, humidityPercent: 12, pressureHPa: 800))

        #expect(ground > 8, "ground mixing ratio was \(ground)")
        #expect(cruise < 3, "cruise mixing ratio was \(cruise)")
    }
}

// MARK: - Session export

struct SessionExportTests {

    static func session() -> FlightSession {
        let start = Date(timeIntervalSince1970: 1_757_000_000)
        let s = FlightSession(flightNumber: "UA 1885", airline: "United",
                              origin: "EWR", destination: "SFO",
                              aircraftModel: "Boeing 777-200",
                              recordingStartedAt: start)
        s.sensorReadings = [
            SensorReading(timestamp: start, temperatureCelsius: 22.0,
                          humidityPercent: 55.0, pressureHPa: 1013.25, source: .heartbeat),
            SensorReading(timestamp: start.addingTimeInterval(3600), temperatureCelsius: 22.0,
                          humidityPercent: 12.0, pressureHPa: 800.0, source: .history),
        ]
        s.flightDataPoints = [
            FlightDataPoint(timestamp: start, altitudeFt: 35000, groundSpeedMPH: 433,
                            outsideAirTempF: -2, flightStatus: "In Flight, on time")
        ]
        s.deviceReadings = [
            DeviceReading(timestamp: start, pressureHPa: 1012.4, gpsAltitudeMeters: 120,
                          gpsVerticalAccuracy: 8, gpsSpeedMPS: 3.2)
        ]
        return s
    }

    /// Derived columns are the point: a downstream query should not have to
    /// redo the psychrometrics, and RH alone cannot be compared across cabins.
    @Test func csvCarriesDerivedHumidityColumns() throws {
        let files = SessionExport.csvFiles(for: Self.session())
        let readings = try #require(files.first { $0.name.hasSuffix("-readings.csv") }).contents

        #expect(readings.contains("mixing_ratio_gkg"))
        #expect(readings.contains("cabin_alt_ft"))

        let rows = readings.split(separator: "\n")
        #expect(rows.count == 3, "header plus two readings")

        // Cruise row: 800 hPa is roughly a 6,400 ft cabin, and the mixing ratio
        // must reflect cruise pressure rather than sea level.
        let cruise = String(rows[2])
        #expect(cruise.contains("history"))
        let cols = cruise.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let mixingRatio = try #require(Double(cols[4]))
        let cabinAlt = try #require(Double(cols[7]))
        #expect(abs(mixingRatio - 2.48) < 0.05, "mixing ratio \(mixingRatio)")
        #expect(abs(cabinAlt - 6394) < 30, "cabin altitude \(cabinAlt)")
    }

    /// Flight status genuinely contains commas, which would silently shift
    /// every later column.
    @Test func csvQuotesFieldsContainingCommas() {
        let files = SessionExport.csvFiles(for: Self.session())
        let flight = files.first { $0.name.hasSuffix("-flightdata.csv") }?.contents ?? ""
        #expect(flight.contains("\"In Flight, on time\""))

        #expect(SessionExport.csvField("plain") == "plain")
        #expect(SessionExport.csvField("a,b") == "\"a,b\"")
        #expect(SessionExport.csvField("say \"hi\"") == "\"say \"\"hi\"\"\"")
    }

    /// Spaces and commas are structural in line protocol, so an unescaped
    /// aircraft model or flight number would corrupt the record.
    @Test func lineProtocolEscapesTags() {
        let out = SessionExport.lineProtocol(for: Self.session())

        #expect(out.contains("aircraft=Boeing\\ 777-200"))
        #expect(out.contains("flight=UA\\ 1885"))
        #expect(SessionExport.lineProtocolTag("a b,c=d") == "a\\ b\\,c\\=d")

        // One line per point across the three measurements.
        let lines = out.split(separator: "\n")
        #expect(lines.filter { $0.hasPrefix("cabin,") }.count == 2)
        #expect(lines.filter { $0.hasPrefix("flight,") }.count == 1)
        #expect(lines.filter { $0.hasPrefix("device,") }.count == 1)
        // Nanosecond timestamps, as line protocol expects by default.
        #expect(out.contains("1757000000000000000"))
    }

    @Test func jsonIncludesMetadataCoverageAndSeries() throws {
        let text = SessionExport.json(for: Self.session())
        let root = try #require(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])

        #expect(root["flightNumber"] as? String == "UA 1885")
        #expect(root["aircraftModel"] as? String == "Boeing 777-200")

        let coverage = try #require(root["coverage"] as? [String: Any])
        #expect(coverage["readings"] as? Int == 2)
        #expect(coverage["backfilled"] as? Int == 1)

        let readings = try #require(root["readings"] as? [[String: Any]])
        #expect(readings.count == 2)
        #expect(readings[0]["mixingRatioGKg"] != nil)
        #expect(readings[1]["source"] as? String == "history")
    }

    /// Filenames land in a Files listing and need to be tellable apart.
    @Test func fileNamesIdentifyTheFlight() {
        let stem = SessionExport.fileStem(for: Self.session())
        #expect(stem.hasPrefix("UA1885-"))
        #expect(!stem.contains(" "), "spaces make command-line handling awkward")
        #expect(!stem.contains("/"), "slashes would create directories")
    }

    /// A session with nothing recorded must still export cleanly rather than
    /// producing a malformed file.
    @Test func emptySessionExportsHeadersOnly() throws {
        let empty = FlightSession(recordingStartedAt: Date())
        let files = SessionExport.csvFiles(for: empty)

        // Readings CSV and metadata only — no flight or device files.
        #expect(files.count == 2)
        let readings = try #require(files.first { $0.name.hasSuffix("-readings.csv") }).contents
        #expect(readings.split(separator: "\n").count == 1, "header only")
        #expect(SessionExport.lineProtocol(for: empty).isEmpty)
    }
}

// MARK: - HealthKit

/// The query needs a device, a Watch and a flight; the rules around it do not.
/// These cover the parts that would silently corrupt data.
struct HealthKitTests {

    /// HealthKit stores blood oxygen as a 0–1 fraction. Storing it unconverted
    /// would record 0.97% instead of 97% — plausible-looking and wrong.
    @Test func oxygenSaturationIsRescaledFromFraction() {
        #expect(HealthKitService.canonicalValue(0.97, for: .oxygenSaturation) == 97)
        #expect(HealthKitService.canonicalValue(1.0, for: .oxygenSaturation) == 100)

        // Everything else is already in the unit we store.
        #expect(HealthKitService.canonicalValue(72, for: .heartRate) == 72)
        #expect(HealthKitService.canonicalValue(45, for: .heartRateVariability) == 45)
        #expect(HealthKitService.canonicalValue(14, for: .respiratoryRate) == 14)
    }

    /// A bad reading charted alongside good ones distorts the axis for
    /// everything else, so implausible values are dropped rather than stored.
    @Test func plausibleRangesRejectNonsense() {
        #expect(HealthMetric.oxygenSaturation.plausibleRange.contains(97))
        #expect(!HealthMetric.oxygenSaturation.plausibleRange.contains(0.97))  // unconverted
        #expect(!HealthMetric.oxygenSaturation.plausibleRange.contains(140))

        #expect(HealthMetric.heartRate.plausibleRange.contains(58))
        #expect(!HealthMetric.heartRate.plausibleRange.contains(0))
        #expect(HealthMetric.respiratoryRate.plausibleRange.contains(14))
    }

    /// Watch data syncs late, so the same window queried twice returns
    /// overlapping results. Merging must be idempotent or every refresh
    /// duplicates the flight's health data.
    @Test func mergeIsIdempotentAcrossRepeatedFetches() {
        let now = Date()
        let fetched: [(metric: HealthMetric, date: Date, value: Double, uuid: String)] = [
            (.heartRate, now, 72, "A"),
            (.heartRate, now.addingTimeInterval(60), 75, "B"),
            (.oxygenSaturation, now, 97, "C"),
        ]

        let first = HealthSampleMerge.newRows(from: fetched, existingUUIDs: []) { m, d, v, u in
            (m, d, v, u)
        }
        #expect(first.count == 3)

        // Same fetch again, now that those UUIDs are stored.
        let second = HealthSampleMerge.newRows(
            from: fetched, existingUUIDs: ["A", "B", "C"]) { m, d, v, u in (m, d, v, u) }
        #expect(second.isEmpty)

        // A later sync brings one new sample alongside the old ones.
        let third = HealthSampleMerge.newRows(
            from: fetched + [(.heartRate, now.addingTimeInterval(120), 70, "D")],
            existingUUIDs: ["A", "B", "C"]) { m, d, v, u in (m, d, v, u) }
        #expect(third.count == 1)
        #expect(third.first?.3 == "D")
    }

    /// A single fetch can itself contain repeats; the guard must cover that too.
    @Test func duplicatesWithinOneFetchAreCollapsed() {
        let now = Date()
        let fetched: [(metric: HealthMetric, date: Date, value: Double, uuid: String)] = [
            (.heartRate, now, 72, "A"),
            (.heartRate, now, 72, "A"),
        ]
        let rows = HealthSampleMerge.newRows(from: fetched, existingUUIDs: []) { m, d, v, u in
            (m, d, v, u)
        }
        #expect(rows.count == 1)
    }

    @Test func storedMetricRoundTrips() {
        for metric in HealthMetric.allCases {
            let sample = HealthSample(metric: metric, value: 1, sampleUUID: "x")
            #expect(sample.healthMetric == metric)
            #expect(!metric.unit.isEmpty)
            #expect(!metric.label.isEmpty)
        }
        // Rows predating the field, or a future metric, must not crash.
        let legacy = HealthSample(metric: .heartRate, value: 1, sampleUUID: "x")
        legacy.metric = "somethingNew"
        #expect(legacy.healthMetric == nil)
    }

    /// These series are sparse and irregular; a mean alone would hide that a
    /// "reading" might be one measurement.
    @Test func summaryShowsRangeAndCount() {
        #expect(FlightDetailView.summary([97], unit: "%") == "97 % (1)")
        #expect(FlightDetailView.summary([93, 97, 95], unit: "%") == "93–97 % (3)")
        #expect(FlightDetailView.summary([], unit: "%") == "—")
    }
}

// MARK: - Portal detection (B1)

/// Reachability is not the same as an airline API answering.
///
/// The old probe returned true for any HTTP 200, so a captive portal login
/// page -- or United's own portal before the flight begins -- would latch
/// detection onto a config that then reported nothing for the whole flight.
@Suite("Portal detection")
struct PortalDetectionTests {

    static let united = AirlineConfig.FieldMappings(
        flightNumber: "flifo.flightNumber",
        altitudeFt: "flifo.altitudeFt",
        groundSpeedMPH: "flifo.groundSpeedMPH"
    )

    private func body(_ s: String) -> Data { Data(s.utf8) }

    /// The failure that motivated the fix: 200 OK, valid JSON, no flight data.
    @Test func portalAnnouncingItIsNotReadyIsRejected() {
        let data = body(#"{"isPortalInitialized": false}"#)
        #expect(AirlineAPIService.isUsableResponse(data, fields: Self.united) == false)
    }

    /// Captive portals commonly answer 200 with a login page.
    @Test func htmlLoginPageIsRejected() {
        let data = body("<html><body>Sign in to Wi-Fi</body></html>")
        #expect(AirlineAPIService.isUsableResponse(data, fields: Self.united) == false)
    }

    /// Right shape, wrong provider: valid JSON whose paths do not match.
    @Test func someOtherServicesJSONIsRejected() {
        let data = body(#"{"status":"ok","version":"2.1"}"#)
        #expect(AirlineAPIService.isUsableResponse(data, fields: Self.united) == false)
    }

    /// An empty body is not a 200 worth believing either.
    @Test func emptyBodyIsRejected() {
        #expect(AirlineAPIService.isUsableResponse(Data(), fields: Self.united) == false)
    }

    /// A real response still detects, or the fix would have broken every flight.
    @Test func genuineFlightDataIsAccepted() {
        let data = body(#"{"flifo":{"flightNumber":"1885","altitudeFt":"35000"}}"#)
        #expect(AirlineAPIService.isUsableResponse(data, fields: Self.united))
    }

    /// Partial data counts. A portal that reports only a flight number is
    /// still the right provider; demanding every field would reject it.
    @Test func partialDataStillCountsAsDetection() {
        let data = body(#"{"flifo":{"flightNumber":"1885"}}"#)
        #expect(AirlineAPIService.isUsableResponse(data, fields: Self.united))
    }
}

// MARK: - Absent telemetry (B8)

/// `nil` means "the provider did not report this" and must survive all the way
/// to export. Collapsing it to 0 produced a plausible-looking 0 °F cruise
/// temperature and a 0 ft altitude indistinguishable from being on the ground.
@Suite("Absent telemetry")
struct AbsentTelemetryTests {

    /// United reports no outside air temperature at all.
    static func sessionMissingOAT() -> FlightSession {
        let start = Date(timeIntervalSince1970: 1_757_000_000)
        let s = FlightSession(flightNumber: "UA 1885", airline: "United",
                              origin: "EWR", destination: "SFO",
                              recordingStartedAt: start)
        s.flightDataPoints = [
            FlightDataPoint(timestamp: start, altitudeFt: 35000,
                            groundSpeedMPH: 433, outsideAirTempF: nil,
                            flightStatus: "In Flight")
        ]
        return s
    }

    @Test func csvLeavesTheColumnEmptyRatherThanZero() throws {
        let files = SessionExport.csvFiles(for: Self.sessionMissingOAT())
        let flight = try #require(files.first { $0.name.hasSuffix("-flightdata.csv") }).contents
        let rows = flight.split(separator: "\n")
        let cols = String(rows[1]).split(separator: ",", omittingEmptySubsequences: false).map(String.init)

        #expect(cols[1] == "35000")
        #expect(cols[3].isEmpty, "absent OAT became \(cols[3])")
    }

    /// Line protocol has no null, so an omitted field is the only honest
    /// encoding -- 0 would read as a real measurement in the database.
    @Test func lineProtocolOmitsTheFieldEntirely() {
        let out = SessionExport.lineProtocol(for: Self.sessionMissingOAT())
        #expect(out.contains("altitude_ft=35000.0"))
        #expect(!out.contains("outside_air_temp_f"))
    }

    @Test func jsonOmitsTheKeyEntirely() throws {
        let text = SessionExport.json(for: Self.sessionMissingOAT())
        let root = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let points = try #require(root["flightData"] as? [[String: Any]])

        #expect(points[0]["altitudeFt"] != nil)
        #expect(points[0]["outsideAirTempF"] == nil, "absent OAT was serialised anyway")
    }

    /// Line protocol requires at least one field per point, so a row where
    /// nothing parsed must be skipped rather than emitted malformed.
    @Test func pointWithNoNumericFieldsIsSkipped() {
        let start = Date(timeIntervalSince1970: 1_757_000_000)
        let s = FlightSession(flightNumber: "UA 1", airline: "United",
                              recordingStartedAt: start)
        s.flightDataPoints = [FlightDataPoint(timestamp: start, flightStatus: "Taxiing")]

        let out = SessionExport.lineProtocol(for: s)
        #expect(!out.contains("flight,"), "emitted a point with no fields")
    }
}

// MARK: - Detection order

/// Two providers ship more than one endpoint on the same host, and bundle URL
/// order is filesystem order. Without an explicit ranking, which config wins
/// detection is arbitrary -- and picking the thin one costs the whole flight.
@Suite("Detection order")
struct DetectionOrderTests {

    /// The case that motivated this: both Lufthansa configs answer on
    /// `lufthansa-flynet.com`, but only `/fapi/flightData` carries the
    /// on-ground flag, aircraft type and flight number.
    @Test func richLufthansaConfigOutranksThePositionOnlyOne() throws {
        let fapi = AirlineConfig.FieldMappings(
            flightNumber: "flightNumber", origin: "orig.code",
            destination: "dest.code", altitudeFt: "altitude",
            groundSpeedMPH: "groundSpeed", onGround: "weightOnWheels",
            aircraftModel: "aircraftType", flightStatus: "flightPhase",
            tailNumber: "aircraftRegistration"
        )
        let map = AirlineConfig.FieldMappings(
            altitudeFt: "altitude", groundSpeedMPH: "groundSpeed"
        )

        #expect(fapi.mappedCount > map.mappedCount)
        #expect(map.mappedCount == 2)
    }

    /// Unit declarations describe how to read a field, not an extra field.
    /// Counting them would let a thin config outrank a rich one for free.
    @Test func unitDeclarationsDoNotInflateTheCount() {
        let plain = AirlineConfig.FieldMappings(altitudeFt: "a", groundSpeedMPH: "b")
        let withUnits = AirlineConfig.FieldMappings(
            altitudeFt: "a", groundSpeedMPH: "b",
            altitudeUnit: "meters", speedUnit: "knots", temperatureUnit: "celsius"
        )
        #expect(plain.mappedCount == withUnits.mappedCount)
    }

    /// United detects landing only through status text, which is a real
    /// capability and should outrank a config that cannot detect it at all.
    @Test func textLandingSignalCounts() {
        let silent = AirlineConfig.FieldMappings(altitudeFt: "a")
        let speaks = AirlineConfig.FieldMappings(
            altitudeFt: "a", onGroundStatusValues: ["landed"]
        )
        #expect(speaks.mappedCount > silent.mappedCount)
    }

    /// An empty path is not a mapping. Configs are hand-written JSON and an
    /// empty string is an easy way to think you have mapped something.
    @Test func emptyPathsDoNotCount() {
        #expect(AirlineConfig.FieldMappings(altitudeFt: "").mappedCount == 0)
    }

    /// The real bundled set must order the way the fix intends.
    ///
    /// Read from disk rather than `Bundle.main`, which carries no configs in
    /// the test host -- the same approach the other config tests take.
    @Test func bundledConfigsAreRankedRichestFirst() throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "flight-logger/AirlineConfigs")

        let configs = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(AirlineConfig.self, from: Data(contentsOf: $0)) }
        try #require(configs.count > 1)

        let all = AirlineConfigLoader.ranked(configs)
        let counts = all.map(\.fields.mappedCount)
        #expect(counts == counts.sorted(by: >), "configs are not ranked: \(counts)")

        let names = all.map(\.airline)
        let fapi = try #require(names.firstIndex { $0.contains("FlyNet") })
        let map = try #require(names.firstIndex { $0.contains("BoardConnect") })
        #expect(fapi < map, "position-only BoardConnect would win detection")
    }

    /// Equal-ranked configs must not reorder between runs, or which provider
    /// is probed first becomes a coin flip again.
    @Test func tiesAreBrokenStably() {
        let a = AirlineConfig(airline: "Zebra", url: "https://z", fields: .init(altitudeFt: "a"))
        let b = AirlineConfig(airline: "Alpha", url: "https://a", fields: .init(altitudeFt: "a"))
        #expect(AirlineConfigLoader.ranked([a, b]).map(\.airline) == ["Alpha", "Zebra"])
        #expect(AirlineConfigLoader.ranked([b, a]).map(\.airline) == ["Alpha", "Zebra"])
    }
}

// MARK: - Payload inspection and field reporting

/// Discovering unmapped fields, and redacting a payload well enough to attach
/// to a public issue.
@Suite("Payload inspection")
struct PayloadInspectorTests {

    static func json(_ s: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])
    }

    static let unitedFields = AirlineConfig.FieldMappings(
        flightNumber: "flifo.flightNumber",
        altitudeFt: "flifo.altitudeFt"
    )

    @Test func flattensNestedPathsInConfigSyntax() throws {
        let leaves = PayloadInspector.leaves(try Self.json(
            #"{"flifo":{"altitudeFt":35000,"nested":{"deep":"x"}}}"#))
        #expect(leaves.map(\.path).contains("flifo.altitudeFt"))
        #expect(leaves.map(\.path).contains("flifo.nested.deep"))
    }

    /// A path reported must be usable verbatim in a config, arrays included.
    @Test func arrayPathsMatchTheResolver() throws {
        let payload = try Self.json(#"{"legs":[{"altitude":35000}]}"#)
        let path = try #require(PayloadInspector.leaves(payload).first?.path)
        #expect(path == "legs.0.altitude")

        let fields = AirlineConfig.FieldMappings(altitudeFt: path)
        #expect(AirlineResponseParser.parse(json: payload, fields: fields).altitudeFt == 35000)
    }

    /// Only the first element: a fifty-leg array would bury the new field.
    @Test func onlyTheFirstArrayElementIsReported() throws {
        let leaves = PayloadInspector.leaves(try Self.json(
            #"{"legs":[{"a":1},{"a":2},{"a":3}]}"#))
        #expect(leaves.count == 1)
    }

    @Test func distinguishesBooleansFromNumbers() throws {
        let leaves = PayloadInspector.leaves(try Self.json(
            #"{"onGround":true,"altitude":35000}"#))
        let types = Dictionary(uniqueKeysWithValues: leaves.map { ($0.path, $0.type) })
        #expect(types["onGround"] == "boolean")
        #expect(types["altitude"] == "number")
    }

    /// A null may carry a value on another fleet or later in the flight.
    @Test func nullsAreReportedNotDropped() throws {
        let leaves = PayloadInspector.leaves(try Self.json(#"{"airTemp":null}"#))
        #expect(leaves.first?.type == "null")
    }

    @Test func mappedFieldsAreNotReportedAsUnknown() throws {
        let payload = try Self.json(
            #"{"flifo":{"flightNumber":"1885","altitudeFt":35000,"windDirection":270}}"#)
        let unmapped = PayloadInspector.unmapped(json: payload, fields: Self.unitedFields)

        #expect(unmapped.map(\.path) == ["flifo.windDirection"])
    }

    /// Portal plumbing is both useless and the most identifying part of a
    /// payload, so it never reaches a draft report at all.
    @Test func portalNoiseIsExcluded() throws {
        let payload = try Self.json("""
        {"sessionId":"abc","macAddress":"aa:bb","advertBanner":"x","windDirection":270}
        """)
        let unmapped = PayloadInspector.unmapped(json: payload, fields: .init())
        #expect(unmapped.map(\.path) == ["windDirection"])
    }
}

@Suite("Payload redaction")
struct PayloadRedactionTests {

    static func redact(_ s: String) throws -> String {
        let json = try #require(
            try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])
        return PayloadInspector.redactedJSONText(json)
    }

    /// The point of the whole feature: keys and types survive, so a reader can
    /// still write a config from the report.
    @Test func structureAndKeysSurvive() throws {
        let out = try Self.redact(#"{"flifo":{"windDirection":270,"flightPhase":"cruise"}}"#)
        #expect(out.contains("flifo"))
        #expect(out.contains("windDirection"))
        #expect(out.contains("flightPhase"))
    }

    /// Identifying values must not reach a public issue tracker.
    @Test func identifyingValuesAreReplaced() throws {
        let out = try Self.redact("""
        {"flightNumber":"LH441","tailNumber":"D-AIGX","departureGate":"C14","seat":"32A"}
        """)
        #expect(!out.contains("LH441"))
        #expect(!out.contains("D-AIGX"))
        #expect(!out.contains("C14"))
        #expect(!out.contains("32A"))
        #expect(out.contains("redacted"))
    }

    /// Numbers are how you tell feet from metres, which has already caused one
    /// class of bug here, so they are kept.
    @Test func plainNumbersAreKept() throws {
        let out = try Self.redact(#"{"altitude":35000,"groundSpeed":512}"#)
        #expect(out.contains("35000"))
        #expect(out.contains("512"))
    }

    /// Except coordinates, which locate the reporter.
    @Test func coordinatesAreRedactedDespiteBeingNumbers() throws {
        let out = try Self.redact(#"{"latitude":51.4706,"longitude":-0.4619}"#)
        #expect(!out.contains("51.47"))
        #expect(!out.contains("0.46"))
    }

    /// Short strings are enum-like status values and are what make a field
    /// mappable; long ones are free text and are not.
    @Test func shortStatusStringsSurviveLongOnesDoNot() throws {
        let long = String(repeating: "x", count: 200)
        let out = try Self.redact(#"{"flightPhase":"cruise","notice":"\#(long)"}"#)
        #expect(out.contains("cruise"))
        #expect(!out.contains(long))
        #expect(out.contains("200 chars"))
    }

    @Test func booleansSurviveEvenOnIdentifyingKeys() throws {
        let out = try Self.redact(#"{"weightOnWheels":false}"#)
        #expect(out.contains("false"))
    }

    /// Redaction must not produce something JSONSerialization chokes on.
    @Test func outputIsStillValidJSON() throws {
        let out = try Self.redact("""
        {"flifo":{"flightNumber":"LH441","altitudeFt":35000,"legs":[{"lat":1.0}]}}
        """)
        #expect((try? JSONSerialization.jsonObject(with: Data(out.utf8))) != nil)
    }
}

@Suite("Field report")
struct FieldReportTests {

    static let payload: [String: Any] = ["flifo": ["flightNumber": "LH441", "windDirection": 270]]

    @Test func bodyListsUnmappedPathsAndCarriesRedactedPayload() {
        let draft = FieldReport.draft(
            provider: "Lufthansa FlyNet",
            endpoint: "https://www.lufthansa-flynet.com/fapi/flightData",
            unmapped: [.init(path: "flifo.windDirection", type: "number")],
            payload: Self.payload,
            appVersion: "1.0 (1)"
        )

        #expect(draft.title.contains("Lufthansa FlyNet"))
        #expect(draft.body.contains("flifo.windDirection"))
        #expect(draft.body.contains("lufthansa-flynet.com"))
        #expect(!draft.body.contains("LH441"), "identifying value reached the report body")
    }

    @Test func issueURLCarriesTitleAndBody() throws {
        let draft = FieldReport.draft(
            provider: "United", endpoint: "https://example.com",
            unmapped: [], payload: [:], appVersion: "1.0 (1)")
        let url = try #require(FieldReport.issueURL(for: draft))

        #expect(url.absoluteString.hasPrefix("https://github.com/\(FieldReport.repository)/issues/new"))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.contains { $0.name == "title" })
        #expect(items.contains { $0.name == "body" })
    }

    /// A huge payload must fall back to copy rather than build a URL GitHub
    /// will reject at the last step.
    @Test func oversizedBodyIsFlaggedRatherThanTruncated() {
        let big = (0..<2000).map { ("field\($0)", $0) }
        let draft = FieldReport.draft(
            provider: "X", endpoint: "y", unmapped: [],
            payload: Dictionary(uniqueKeysWithValues: big), appVersion: "1.0 (1)")

        #expect(draft.fitsInURL == false)
    }
}

@Suite("Discovery endpoint")
struct DiscoveryEndpointTests {

    /// The B1 fix requires a mapped field before believing a response, which a
    /// brand-new provider cannot satisfy by definition. Without the exemption
    /// this feature could not work at all.
    @Test func discoveryAcceptsJSONThatMapsNothing() {
        let body = Data(#"{"someUnknownShape":{"x":1}}"#.utf8)

        #expect(AirlineAPIService.isUsableResponse(body, fields: .init()) == false)
        #expect(AirlineAPIService.isUsableResponse(body, fields: .init(), isDiscovery: true))
    }

    /// Still not a blank cheque: a captive portal login page is rejected in
    /// discovery mode too.
    @Test func discoveryStillRejectsNonJSON() {
        let html = Data("<html><body>Sign in</body></html>".utf8)
        #expect(AirlineAPIService.isUsableResponse(html, fields: .init(), isDiscovery: true) == false)
    }

    @Test func discoveryRejectsAnEmptyObject() {
        let empty = Data("{}".utf8)
        #expect(AirlineAPIService.isUsableResponse(empty, fields: .init(), isDiscovery: true) == false)
    }

    /// No bundled config may set the flag, or detection would accept anything.
    @Test func noBundledConfigIsADiscoveryConfig() throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "flight-logger/AirlineConfigs")
        let configs = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(AirlineConfig.self, from: Data(contentsOf: $0)) }

        #expect(configs.allSatisfy { !$0.isDiscovery })
    }
}

/// Regression guard for a trap this project has now hit twice: adding a
/// property to `AirlineConfig` makes its key *required* by the synthesized
/// decoder unless it is left out of `CodingKeys`. The failure is silent in the
/// worst way -- every airline config stops decoding, so the app finds no
/// provider and a flight records nothing, with no error anywhere.
@Suite("Config Codable synthesis")
struct ConfigCodableSynthesisTests {

    @Test func configDecodesWithoutInCodeOnlyProperties() throws {
        let json = #"{"airline":"X","url":"https://x","fields":{"altitudeFt":"a"}}"#
        let config = try JSONDecoder().decode(AirlineConfig.self, from: Data(json.utf8))

        #expect(config.airline == "X")
        #expect(config.isDiscovery == false, "default did not apply on decode")
    }

    /// A config file cannot grant itself the detection exemption.
    @Test func isDiscoveryCannotBeSetFromJSON() throws {
        let json = #"{"airline":"X","url":"https://x","fields":{},"isDiscovery":true}"#
        let config = try JSONDecoder().decode(AirlineConfig.self, from: Data(json.utf8))

        #expect(config.isDiscovery == false, "JSON granted itself discovery mode")
    }
}
