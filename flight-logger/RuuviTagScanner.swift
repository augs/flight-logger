//
//  RuuviTagScanner.swift
//  flight-logger
//
//  Created by august huber on 4/4/26.
//

import Foundation
import CoreBluetooth
import SwiftData
import Observation
import os

/// Scans for RuuviTag BLE advertisement packets (RAWv2 / Data Format 5)
/// and creates SensorReading records for the active flight session.
///
/// Advertisement-only by design. Connecting to a RuuviTag is destructive to
/// live logging: iOS stops delivering `didDiscover` for a connected peripheral,
/// and the tag's firmware stops advertising once a central connects — so a
/// connection silently terminates the data stream this class depends on.
/// Bulk history retrieval over GATT is a separate, deliberately scheduled
/// operation and does not belong here (see TODO.md P1 #6).
@Observable
final class RuuviTagScanner: NSObject {

    enum ScanStatus: Equatable {
        case idle
        case scanning
        case found(name: String)
        case bluetoothOff
        case unauthorized
        case unavailable
    }

    private(set) var status: ScanStatus = .idle
    private(set) var lastReading: Date?

    /// Number of readings persisted this session. Logged periodically at info
    /// level so collection can be verified from device logs — including while
    /// the screen is locked, where nothing else is observable.
    private(set) var readingCount = 0

    private var discoveryCount = 0
    private var ruuviDiscoveryCount = 0

    /// Set when persisting a reading fails, so the UI can surface that
    /// data is being lost rather than failing silently.
    private(set) var persistenceError: String?

    /// Called each time a sensor reading is recorded — used by
    /// DataCollectionManager to piggyback API polls in background.
    var onDataReceived: (() -> Void)?

    private var centralManager: CBCentralManager?
    private var flightSession: FlightSession?
    private var modelContext: ModelContext?

    private let logger = Logger(subsystem: "org.pbx.flight-logger", category: "BLE")

    /// Ruuvi Innovations Bluetooth SIG company ID (little-endian: 0x0499)
    private static let ruuviCompanyId: UInt16 = 0x0499

    /// Nordic UART Service UUID — used for GATT history, never for scanning.
    ///
    /// Verified against hardware 2026-09-07: a RuuviTag in RAWv2 broadcast mode
    /// advertises **no service UUIDs at all**, in neither the advertisement nor
    /// the scan response. Scanning with `[nusServiceUUID]` discovers the tag
    /// zero times; scanning with `nil` discovers it immediately. Do not
    /// reintroduce a service filter here.
    private static let nusServiceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")

    /// NUS RX — we write log-read commands here.
    private static let nusRXCharUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")

    /// NUS TX — the tag streams log frames back on this characteristic.
    private static let nusTXCharUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

    /// Restore identifier for CoreBluetooth state preservation.
    private static let restoreIdentifier = "com.flight-logger.ruuvi-scanner"

    // MARK: - History sync state

    /// History sync is a deliberate, explicitly triggered mode — never
    /// automatic. Connecting stops the tag advertising, so this must not run
    /// concurrently with live scanning; `syncHistory` owns that transition.
    enum HistoryState: Equatable {
        case idle
        case connecting
        case downloading(frames: Int)
        case failed(String)
    }

    /// Outcome of the most recent history sync, for the dashboard to surface.
    enum SyncResult: Equatable {
        case never
        case merged(count: Int, at: Date)
        case failed(reason: String, at: Date)
    }

    private(set) var historyState: HistoryState = .idle
    private(set) var lastSyncResult: SyncResult = .never

    private static let historyTimeoutSeconds: TimeInterval = 30

