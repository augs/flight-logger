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

    /// Consecutive polls reporting on-ground. Reset by any airborne reading.
    private var consecutiveOnGround = 0
    /// Polls the indicator must hold before a session is ended. At the 30s poll
    /// interval this is ~90 seconds.
    private static let onGroundConfirmations = 3
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
        consecutiveOnGround = 0
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

            // Parsing lives in AirlineResponseParser so it can be tested
            // against recorded responses without a network or a flight.
            let reading = AirlineResponseParser.parse(json: json, fields: config.fields)

            let altitude = reading.altitudeFt ?? 0
            let speed = reading.groundSpeedMPH ?? 0
            let airTemp = reading.airTempF ?? 0
            let flightStatus = reading.flightStatus ?? ""

            let dataPoint = FlightDataPoint(
                altitudeFt: altitude,
                groundSpeedMPH: speed,
                outsideAirTempF: airTemp,
                flightStatus: flightStatus,
                session: flightSession
            )
            modelContext.insert(dataPoint)

            lastPollTime = Date()

            timeRemainingMinutes = reading.timeRemainingMinutes

            // Auto-populate session metadata on first successful poll
            if !hasPopulatedMetadata {
                populateMetadata(reading, session: flightSession)
                flightSession.apiProvider = config.airline
                // Keep the payload verbatim. Anything not mapped above is
                // otherwise lost the moment the flight lands, and this turns a
                // real flight into a fixture for the parser tests.
                flightSession.rawFirstResponse = String(data: data, encoding: .utf8) ?? ""
                hasPopulatedMetadata = true
            }

            // Auto-stop on the on-ground indicator, but only after it holds.
            //
            // A single true reading is not enough: the flag is also true during
            // taxi and pushback, and a transient one mid-flight would end a
            // recording that cannot be resumed. Requiring consecutive polls
            // costs ~90s of extra tail data and removes that whole class of
            // false positive.
            if let onGround = reading.onGround {
                if onGround {
                    consecutiveOnGround += 1
                    if consecutiveOnGround >= Self.onGroundConfirmations {
                        logger.info("On-ground confirmed \(self.consecutiveOnGround)x — ending session")
                        flightSession.recordingEndedAt = Date()
                        stopPolling()
                    } else {
                        logger.info("On-ground reported (\(self.consecutiveOnGround)/\(Self.onGroundConfirmations)) — waiting for confirmation")
                    }
                } else {
                    consecutiveOnGround = 0
                }
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

    private func populateMetadata(_ reading: AirlineResponseParser.Reading, session: FlightSession) {
        // Only fill blanks: a value the user typed, or an earlier poll
        // established, should not be overwritten by a later one.
        if let number = reading.flightNumber, session.flightNumber.isEmpty {
            session.flightNumber = number
        }
        if let origin = reading.origin, session.origin.isEmpty {
            session.origin = origin
        }
        if let destination = reading.destination, session.destination.isEmpty {
            session.destination = destination
        }
        if let model = reading.aircraftModel, session.aircraftModel.isEmpty {
            session.aircraftModel = model
        }

        // Static metadata. Same fill-blanks-only rule, so a value the user
        // typed or an earlier poll established is never overwritten.
        fill(&session.originCity, reading.originCity)
        fill(&session.destinationCity, reading.destinationCity)
        fill(&session.originICAO, reading.originICAO)
        fill(&session.destinationICAO, reading.destinationICAO)
        fill(&session.departureGate, reading.departureGate)
        fill(&session.departureTerminal, reading.departureTerminal)
        fill(&session.arrivalGate, reading.arrivalGate)
        fill(&session.arrivalTerminal, reading.arrivalTerminal)
        fill(&session.tailNumber, reading.tailNumber)
        fill(&session.equipmentCode, reading.equipmentCode)

        if session.scheduledDurationMinutes == 0, let minutes = reading.scheduledDurationMinutes {
            session.scheduledDurationMinutes = Int(minutes)
        }
    }

    private func fill(_ target: inout String, _ value: String?) {
        guard target.isEmpty, let value, !value.isEmpty else { return }
        target = value
    }
}
