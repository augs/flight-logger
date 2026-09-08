//
//  DataCollectionManager.swift
//  flight-logger
//
//  Created by august huber on 4/5/26.
//

import Foundation
import SwiftData
import SwiftUI
import Observation
import os
#if os(iOS)
import UIKit
#endif

/// App-level coordinator that owns the data collection services
/// and manages their lifecycle across background/foreground transitions.
@Observable
final class DataCollectionManager {

    let apiService = AirlineAPIService()
    let bleScanner = RuuviTagScanner()
    let locationKeepAlive = LocationKeepAlive()

    private(set) var activeSession: FlightSession?
    private var modelContext: ModelContext?
    private var livenessTask: Task<Void, Never>?

    /// Sampling cadence for the background diagnostic probe.
    ///
    /// This loop also drives history sync scheduling and the session cap, so it
    /// can't be disabled outright — but 15s was a debugging cadence, not a
    /// flight one. Over a 10h flight that was ~2,400 wake-ups and disk writes.
    private static let livenessInterval: TimeInterval = 60

    /// Run the network probe only every Nth sample. Each probe is a real HTTPS
    /// request, and in a cabin with poor connectivity a failing one burns radio
    /// retries — the single most expensive thing this loop did per tick.
    private static let networkProbeEverySamples = 5

    /// How often to pull the tag's onboard log mid-session.
    ///
    /// Live BLE is dead once backgrounded, so this is the only route to cabin
    /// data across a locked screen. The tag's own log cadence (~5 min observed)
    /// caps resolution, so syncing much more often than this gains nothing
    /// while costing a connection and a scanning pause each time.
    private static let historySyncInterval: TimeInterval = 15 * 60

    /// Hard ceiling on session length. The longest scheduled flight in service
    /// is roughly 19h (SIN–JFK), so this leaves ~2h of headroom. Without it a
    /// session that never sees an `onGround` indicator — every manual session —
    /// would run until the battery died.
    private static let maxSessionDuration: TimeInterval = 21 * 60 * 60

    /// Shorter backoff after a failed sync — a busy connection slot usually frees up.
    private static let historyRetryInterval: TimeInterval = 2 * 60

    /// Watermark: end of the data window we have successfully merged.
    private var lastHistorySync: Date?
    /// When we last *attempted* a sync, successful or not.
    private var lastSyncAttempt: Date?

    /// Incremented on every session start. Deferred work captured from a
    /// previous session compares against this before touching shared state.
    private var sessionGeneration = 0

    private let logger = Logger(subsystem: "org.pbx.flight-logger", category: "Collection")

    #if os(iOS)
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    #endif

    // MARK: - Session Resumption