    /// Identifier of a tag we've seen before, persisted so history sync can
    /// connect without scanning — which is the only way it can work in the
    /// background.
    private var knownTagIdentifier: UUID? {
        get {
            guard let s = UserDefaults.standard.string(forKey: Self.knownTagKey) else { return nil }
            return UUID(uuidString: s)
        }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: Self.knownTagKey) }
    }

    private static let knownTagKey = "knownRuuviTagIdentifier"

    private var historyPeripheral: CBPeripheral?
    private var historyRXChar: CBCharacteristic?
    private var historySamples: [RuuviHistoryProtocol.Sample] = []
    private var historySince: Date = .distantPast
    private var historyCompletion: ((Int) -> Void)?
    private var historyTimeout: Task<Void, Never>?
    private var wasScanningBeforeSync = false

    // MARK: - Initialization

    override init() {
        super.init()
        // Create the CBCentralManager eagerly so it persists for background
        // delivery and state restoration. It won't start scanning until
        // startScanning() provides a flight session.
        if Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") != nil {
            centralManager = CBCentralManager(
                delegate: self,
                queue: .main,
                options: [
                    CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier
                ]
            )
            logger.info("CBCentralManager created with restore identifier")
        } else {
            status = .unavailable
            logger.error("NSBluetoothAlwaysUsageDescription missing — BLE unavailable")
        }
    }

    // MARK: - Public API

    func startScanning(flightSession: FlightSession, modelContext: ModelContext) {
        self.flightSession = flightSession
        self.modelContext = modelContext
        self.persistenceError = nil
        // Per-session counters; leaving these stale made a new session appear
        // to have readings that actually belonged to the previous one.
        self.readingCount = 0
        self.discoveryCount = 0
        self.ruuviDiscoveryCount = 0
        self.lastReading = nil

        let auth = CBCentralManager.authorization
        if auth == .denied || auth == .restricted {
            status = .unauthorized
            logger.warning("Bluetooth authorization denied")
            return
        }

        beginScan()
    }

    func stopScanning() {
        centralManager?.stopScan()
        // Don't nil centralManager — it must persist for background BLE delivery
        flightSession = nil
        modelContext = nil
        onDataReceived = nil
        status = .idle
        logger.info("Scanning stopped")
    }

    // MARK: - Scanning

    private func beginScan() {
        guard let cm = centralManager, cm.state == .poweredOn else { return }
        guard flightSession != nil else { return }

        // Must be nil: the tag advertises no service UUIDs, so any filter
        // matches nothing. Consequence — this only works in the foreground,
        // where iOS permits unfiltered scans. See DESIGN.md.
        cm.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: true
        ])
        status = .scanning
        logger.info("Scanning for RuuviTags (unfiltered)")
    }

    // MARK: - RAWv2 (Data Format 5) Parsing

    /// Parses a RuuviTag RAWv2 manufacturer data payload.
    static func parseRAWv2(_ data: Data) -> (temperature: Double, humidity: Double, pressure: Double)? {
        guard data.count >= 24 else { return nil }

        let bytes = [UInt8](data)

        guard bytes[0] == 0x05 else { return nil }

        let rawTemp = Int16(bitPattern: UInt16(bytes[1]) << 8 | UInt16(bytes[2]))
        guard rawTemp != -32768 else { return nil }
        let temperature = Double(rawTemp) * 0.005

        let rawHumidity = UInt16(bytes[3]) << 8 | UInt16(bytes[4])
        guard rawHumidity != 0xFFFF else { return nil }
        let humidity = Double(rawHumidity) * 0.0025

        let rawPressure = UInt16(bytes[5]) << 8 | UInt16(bytes[6])
        guard rawPressure != 0xFFFF else { return nil }
        let pressure = (Double(rawPressure) + 50000.0) / 100.0

        return (temperature, humidity, pressure)
    }

    /// Record a sensor reading from parsed data.
    private func recordReading(_ parsed: (temperature: Double, humidity: Double, pressure: Double), from peripheralName: String?) {
        guard let session = flightSession, let context = modelContext else {
            logger.warning("BLE data received but no active session")
            return
        }

        let reading = SensorReading(
            temperatureCelsius: parsed.temperature,
            humidityPercent: parsed.humidity,
            pressureHPa: parsed.pressure,
            session: session
        )
        context.insert(reading)

        do {
            try context.save()
            persistenceError = nil
        } catch {
            // Most likely cause is data protection blocking the store while the
            // screen is locked. Never swallow this — an entire flight can be
            // lost otherwise.
            persistenceError = error.localizedDescription
            logger.error("Failed to save sensor reading: \(error.localizedDescription, privacy: .public)")
            return
        }

        lastReading = Date()
        readingCount += 1
        onDataReceived?()

        let name = peripheralName ?? "RuuviTag"
        let summary = String(format: "%.1f°C %.0f%% %.0fhPa", parsed.temperature, parsed.humidity, parsed.pressure)
        // First reading and every 10th at info level: enough to confirm
        // collection is alive from a log stream without flooding it.
        if readingCount == 1 || readingCount % 10 == 0 {
            logger.info("Reading #\(self.readingCount) saved: \(summary, privacy: .public)")
        } else {
            logger.debug("Sensor reading recorded: \(summary)")
        }
        status = .found(name: name)
    }

    // MARK: - History Sync

    /// Download the tag's onboard log and merge it into the active session.
    ///
    /// This connects to the tag, which stops it advertising — so live scanning
    /// is suspended for the duration and resumed afterwards.
    ///
    /// Works in the background, unlike live scanning. Once we've seen the tag
    /// even once, its identifier is remembered and
    /// `retrievePeripherals(withIdentifiers:)` gives us a peripheral to connect
    /// to directly — no scan required. That matters because background scans
    /// deliver nothing for this tag (see DESIGN.md), so a scan-based sync could
    /// only ever have worked in the foreground.
    ///
    /// Requires the tag's single connection slot to be free; if another app
    /// (typically Ruuvi Station) holds it, this fails rather than hanging.
    func syncHistory(since: Date, completion: ((Int) -> Void)? = nil) {
        guard let cm = centralManager, cm.state == .poweredOn else {
            completion?(0)
            return
        }
        guard historyState == .idle else {
            logger.info("History sync already in progress")
            completion?(0)
            return
        }

        historySince = since
        historyCompletion = completion
        historySamples = []
        historyState = .connecting
        wasScanningBeforeSync = (status == .scanning || isFound(status))

        // Suspend live scanning — a connection would silently kill it anyway.
        cm.stopScan()

        historyTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.historyTimeoutSeconds))
            guard !Task.isCancelled else { return }
            self?.finishHistorySync(error: "Timed out — is another app connected to the tag?")
        }

        // Preferred path: connect to the remembered tag without scanning.
        if let known = knownTagIdentifier,
           let peripheral = cm.retrievePeripherals(withIdentifiers: [known]).first {
            logger.info("History sync: connecting to known tag (no scan)")
            connectForHistory(peripheral)
            return
        }

        // Fallback: we've never seen the tag, so we have to discover it first.
        // Only viable in the foreground.
        cm.scanForPeripherals(withServices: nil, options: nil)
        logger.info("History sync: no known tag, scanning to discover one")
    }

    /// Manually trigger a sync for the whole active session. Exposed for the
    /// dashboard's retry affordance when a sync failed.
    func syncHistoryForActiveSession(completion: ((Int) -> Void)? = nil) {
        guard let session = flightSession else {
            completion?(0)
            return
        }
        syncHistory(since: session.recordingStartedAt, completion: completion)
    }

    private func isFound(_ status: ScanStatus) -> Bool {
        if case .found = status { return true }
        return false
    }

    private func beginHistoryConnection(to peripheral: CBPeripheral, connectable: Bool) {
        guard historyState == .connecting, historyPeripheral == nil else { return }

        // Verified against hardware: while another central holds the tag's
        // single connection slot it advertises non-connectable, and `connect`
        // then hangs silently until timeout rather than failing. Fail fast with
        // something the user can act on.
        guard connectable else {
            finishHistorySync(error: "Tag is busy — another app (e.g. Ruuvi Station) is connected to it")
            return
        }

        connectForHistory(peripheral)
    }

    private func connectForHistory(_ peripheral: CBPeripheral) {
        historyPeripheral = peripheral
        peripheral.delegate = self
        centralManager?.stopScan()
        centralManager?.connect(peripheral, options: nil)
        logger.info("History sync: connecting to \(peripheral.name ?? "RuuviTag")")
    }

    /// Persist assembled entries, then tear down and resume live scanning.
    private func finishHistorySync(error: String? = nil) {
        historyTimeout?.cancel()
        historyTimeout = nil

        var saved = 0
        if let error {
            historyState = .failed(error)
            lastSyncResult = .failed(reason: error, at: Date())
            logger.error("History sync failed: \(error, privacy: .public)")
        } else {
            saved = persistHistory()
            lastSyncResult = .merged(count: saved, at: Date())
        }

        if let peripheral = historyPeripheral {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
        historyPeripheral = nil
        historyRXChar = nil
        historySamples = []

        // Always return to .idle, including after a failure — otherwise the
        // `guard historyState == .idle` in syncHistory would block every future
        // retry. The failure is preserved in `lastSyncResult` instead.
        historyState = .idle

        let completion = historyCompletion
        historyCompletion = nil

        // Resume live advertisement scanning if it was running before.
        if wasScanningBeforeSync {
            beginScan()
        }
        wasScanningBeforeSync = false

        completion?(saved)
    }

    /// Merge downloaded entries into the session, skipping timestamps we
    /// already have from advertisements.
    private func persistHistory() -> Int {
        guard let session = flightSession, let context = modelContext else { return 0 }

        let entries = RuuviHistoryProtocol.assemble(historySamples)
            .filter { $0.timestamp >= historySince }
        guard !entries.isEmpty else { return 0 }

        // Advertisement-derived readings and log entries will overlap. Dedupe
        // on whole seconds — the tag logs at fixed intervals, so exact-match
        // timestamps are the right granularity.
        let existing = Set(session.sensorReadings.map { Int($0.timestamp.timeIntervalSince1970) })

        var inserted = 0
        for entry in entries {
            let key = Int(entry.timestamp.timeIntervalSince1970)
            guard !existing.contains(key) else { continue }

            let reading = SensorReading(
                timestamp: entry.timestamp,
                temperatureCelsius: entry.temperatureCelsius,
                humidityPercent: entry.humidityPercent,
                pressureHPa: entry.pressureHPa,
                session: session
            )
            context.insert(reading)
            inserted += 1
        }

        do {
            try context.save()
            persistenceError = nil
        } catch {
            persistenceError = error.localizedDescription
            logger.error("Failed to save history: \(error.localizedDescription, privacy: .public)")
            return 0
        }

        logger.info("History sync merged \(inserted) of \(entries.count) entries")
        return inserted
    }
}

