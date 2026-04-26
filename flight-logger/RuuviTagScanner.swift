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

/// Scans for RuuviTag BLE advertisement packets (RAWv2 / Data Format 5),
/// connects to discovered tags for reliable background delivery, and
/// creates SensorReading records for the active flight session.
@Observable
final class RuuviTagScanner: NSObject {

    enum ScanStatus: Equatable {
        case idle
        case scanning
        case found(name: String)
        case connected(name: String)
        case bluetoothOff
        case unauthorized
        case unavailable
    }

    private(set) var status: ScanStatus = .idle
    private(set) var lastReading: Date?

    /// Called each time a sensor reading is recorded — used by
    /// DataCollectionManager to piggyback API polls in background.
    var onDataReceived: (() -> Void)?

    private var centralManager: CBCentralManager?
    private var connectedPeripheral: CBPeripheral?
    private var flightSession: FlightSession?
    private var modelContext: ModelContext?

    private let logger = Logger(subsystem: "org.pbx.flight-logger", category: "BLE")

    /// Ruuvi Innovations Bluetooth SIG company ID (little-endian: 0x0499)
    private static let ruuviCompanyId: UInt16 = 0x0499

    /// Nordic UART Service UUID — RuuviTags advertise this in their scan response.
    /// Scanning for this specific UUID enables reliable background BLE delivery.
    private static let nusServiceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")

    /// NUS TX Characteristic — subscribe for active data notifications.
    private static let nusTXCharUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

    /// Restore identifier for CoreBluetooth state preservation.
    private static let restoreIdentifier = "com.flight-logger.ruuvi-scanner"

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
        }
    }

    // MARK: - Public API

    func startScanning(flightSession: FlightSession, modelContext: ModelContext) {
        self.flightSession = flightSession
        self.modelContext = modelContext

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
        if let peripheral = connectedPeripheral {
            centralManager?.cancelPeripheralConnection(peripheral)
            connectedPeripheral = nil
        }
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

        // Scan for the Nordic UART Service UUID that RuuviTags advertise.
        // Scanning with a specific service UUID (vs nil) is critical for
        // reliable background BLE delivery on iOS.
        cm.scanForPeripherals(withServices: [Self.nusServiceUUID], options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: true
        ])
        status = .scanning
        logger.info("Scanning for RuuviTags (NUS service UUID)")
    }

    // MARK: - Connection Management

    private func connectToPeripheral(_ peripheral: CBPeripheral) {
        guard connectedPeripheral == nil else { return }

        connectedPeripheral = peripheral
        peripheral.delegate = self
        centralManager?.connect(peripheral, options: [
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
        ])
        logger.info("Connecting to \(peripheral.name ?? "RuuviTag")")
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
        try? context.save()

        lastReading = Date()
        onDataReceived?()

        let name = peripheralName ?? "RuuviTag"
        logger.debug("Sensor reading recorded: \(String(format: "%.1f°C %.0f%% %.0fhPa", parsed.temperature, parsed.humidity, parsed.pressure))")

        if case .connected = status {
            // Keep connected status
        } else {
            status = .found(name: name)
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension RuuviTagScanner: CBCentralManagerDelegate {

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        logger.info("CoreBluetooth state restored")
        centralManager = central

        // Restore references to any peripherals that were connected
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let peripheral = peripherals.first {
            connectedPeripheral = peripheral
            peripheral.delegate = self
            logger.info("Restored connection to \(peripheral.name ?? "RuuviTag")")
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        logger.info("Bluetooth state: \(String(describing: central.state.rawValue))")
        switch central.state {
        case .poweredOn:
            beginScan()
            // Reconnect if we had a peripheral but lost it
            if let peripheral = connectedPeripheral, peripheral.state != .connected {
                central.connect(peripheral)
                logger.info("Reconnecting to \(peripheral.name ?? "RuuviTag")")
            }
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
        logger.debug("Discovered peripheral: \(peripheral.name ?? "unknown") RSSI=\(RSSI)")

        // Parse manufacturer data for sensor readings
        if let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
           manufacturerData.count >= 2 {
            let companyId = UInt16(manufacturerData[0]) | UInt16(manufacturerData[1]) << 8
            if companyId == Self.ruuviCompanyId {
                let payload = manufacturerData.dropFirst(2)
                if let parsed = Self.parseRAWv2(Data(payload)) {
                    recordReading(parsed, from: peripheral.name)
                }
            }
        }

        // Connect to the RuuviTag for reliable background wakeups
        connectToPeripheral(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let name = peripheral.name ?? "RuuviTag"
        logger.info("Connected to \(name)")
        status = .connected(name: name)

        // Discover NUS service to subscribe for active data notifications
        peripheral.discoverServices([Self.nusServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        logger.error("Failed to connect: \(error?.localizedDescription ?? "unknown")")
        connectedPeripheral = nil
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        logger.info("Disconnected from \(peripheral.name ?? "RuuviTag"), will reconnect")

        // Auto-reconnect — CoreBluetooth handles pending connections even
        // when the app is suspended, and wakes the app on success.
        if flightSession != nil {
            central.connect(peripheral, options: [
                CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
            ])
        } else {
            connectedPeripheral = nil
        }

        if case .connected = status {
            status = .found(name: peripheral.name ?? "RuuviTag")
        }

        // Piggyback an API poll on this wakeup
        onDataReceived?()
    }
}

// MARK: - CBPeripheralDelegate

extension RuuviTagScanner: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        if let error {
            logger.error("Service discovery failed: \(error.localizedDescription)")
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.nusServiceUUID }) else {
            logger.info("NUS service not found on peripheral")
            return
        }
        logger.info("Found NUS service, discovering TX characteristic")
        peripheral.discoverCharacteristics([Self.nusTXCharUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        if let error {
            logger.error("Characteristic discovery failed: \(error.localizedDescription)")
            return
        }
        guard let txChar = service.characteristics?.first(where: { $0.uuid == Self.nusTXCharUUID }) else {
            logger.info("NUS TX characteristic not found")
            return
        }
        // Subscribe to notifications — each notification wakes the app in background
        peripheral.setNotifyValue(true, for: txChar)
        logger.info("Subscribed to NUS TX notifications")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: (any Error)?) {
        if let error {
            logger.error("Notification subscription failed: \(error.localizedDescription)")
        } else {
            logger.info("NUS TX notification state: \(characteristic.isNotifying ? "ON" : "OFF")")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard characteristic.uuid == Self.nusTXCharUUID else { return }
        let byteCount = characteristic.value?.count ?? 0
        logger.debug("NUS TX data received: \(byteCount) bytes")

        // Each notification is a background wakeup opportunity — piggyback API poll
        onDataReceived?()
    }
}
