//
//  ModelStore.swift
//  flight-logger
//
//  Created by august huber on 9/7/26.
//

import Foundation
import SwiftData
import os

/// Builds the app's SwiftData container with a data protection class that
/// permits writes while the device is locked.
///
/// By default the store is created with `NSFileProtectionComplete`, which makes
/// the SQLite file unreadable once the screen locks on a passcode-protected
/// device. Because this app's entire purpose is logging while the phone is in a
/// pocket, that default silently drops every reading and flight data point for
/// the duration of the lock. `completeUntilFirstUserAuthentication` keeps the
/// store writable after the first unlock following boot.
enum ModelStore {

    private static let logger = Logger(subsystem: "org.pbx.flight-logger", category: "Store")

    static let schema = Schema([
        FlightSession.self,
        SensorReading.self,
        FlightDataPoint.self,
        DiagnosticSample.self,
    ])

    /// Explicit store location. This matches SwiftData's own default
    /// (`default.store` in Application Support), so existing installs keep
    /// their data — but naming it explicitly lets us set file protection on it.
    static var storeURL: URL {
        URL.applicationSupportDirectory.appending(path: "default.store")
    }

    static func makeContainer() -> ModelContainer {
        prepareDirectory()

        do {
            let container = try open()
            applyProtection()
            return container
        } catch {
            // A failed migration used to be fatal, which bricked the app until a
            // new build could be installed — a bad outcome for something meant to
            // be used away from a laptop. Move the unreadable store aside instead
            // (never delete it: it may hold flight data recoverable later) and
            // start fresh so the app still launches.
            logger.error("Store failed to load, quarantining: \(error.localizedDescription, privacy: .public)")
            quarantineStore()

            do {
                let container = try open()
                applyProtection()
                logger.error("Recovered with a fresh store; previous data quarantined")
                return container
            } catch {
                fatalError("Could not create ModelContainer even after quarantine: \(error)")
            }
        }
    }

    private static func open() throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, url: storeURL)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// Rename the store and its sidecars out of the way, preserving them.
    private static func quarantineStore() {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")

        for suffix in ["", "-wal", "-shm"] {
            let from = URL(fileURLWithPath: storeURL.path(percentEncoded: false) + suffix)
            guard FileManager.default.fileExists(atPath: from.path(percentEncoded: false)) else { continue }

            let to = URL(fileURLWithPath: storeURL.path(percentEncoded: false) + ".quarantined-\(stamp)" + suffix)
            do {
                try FileManager.default.moveItem(at: from, to: to)
                logger.error("Quarantined \(from.lastPathComponent, privacy: .public) -> \(to.lastPathComponent, privacy: .public)")
            } catch {
                logger.error("Could not quarantine \(from.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - File protection

    /// Create Application Support if needed and set its protection class, so
    /// files SQLite creates later (the -wal and -shm sidecars) inherit it.
    private static func prepareDirectory() {
        let directory = URL.applicationSupportDirectory
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: directory.path(percentEncoded: false)
            )
        } catch {
            logger.error("Could not set protection on store directory: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Apply protection to the store and its sidecars. Needed for stores that
    /// already exist from a previous install, which inherited the old class.
    private static func applyProtection() {
        let paths = [
            storeURL,
            storeURL.appendingPathExtension("wal"),
            storeURL.appendingPathExtension("shm"),
        ]

        for url in paths {
            let path = url.path(percentEncoded: false)
            guard FileManager.default.fileExists(atPath: path) else { continue }
            do {
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: path
                )
            } catch {
                logger.error("Could not set protection on \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
