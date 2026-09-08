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

    /// Fine-grained trace of the last sync attempt: which GATT stage was
    /// reached and how long after the attempt began. Connecting in background
    /// succeeds but frames never arrive, so knowing the exact stall point
    /// matters more than the coarse HistoryState.
    private(set) var historyTrace: String = ""
    private var historyStarted: Date?

    private func trace(_ stage: String) {
        let dt = historyStarted.map { String(format: "%.1f", Date().timeIntervalSince($0)) } ?? "?"
        historyTrace += (historyTrace.isEmpty ? "" : " ") + "\(stage)@\(dt)s"
        logger.info("History stage: \(stage, privacy: .public) @\(dt, privacy: .public)s")
    }

    private static let historyTimeoutSeconds: TimeInterval = 45

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

    /// Count of raw NUS TX notifications seen this sync, for diagnostics.
    private var rawFrameCount = 0

    // MARK: - Persistent link
    //
    // The tag streams DF5 heartbeats (~2s) over NUS while connected. That is
    // both finer than advertisement scanning manages in the foreground and,
    // unlike scanning, a delivery path iOS supports for backgrounded apps —
    // Apple: "While your app is in the background you can still discover and
    // connect to peripherals, and explore and interact with peripheral data."
    // So we hold one connection for the session rather than connecting per
    // sync, and let the tag's own stream drive readings.
    //
    // Cost: the tag has a single connection slot, so holding it locks out
    // Ruuvi Station for the duration of a recording.

    private var linkPeripheral: CBPeripheral?
    private var linkRX: CBCharacteristic?
    /// True once NUS notifications are live and requests can be written.
    private(set) var linkReady = false
    /// Whether we want a link at all — false outside a recording session.
    private var wantsLink = false

    /// Heartbeats arrive every ~2s and advertisements every ~5s — both far
    /// finer than a flight profile needs, and every stored row is a SwiftData
    /// write. Persist at most one reading per this interval regardless of
    /// source. At 2s unthrottled this would be ~1800 writes/hour.
    private var lastRecordedAt: Date?
    static let readingRecordInterval: TimeInterval = 60

    /// Set when a log read is requested before the link is ready.
    private var pendingHistorySince: Date?
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

        wantsLink = true
        lastRecordedAt = nil
        beginScan()
        openLink()
    }

    func stopScanning() {
        centralManager?.stopScan()
        closeLink()
        // Don't nil centralManager — it must persist for background BLE delivery
        flightSession = nil
        modelContext = nil
        onDataReceived = nil
        status = .idle
        logger.info("Scanning stopped")
    }

    // MARK: - Link lifecycle

    /// Open (or reopen) the persistent connection to the tag.
    ///
    /// Uses `retrievePeripherals(withIdentifiers:)` so no scan is needed — the
    /// only way this can work in the background, where scanning delivers
    /// nothing for this tag.
    private func openLink() {
        guard wantsLink, linkPeripheral == nil,
              let cm = centralManager, cm.state == .poweredOn else { return }

        guard let known = knownTagIdentifier,
              let peripheral = cm.retrievePeripherals(withIdentifiers: [known]).first else {
            // Never seen the tag, so it has to be discovered first. Foreground
            // only; beginScan() is already running and didDiscover will call
            // back here once it learns the identifier.
            logger.info("No known tag yet — waiting for discovery before linking")
            return
        }

        linkPeripheral = peripheral
        peripheral.delegate = self
        // iOS 17+: the system reconnects on its own after a drop and wakes us
        // via didConnect, so no reconnect timer of our own is needed.
        cm.connect(peripheral, options: [
            CBConnectPeripheralOptionEnableAutoReconnect: true
        ])
        logger.info("Linking to \(peripheral.name ?? "RuuviTag") (auto-reconnect)")
    }

    private func closeLink() {
        wantsLink = false
        linkReady = false
        pendingHistorySince = nil
        if let peripheral = linkPeripheral {
            // Also cancels any auto-reconnect the system has pending.
            centralManager?.cancelPeripheralConnection(peripheral)
        }
        linkPeripheral = nil
        linkRX = nil
    }

    // MARK: - Scanning

    private func beginScan() {
        guard let cm = centralManager, cm.state == .poweredOn else { return }
        guard flightSession != nil else { return }

        // The link is the primary data source; scanning only bridges the gap
        // before it comes up (and is the only way to learn the tag identifier
        // the first time). Skip it entirely once linked — the tag stops
        // advertising while connected, so it would be pure radio waste.
        guard !linkReady else { return }

        // Must be nil: the tag advertises no service UUIDs, so any filter
        // matches nothing. Consequence — this only works in the foreground,
        // where iOS permits unfiltered scans. See DESIGN.md.
        //
        // allowDuplicates is deliberately off: we throttle to one reading a
        // minute anyway, and duplicate delivery is a documented battery cost.
        cm.scanForPeripherals(withServices: nil, options: nil)
        status = .scanning
        logger.info("Scanning for RuuviTags (unfiltered, fallback)")
    }

    // MARK: - RAWv2 (Data Format 5) Parsing

    /// Parses a RuuviTag RAWv2 (Data Format 5) payload.
    ///
    /// Accepts both lengths this app sees, verified against hardware:
    /// - **24 bytes** — advertisement payload, MAC included.
    /// - **18 bytes** — NUS heartbeat, identical but with the trailing 6-byte
    ///   MAC omitted (the tag streams these while connected).
    ///
    /// Only bytes 0–6 are read, so the previous `>= 24` guard was rejecting
    /// perfectly good heartbeat frames purely on length. Both exact shapes are
    /// matched rather than a loose minimum, so a truncated payload — which is
    /// neither format — is still rejected.
    static func parseRAWv2(_ data: Data) -> (temperature: Double, humidity: Double, pressure: Double)? {
        guard data.count == 18 || data.count >= 24 else { return nil }

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

    /// Record a sensor reading from parsed data, throttled to one row per
    /// `readingRecordInterval` regardless of source.
    private func recordReading(_ parsed: (temperature: Double, humidity: Double, pressure: Double), from peripheralName: String?) {
        guard let session = flightSession, let context = modelContext else {
            logger.warning("BLE data received but no active session")
            return
        }

        if let last = lastRecordedAt,
           Date().timeIntervalSince(last) < Self.readingRecordInterval {
            // Still counts as liveness — the tag is being heard from — but not
            // worth a disk write.
            lastReading = Date()
            status = .found(name: peripheralName ?? "RuuviTag")
            return
        }
        lastRecordedAt = Date()

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

    /// Request the tag's onboard log and merge it into the active session.
    ///
    /// Issued over the persistent link rather than a connection of its own. If
    /// the link isn't ready yet the request is queued and sent as soon as
    /// notifications come up.
    ///
    /// Requires the tag's single connection slot; if another app (typically
    /// Ruuvi Station) holds it, the link never establishes and this times out.
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
        rawFrameCount = 0
        historyState = .connecting
        historyStarted = Date()
        historyTrace = ""

        historyTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.historyTimeoutSeconds))
            guard !Task.isCancelled else { return }
            self?.finishHistorySync(error: "Timed out — is another app connected to the tag?")
        }

        if linkReady {
            trace("link-ready")
            sendHistoryRequest()
        } else {
            // Link will carry it once notifications are live.
            trace("awaiting-link")
            pendingHistorySince = since
            openLink()
        }
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

    private func sendHistoryRequest() {
        guard let peripheral = linkPeripheral, let rx = linkRX else { return }
        pendingHistorySince = nil
        historyState = .downloading(frames: 0)

        let request = RuuviHistoryProtocol.logReadRequest(since: historySince)
        let hex = request.map { String(format: "%02X", $0) }.joined(separator: " ")
        logger.info("History request bytes: \(hex, privacy: .public)")
        peripheral.writeValue(request, for: rx, type: .withResponse)
    }

    /// Persist whatever arrived and reset sync state. The link is left open.
    private func finishHistorySync(error: String? = nil) {
        historyTimeout?.cancel()
        historyTimeout = nil
        pendingHistorySince = nil

        var saved = 0
        if let error {
            lastSyncResult = .failed(reason: error, at: Date())
            logger.error("History sync failed: \(error, privacy: .public)")
        } else {
            saved = persistHistory()
            lastSyncResult = .merged(count: saved, at: Date())
        }

        historySamples = []
        // Always return to .idle, including after a failure — otherwise the
        // `guard historyState == .idle` in syncHistory would block every future
        // retry. The failure is preserved in `lastSyncResult` instead.
        historyState = .idle

        let completion = historyCompletion
        historyCompletion = nil
        completion?(saved)
    }

    /// Merge downloaded entries into the session, skipping timestamps we
    /// already have from heartbeats or advertisements.
    private func persistHistory() -> Int {
        guard let session = flightSession, let context = modelContext else { return 0 }

        let entries = RuuviHistoryProtocol.assemble(historySamples)
            .filter { $0.timestamp >= historySince }
        guard !entries.isEmpty else { return 0 }

        // Live readings and log entries will overlap. Dedupe on whole seconds —
        // the tag logs at fixed intervals, so exact-match timestamps are the
        // right granularity.
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

        // Reclaim a connection the system restored on our behalf, so the link
        // isn't abandoned after the app is relaunched mid-session.
        if let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let peripheral = restored.first {
            linkPeripheral = peripheral
            peripheral.delegate = self
            logger.info("Restored link to \(peripheral.name ?? "RuuviTag")")
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        logger.info("Bluetooth state: \(String(describing: central.state.rawValue))")
        switch central.state {
        case .poweredOn:
            beginScan()
            openLink()
        case .poweredOff:
            status = .bluetoothOff
            linkReady = false
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

        // Remember the tag so the link can be opened without scanning — the
        // only route that works in the background.
        if knownTagIdentifier != peripheral.identifier {
            knownTagIdentifier = peripheral.identifier
            logger.info("Remembered RuuviTag \(peripheral.identifier, privacy: .public)")
            openLink()
        }

        let payload = manufacturerData.dropFirst(2)
        guard let parsed = Self.parseRAWv2(Data(payload)) else { return }

        recordReading(parsed, from: peripheral.name)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === linkPeripheral else { return }
        trace("connected")
        logger.info("Link connected — discovering NUS")
        // The tag stops advertising while connected, so scanning can only waste
        // radio time from here.
        central.stopScan()
        peripheral.discoverServices([Self.nusServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        guard peripheral === linkPeripheral else { return }
        logger.error("Link failed: \(error?.localizedDescription ?? "unknown", privacy: .public)")
        linkReady = false
        if historyState != .idle {
            finishHistorySync(error: error?.localizedDescription ?? "Could not connect to tag")
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        guard peripheral === linkPeripheral else { return }
        linkReady = false
        linkRX = nil
        logger.info("Link dropped: \(error?.localizedDescription ?? "clean", privacy: .public)")

        // A disconnect mid-download ends the sync; whatever arrived is kept.
        if case .downloading = historyState {
            finishHistorySync()
        }

        if wantsLink {
            // Auto-reconnect means the system retries on its own; fall back to
            // advertisement scanning meanwhile so the foreground keeps data.
            beginScan()
        } else {
            // Cancel again to clear any auto-reconnect the system has pending.
            central.cancelPeripheralConnection(peripheral)
            linkPeripheral = nil
        }
    }
}

// MARK: - CBPeripheralDelegate

extension RuuviTagScanner: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        if let error {
            logger.error("Service discovery failed: \(error.localizedDescription, privacy: .public)")
            if historyState != .idle { finishHistorySync(error: error.localizedDescription) }
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.nusServiceUUID }) else {
            if historyState != .idle {
                finishHistorySync(error: "Tag has no NUS service — unsupported firmware")
            }
            return
        }
        trace("services")
        peripheral.discoverCharacteristics([Self.nusRXCharUUID, Self.nusTXCharUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        if let error {
            logger.error("Characteristic discovery failed: \(error.localizedDescription, privacy: .public)")
            if historyState != .idle { finishHistorySync(error: error.localizedDescription) }
            return
        }
        guard let rx = service.characteristics?.first(where: { $0.uuid == Self.nusRXCharUUID }),
              let tx = service.characteristics?.first(where: { $0.uuid == Self.nusTXCharUUID }) else {
            if historyState != .idle { finishHistorySync(error: "NUS characteristics not found") }
            return
        }
        linkRX = rx
        trace("chars")
        // Heartbeats and any log reply both arrive on this subscription.
        peripheral.setNotifyValue(true, for: tx)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: (any Error)?) {
        if let error {
            logger.error("Notification subscription failed: \(error.localizedDescription, privacy: .public)")
            if historyState != .idle { finishHistorySync(error: error.localizedDescription) }
            return
        }
        guard characteristic.isNotifying else { return }

        linkReady = true
        trace("notifying")
        logger.info("Link ready — heartbeats streaming")
        status = .found(name: peripheral.name ?? "RuuviTag")

        if pendingHistorySince != nil {
            sendHistoryRequest()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        if let error {
            // Previously unhandled, so a rejected write looked identical to the
            // tag simply not answering.
            finishHistorySync(error: "Log request rejected: \(error.localizedDescription)")
        } else {
            trace("written")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        if let error {
            logger.error("Characteristic update error: \(error.localizedDescription, privacy: .public)")
        }
        guard characteristic.uuid == Self.nusTXCharUUID, let data = characteristic.value else { return }

        rawFrameCount += 1
        if rawFrameCount <= 4 {
            let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
            logger.info("TX frame \(self.rawFrameCount) len=\(data.count) \(hex, privacy: .public)")
        }

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
            // Not a log frame: a DF5 heartbeat carrying the tag's current
            // reading, streamed ~2s apart while connected. Throttle to the
            // configured interval — 2s resolution is far more than a flight
            // profile needs, and every row is a SwiftData write.
            recordHeartbeat(data, from: peripheral.name)
        }
    }

    private func recordHeartbeat(_ data: Data, from name: String?) {
        guard let parsed = Self.parseRAWv2(data) else { return }
        recordReading(parsed, from: name)
    }
}
