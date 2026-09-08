//
//  AirlineAPIService.swift
//  flight-logger
//
//  Created by august huber on 4/4/26.
//

import Foundation
import SwiftData
import Observation
import os

/// Polls an airline WiFi API on a 30-second interval, creating
/// FlightDataPoint records and auto-populating session metadata.
@Observable
final class AirlineAPIService {

    enum ConnectionStatus: Equatable {
        case idle
        case detecting
        case connected(airline: String)
        case noAPI
        case error(String)
    }

    private(set) var status: ConnectionStatus = .idle
    private(set) var lastPollTime: Date?
    /// Time remaining to destination in minutes, updated each poll cycle.
    private(set) var timeRemainingMinutes: Double?

    /// Set when persisting a data point fails, so the UI can surface that
    /// data is being lost rather than failing silently.
    private(set) var persistenceError: String?

    private let logger = Logger(subsystem: "org.pbx.flight-logger", category: "API")

    private var pollingTask: Task<Void, Never>?
    private var detectedConfig: AirlineConfig?
    private var hasPopulatedMetadata = false
    private var flightSession: FlightSession?
    private var modelContext: ModelContext?

    private static let pollInterval: TimeInterval = 30
    /// A poll this far overdue means the loop stalled; the heartbeat forces one.
    private static let staleAfter: TimeInterval = 90
    private static let detectRetryFloor: TimeInterval = 60
    private static let detectRetryCeiling: TimeInterval = 300

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config)
    }()

    // MARK: - Public API

    /// Begin detecting an airline API and polling if found.
    func startPolling(flightSession: FlightSession, modelContext: ModelContext) {
        stopPolling()
        hasPopulatedMetadata = false
        self.flightSession = flightSession
        self.modelContext = modelContext
        status = .detecting
        launchLoop()
    }

    /// Stop polling immediately.
    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
        detectedConfig = nil
        flightSession = nil
        modelContext = nil
        timeRemainingMinutes = nil
        if status != .idle {
            status = .idle
        }
    }

    /// Restart the poll loop if it is no longer running.
    ///
    /// The loop can die when the app is suspended mid-`Task.sleep`. With the
    /// location keep-alive active that should not happen, but this is cheap
    /// insurance and covers the case where location permission was denied.
    func resumeIfNeeded(flightSession: FlightSession, modelContext: ModelContext) {
        self.flightSession = flightSession
        self.modelContext = modelContext

        if let task = pollingTask, !task.isCancelled { return }
        launchLoop()
    }

    /// Background heartbeat — called from the location keep-alive. Restarts a
    /// dead loop and forces a poll if the last one is overdue.
    func heartbeat() {
        guard let session = flightSession, let context = modelContext else { return }
        resumeIfNeeded(flightSession: session, modelContext: context)

        if let last = lastPollTime, Date().timeIntervalSince(last) > Self.staleAfter {
            logger.info("Poll overdue by \(Int(Date().timeIntervalSince(last)))s — forcing")
            pollOnce(flightSession: session, modelContext: context)
        }
    }

    // MARK: - Poll loop

    private func launchLoop() {
        guard let session = flightSession, let context = modelContext else { return }
        pollingTask = Task { [weak self] in
            await self?.run(flightSession: session, modelContext: context)
        }
    }

    private func run(flightSession: FlightSession, modelContext: ModelContext) async {
        var detectBackoff = Self.detectRetryFloor

        while !Task.isCancelled {
            // Detection retries rather than giving up permanently — the user
            // may start recording before joining the airline WiFi, or the
            // portal may only come up once airborne.
            if detectedConfig == nil {
                if status != .noAPI { status = .detecting }

                if let config = await detect() {
                    detectedConfig = config
                    status = .connected(airline: config.airline)
                    flightSession.airline = config.airline
                    flightSession.recordingMode = "api-auto"
                    detectBackoff = Self.detectRetryFloor
                } else {
                    status = .noAPI
                    try? await Task.sleep(for: .seconds(detectBackoff))
                    detectBackoff = min(detectBackoff * 2, Self.detectRetryCeiling)
                    continue
                }
            }

            guard let config = detectedConfig else { continue }

            await poll(config: config, flightSession: flightSession, modelContext: modelContext)
            if Task.isCancelled { break }
            try? await Task.sleep(for: .seconds(Self.pollInterval))
        }
    }

    /// Probe every bundled config and return the first that answers.
    private func detect() async -> AirlineConfig? {
        for config in AirlineConfigLoader.loadAll() {
            if Task.isCancelled { return nil }
            if await probe(config: config) { return config }
        }
        return nil
    }

    /// Perform a single poll — used to piggyback API calls on BLE wakeups
    /// in the background. Throttled to avoid duplicate work with the poll loop.
    func pollOnce(flightSession: FlightSession, modelContext: ModelContext) {
        guard let config = detectedConfig else { return }
        // Throttle: skip if we polled less than 20 seconds ago
        if let last = lastPollTime, Date().timeIntervalSince(last) < 20 { return }

        Task { [weak self] in
            await self?.poll(config: config, flightSession: flightSession, modelContext: modelContext)
        }
    }

    // MARK: - Probing

    /// Quick check to see if an airline API is reachable.
    private func probe(config: AirlineConfig) async -> Bool {
        guard let url = URL(string: config.url) else { return false }
        do {
            let (_, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse {
                return (200...299).contains(http.statusCode)
            }
            return false
        } catch {
            return false
        }
    }

    // MARK: - Polling

    private func poll(config: AirlineConfig, flightSession: FlightSession, modelContext: ModelContext) async {
        guard let url = URL(string: config.url) else { return }

        do {
            let (data, _) = try await session.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

            let fields = config.fields

            // Extract numeric values for the data point
            let altitude = resolveDouble(json: json, path: fields.altitudeFt) ?? 0
            let speed = resolveDouble(json: json, path: fields.groundSpeedMPH) ?? 0
            let airTemp = resolveDouble(json: json, path: fields.airTempF) ?? 0
            let flightStatus = resolveString(json: json, path: fields.flightStatus) ?? ""

            let dataPoint = FlightDataPoint(
                altitudeFt: altitude,
                groundSpeedMPH: speed,
                outsideAirTempF: airTemp,
                flightStatus: flightStatus,
                session: flightSession
            )
            modelContext.insert(dataPoint)

            lastPollTime = Date()

            // Update time remaining from API
            timeRemainingMinutes = resolveDouble(json: json, path: fields.timeRemainingMinutes)

            // Auto-populate session metadata on first successful poll
            if !hasPopulatedMetadata {
                populateMetadata(json: json, fields: fields, session: flightSession)
                hasPopulatedMetadata = true
            }

            // Check on-ground indicator for auto-stop
            if let onGround = resolveBool(json: json, path: fields.onGround), onGround {
                flightSession.recordingEndedAt = Date()
                stopPolling()
            }

            // Kept separate from the network catch below so a persistence
            // failure isn't misreported as an API error.
            do {
                try modelContext.save()
                persistenceError = nil
            } catch {
                // Most likely cause is data protection blocking the store while
                // the screen is locked. Never swallow this.
                persistenceError = error.localizedDescription
                logger.error("Failed to save flight data point: \(error.localizedDescription, privacy: .public)")
            }

        } catch {
            status = .error(error.localizedDescription)
        }
    }

    // MARK: - Metadata population

    private func populateMetadata(json: [String: Any], fields: AirlineConfig.FieldMappings, session: FlightSession) {
        if let num = resolveString(json: json, path: fields.flightNumber), session.flightNumber.isEmpty {
            session.flightNumber = num
        }
        if let origin = resolveString(json: json, path: fields.origin), session.origin.isEmpty {
            session.origin = origin
        }
        if let dest = resolveString(json: json, path: fields.destination), session.destination.isEmpty {
            session.destination = dest
        }
        if let path = fields.aircraftModel, let model = resolveString(json: json, path: path), session.aircraftModel.isEmpty {
            session.aircraftModel = model
        }
    }

    // MARK: - JSON path resolution

    /// Resolves a dot-separated key path (e.g. "flifo.altitudeFt") in a nested dictionary.
    private func resolve(json: [String: Any], path: String?) -> Any? {
        guard let path else { return nil }
        let components = path.split(separator: ".").map(String.init)
        var current: Any = json
        for key in components {
            guard let dict = current as? [String: Any], let next = dict[key] else {
                return nil
            }
            current = next
        }
        return current
    }

    private func resolveString(json: [String: Any], path: String?) -> String? {
        guard let value = resolve(json: json, path: path) else { return nil }
        if let s = value as? String { return s }
        return "\(value)"
    }

    private func resolveDouble(json: [String: Any], path: String?) -> Double? {
        guard let value = resolve(json: json, path: path) else { return nil }
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private func resolveBool(json: [String: Any], path: String?) -> Bool? {
        guard let value = resolve(json: json, path: path) else { return nil }
        if let b = value as? Bool { return b }
        if let s = value as? String {
            switch s.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        if let i = value as? Int { return i != 0 }
        return nil
    }
}