    /// Resume data collection for an in-progress session after app relaunch.
    /// Call this early at app startup so the BLE scanner is connected to
    /// the active session before CoreBluetooth delivers background events.
    func resumeActiveSession(modelContainer: ModelContainer) {
        // Already have an active session — no need to resume
        guard activeSession == nil else { return }

        let context = ModelContext(modelContainer)
        var descriptor = FetchDescriptor<FlightSession>(
            predicate: #Predicate<FlightSession> { $0.recordingEndedAt == nil },
            sortBy: [SortDescriptor(\FlightSession.recordingStartedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1

        guard let session = try? context.fetch(descriptor).first else { return }
        startSession(session, modelContext: context)
    }

    // MARK: - Session Lifecycle

    /// Start collecting data for a flight session.
    func startSession(_ session: FlightSession, modelContext: ModelContext) {
        #if os(iOS)
        // Required before batteryLevel returns anything but -1.
        UIDevice.current.isBatteryMonitoringEnabled = true
        #endif
        sessionGeneration += 1
        self.activeSession = session
        self.modelContext = modelContext

        apiService.startPolling(flightSession: session, modelContext: modelContext)
        bleScanner.startScanning(flightSession: session, modelContext: modelContext)

        // Keeps the process alive with the screen off — without this the poll
        // loop dies ~30s after backgrounding and BLE delivery stops.
        locationKeepAlive.onHeartbeat = { [weak self] in
            self?.apiService.heartbeat()
        }
        locationKeepAlive.start()
        lastHistorySync = nil
        lastSyncAttempt = nil
        startLiveness(session: session, context: modelContext)

        logger.info("Session started")
    }

    /// Periodic proof-of-life written to the store, plus a network probe.
    ///
    /// Once the screen locks nothing is observable from outside: logs can't be
    /// streamed from a normally-launched app, and attaching a debugger changes
    /// the suspension behaviour under test. So each tick persists a
    /// `DiagnosticSample` — the gaps between timestamps reveal when iOS stopped
    /// executing us, and the network fields show whether background HTTP still
    /// completes and at what real cadence.
    private func startLiveness(session: FlightSession, context: ModelContext) {
        livenessTask?.cancel()
        livenessTask = Task { [weak self] in
            var previous = Date()
            var sampleIndex = 0

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.livenessInterval))
                guard let self, !Task.isCancelled else { return }

                let now = Date()
                let gap = now.timeIntervalSince(previous)
                previous = now

                // Exercise the network the same way the airline poll would,
                // but only occasionally — see networkProbeEverySamples.
                sampleIndex += 1
                let shouldProbe = sampleIndex % Self.networkProbeEverySamples == 1
                let net = shouldProbe
                    ? await Self.probeNetwork()
                    : (ok: true, ms: 0.0, error: "skipped")

                #if os(iOS)
                let (state, battery, batteryState) = await MainActor.run { () -> (String, Double, String) in
                    let appState: String
                    switch UIApplication.shared.applicationState {
                    case .active: appState = "active"
                    case .inactive: appState = "inactive"
                    case .background: appState = "background"
                    @unknown default: appState = "unknown"
                    }
                    let device = UIDevice.current
                    let level = Double(device.batteryLevel)
                    let charge: String
                    switch device.batteryState {
                    case .unplugged: charge = "unplugged"
                    case .charging: charge = "charging"
                    case .full: charge = "full"
                    default: charge = "unknown"
                    }
                    return (appState, level, charge)
                }
                #else
                let state = "n/a"
                let battery = -1.0
                let batteryState = "n/a"
                #endif

                var storeReadable = true
                var storeError = ""
                do {
                    // Reading the store is the only honest check that data
                    // protection isn't blocking us while locked.
                    _ = try context.fetchCount(FetchDescriptor<SensorReading>())
                } catch {
                    storeReadable = false
                    storeError = error.localizedDescription
                }

                let sample = DiagnosticSample(
                    timestamp: now,
                    appState: state,
                    secondsSincePrevious: gap,
                    storeReadable: storeReadable,
                    storeError: storeError,
                    readingCount: self.bleScanner.readingCount,
                    bleStatus: String(describing: self.bleScanner.status),
                    locationStatus: String(describing: self.locationKeepAlive.status),
                    networkOK: net.ok,
                    networkMilliseconds: net.ms,
                    networkError: net.error,
                    historySyncState: String(describing: self.bleScanner.historyState),
                    historySyncResult: String(describing: self.bleScanner.lastSyncResult),
                    historySyncTrace: self.bleScanner.historyTrace,
                    linkReady: self.bleScanner.linkReady,
                    batteryLevel: battery,
                    batteryState: batteryState
                )
                context.insert(sample)
                try? context.save()

                self.enforceSessionLimit(session)
                // Self-heal: if the scanner is idle while a session is active,
                // it is not collecting at all and nothing else will notice. A
                // teardown race left the app in exactly this state for 40
                // minutes in the field, so re-arm rather than trusting that it
                // can't happen again.
                if self.bleScanner.status == .idle {
                    self.logger.error("Scanner idle during an active session — re-arming")
                    self.bleScanner.startScanning(flightSession: session, modelContext: context)
                }
                // Watchdog: auto-reconnect is rejected on this device, so the
                // link has nothing but this to bring it back after a drop.
                self.bleScanner.openLink()
                self.syncHistoryIfDue(session, appState: state)

                self.logger.info(
                    "alive — state=\(state, privacy: .public) gap=\(String(format: "%.1f", gap), privacy: .public)s readings=\(self.bleScanner.readingCount) store=\(storeReadable) net=\(net.ok)/\(Int(net.ms))ms"
                )
            }
        }
    }

    /// End a session that has outrun the maximum plausible flight length.
    private func enforceSessionLimit(_ session: FlightSession) {
        let elapsed = Date().timeIntervalSince(session.recordingStartedAt)
        guard elapsed > Self.maxSessionDuration else { return }

        logger.warning("Session exceeded \(Int(Self.maxSessionDuration / 3600))h — auto-ending")
        session.recordingEndedAt = Date()
        stopSession()
    }

