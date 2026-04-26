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
#if os(iOS)
import UIKit
#endif

/// App-level coordinator that owns both data collection services
/// and manages their lifecycle across background/foreground transitions.
@Observable
final class DataCollectionManager {

    let apiService = AirlineAPIService()
    let bleScanner = RuuviTagScanner()

    private(set) var activeSession: FlightSession?
    private var modelContext: ModelContext?

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
        self.activeSession = session
        self.modelContext = modelContext
        apiService.startPolling(flightSession: session, modelContext: modelContext)
        bleScanner.startScanning(flightSession: session, modelContext: modelContext)

        bleScanner.onDataReceived = { [weak self] in
            self?.handleBLEDataReceived()
        }
    }

    /// Stop all data collection.
    func stopSession() {
        apiService.stopPolling()
        bleScanner.stopScanning()
        activeSession = nil
        modelContext = nil
        endBackgroundTask()
    }

    // MARK: - Scene Phase

    /// Call when the app enters the background.
    func handleEnteredBackground() {
        guard activeSession != nil else { return }
        beginBackgroundTask()
        // Services keep running — BLE continues via background mode,
        // API polling continues until background time expires.
    }

    /// Call when the app becomes active again.
    func handleBecameActive() {
        guard let session = activeSession, let context = modelContext else { return }
        endBackgroundTask()
        // Ensure API polling is alive (it may have been suspended)
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

    // MARK: - BLE Piggyback Polling

    /// Called when BLE scanner receives data. In background, this is our
    /// opportunity to also fire an API poll.
    private func handleBLEDataReceived() {
        guard let session = activeSession, let context = modelContext else { return }
        apiService.pollOnce(flightSession: session, modelContext: context)
    }
}
