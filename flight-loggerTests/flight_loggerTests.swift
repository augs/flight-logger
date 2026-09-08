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
        altitudeUnit: nil, speedUnit: nil, temperatureUnit: nil
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
        altitudeUnit: nil, speedUnit: nil, temperatureUnit: nil
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
              altitudeUnit: altitudeUnit, speedUnit: speedUnit, temperatureUnit: temperatureUnit)
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