// MARK: - CBCentralManagerDelegate

extension RuuviTagScanner: CBCentralManagerDelegate {

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        logger.info("CoreBluetooth state restored")
        centralManager = central
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        logger.info("Bluetooth state: \(String(describing: central.state.rawValue))")
        switch central.state {
        case .poweredOn:
            beginScan()
        case .poweredOff:
            status = .bluetoothOff
        case .unauthorized:
            status = .unauthorized
        default:
            break
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        // Diagnostic: distinguishes "CoreBluetooth is delivering nothing"
        // (e.g. suppressed in background) from "the tag isn't being seen".
        discoveryCount += 1
        if discoveryCount % 50 == 0 {
            logger.info("Discoveries: \(self.discoveryCount) total, \(self.ruuviDiscoveryCount) from RuuviTags")
        }

        guard let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              manufacturerData.count >= 2 else { return }

        let companyId = UInt16(manufacturerData[0]) | UInt16(manufacturerData[1]) << 8
        guard companyId == Self.ruuviCompanyId else { return }

        ruuviDiscoveryCount += 1

        // Remember the tag so a later sync can connect without scanning.
        if knownTagIdentifier != peripheral.identifier {
            knownTagIdentifier = peripheral.identifier
            logger.info("Remembered RuuviTag \(peripheral.identifier, privacy: .public)")
        }

        // In history mode we're hunting for a tag to connect to, not logging.
        if historyState == .connecting {
            let connectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? false
            beginHistoryConnection(to: peripheral, connectable: connectable)
            return
        }

        let payload = manufacturerData.dropFirst(2)
        guard let parsed = Self.parseRAWv2(Data(payload)) else { return }

        recordReading(parsed, from: peripheral.name)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === historyPeripheral else { return }
        historyState = .downloading(frames: 0)
        logger.info("History sync: connected, discovering NUS")
        peripheral.discoverServices([Self.nusServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        guard peripheral === historyPeripheral else { return }
        finishHistorySync(error: error?.localizedDescription ?? "Connection failed")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        guard peripheral === historyPeripheral else { return }
        // A disconnect mid-download ends the sync; whatever arrived is kept.
        if case .downloading = historyState {
            finishHistorySync()
        }
    }
}

// MARK: - CBPeripheralDelegate (history sync only)

extension RuuviTagScanner: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        if let error {
            finishHistorySync(error: error.localizedDescription)
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.nusServiceUUID }) else {
            finishHistorySync(error: "Tag has no NUS service — history unsupported on this firmware")
            return
        }
        peripheral.discoverCharacteristics([Self.nusRXCharUUID, Self.nusTXCharUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        if let error {
            finishHistorySync(error: error.localizedDescription)
            return
        }
        guard let rx = service.characteristics?.first(where: { $0.uuid == Self.nusRXCharUUID }),
              let tx = service.characteristics?.first(where: { $0.uuid == Self.nusTXCharUUID }) else {
            finishHistorySync(error: "NUS characteristics not found")
            return
        }
        historyRXChar = rx
        // The log request goes out only once notifications are actually live,
        // otherwise the reply stream is missed.
        peripheral.setNotifyValue(true, for: tx)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: (any Error)?) {
        if let error {
            finishHistorySync(error: error.localizedDescription)
            return
        }
        guard characteristic.isNotifying, let rx = historyRXChar else { return }

        let request = RuuviHistoryProtocol.logReadRequest(since: historySince)
        peripheral.writeValue(request, for: rx, type: .withResponse)
        logger.info("History sync: requested log since \(self.historySince, privacy: .public)")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard characteristic.uuid == Self.nusTXCharUUID, let data = characteristic.value else { return }

        switch RuuviHistoryProtocol.parse(data) {
        case .sample(let sample):
            historySamples.append(sample)
            historyState = .downloading(frames: historySamples.count)
        case .endOfData:
            logger.info("History sync: end of data, \(self.historySamples.count) frames")
            finishHistorySync()
        case .error:
            finishHistorySync(error: "Tag reported a log-read error")
        case nil:
            break  // unrecognized frame — ignore
        }
    }
}
