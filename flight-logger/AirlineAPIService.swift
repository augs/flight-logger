//
//  AirlineAPIService.swift
//  flight-logger
//
//  Created by august huber on 4/4/26.
//

import Foundation
import SwiftData
import Observation

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

    private var pollingTask: Task<Void, Never>?
    private var detectedConfig: AirlineConfig?
    private var hasPopulatedMetadata = false

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
        status = .detecting

        pollingTask = Task { [weak self] in
            guard let self else { return }

            // Try to detect which airline WiFi we're on
            let configs = AirlineConfigLoader.loadAll()
            var matched: AirlineConfig?

            for config in configs {
                if Task.isCancelled { return }
                if await self.probe(config: config) {
                    matched = config
                    break
                }
            }

            if Task.isCancelled { return }

            if let config = matched {
                self.detectedConfig = config
                self.status = .connected(airline: config.airline)
                flightSession.airline = config.airline
                flightSession.recordingMode = "api-auto"

                // Poll loop
                while !Task.isCancelled {
                    await self.poll(config: config, flightSession: flightSession, modelContext: modelContext)
                    if Task.isCancelled { break }
                    try? await Task.sleep(for: .seconds(30))
                }
            } else {
                self.status = .noAPI
            }
        }
    }

    /// Stop polling immediately.
    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
        detectedConfig = nil
        timeRemainingMinutes = nil
        if status != .idle {
            status = .idle
        }
    }

    /// Resume the poll loop if we previously detected an airline API
    /// but the polling task is no longer running (e.g. after suspension).
    func resumeIfNeeded(flightSession: FlightSession, modelContext: ModelContext) {
        guard let config = detectedConfig else { return }
        // If polling task is still alive, nothing to do
        if let task = pollingTask, !task.isCancelled { return }

        hasPopulatedMetadata = true // already populated on first detection
        pollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.poll(config: config, flightSession: flightSession, modelContext: modelContext)
                if Task.isCancelled { break }
                try? await Task.sleep(for: .seconds(30))
            }
        }
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

            try? modelContext.save()

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