    /// Pull the tag's log periodically so cabin data survives a locked screen.
    ///
    /// Syncing suspends live scanning and needs the tag's single connection
    /// slot, so failures are expected and non-fatal — the next tick retries,
    /// which is the "retry opportunistically" behaviour we want when another
    /// app is holding the tag.
    private func syncHistoryIfDue(_ session: FlightSession, appState: String) {
        guard bleScanner.historyState == .idle else { return }

        // Foreground: live advertisement scanning works and is far higher
        // resolution than the tag's ~5 min log. Syncing there would stop
        // scanning for the duration of a connection to fetch data we're already
        // collecting better — a straight downgrade, and it looks like a hung
        // scan to the user. Background is where live BLE is dead and the log is
        // the only source, so that's the only place periodic sync earns its
        // cost. Session-end and manual syncs are unaffected.
        guard appState == "background" else { return }

        // Back off less after a failure than after a success: a failure usually
        // means the tag's connection slot was busy, which tends to clear.
        let interval: TimeInterval
        if case .failed = bleScanner.lastSyncResult {
            interval = Self.historyRetryInterval
        } else {
            interval = Self.historySyncInterval
        }

        // Attempt timing is tracked separately from the data watermark, so a
        // string of failures can't turn into a retry every liveness tick.
        let lastAttempt = lastSyncAttempt ?? session.recordingStartedAt
        guard Date().timeIntervalSince(lastAttempt) >= interval else { return }

        // The watermark only advances on success, so a failed sync re-requests
        // the same window rather than losing it.
        let since = lastHistorySync ?? session.recordingStartedAt
        lastSyncAttempt = Date()

        logger.info("History sync due — requesting log since \(since, privacy: .public)")
        bleScanner.syncHistory(since: since) { [weak self] merged in
            guard let self else { return }
            if case .merged = self.bleScanner.lastSyncResult {
                self.lastHistorySync = Date()
            }
            self.logger.info("Periodic history sync merged \(merged) entries")
        }
    }

    /// Small HTTP request used to test whether networking works in background.
    /// Apple's captive-portal endpoint is tiny and highly available.
    private static func probeNetwork() async -> (ok: Bool, ms: Double, error: String) {
        guard let url = URL(string: "https://captive.apple.com/hotspot-detect.html") else {
            return (false, 0, "bad url")
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10

        let started = Date()
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let ms = Date().timeIntervalSince(started) * 1000
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let ok = (200...299).contains(code)
            return (ok, ms, ok ? "" : "HTTP \(code)")
        } catch {
            return (false, Date().timeIntervalSince(started) * 1000, error.localizedDescription)
        }
    }

    /// Stop all data collection.
    func stopSession() {
        apiService.stopPolling()
        locationKeepAlive.stop()
        locationKeepAlive.onHeartbeat = nil
        livenessTask?.cancel()
        livenessTask = nil
        endBackgroundTask()

        let session = activeSession
        activeSession = nil
        modelContext = nil

        guard let session else {
            bleScanner.stopScanning()
            return
        }

        // Pull the tag's own log to backfill anything live collection missed.
        // This completes long after stopSession returns, so it must not tear
        // down a scanner that a *newer* session has since configured.
        //
        // Observed in the field: stopping one session and immediately starting
        // another left the app permanently not collecting for 40 minutes,
        // because the old session's completion nilled the scanner's
        // flightSession and cleared wantsLink after the new session had already
        // armed them. Nothing recovered it short of relaunching.
        let generation = sessionGeneration
        bleScanner.syncHistory(since: session.recordingStartedAt) { [weak self] merged in
            guard let self else { return }
            self.logger.info("Session ended — merged \(merged) history entries")
            guard self.sessionGeneration == generation else {
                self.logger.info("A newer session started; leaving the scanner alone")
                return
            }
            self.bleScanner.stopScanning()
        }
    }

    // MARK: - Scene Phase

    /// Call when the app enters the background.
    func handleEnteredBackground() {
        guard activeSession != nil else { return }
        // Belt-and-braces: if location permission was denied, this at least
        // buys ~30 seconds to finish an in-flight request.
        beginBackgroundTask()
        if locationKeepAlive.status != .active {
            logger.warning("Backgrounded without location keep-alive — collection will stop shortly")
        }
    }

    /// Call when the app becomes active again.
    func handleBecameActive() {
        guard let session = activeSession, let context = modelContext else { return }
        endBackgroundTask()
        apiService.resumeIfNeeded(flightSession: session, modelContext: context)
    }

    // MARK: - Background Task

    private func beginBackgroundTask() {
        #if os(iOS)
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.endBackgroundTask()
        }
        #endif
    }

    private func endBackgroundTask() {
        #if os(iOS)
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
        #endif
    }
}
