//
//  HealthSampleMerge.swift
//  flight-logger
//
//  Created by august huber on 9/8/26.
//

import Foundation
import SwiftData
import os

/// Merges HealthKit samples into a flight session.
///
/// Separate from `HealthKitService` so the merge rules can be tested without
/// HealthKit, a device, or a flight — the query itself needs all three.
enum HealthSampleMerge {

    private static let logger = Logger(subsystem: "org.pbx.flight-logger", category: "Health")

    /// Rows not already present, keyed on HealthKit's sample UUID.
    ///
    /// Health data syncs from the Watch on its own schedule, so refreshing a
    /// finished flight legitimately returns samples seen before alongside new
    /// ones. Filtering on UUID makes repeated merges idempotent instead of
    /// duplicating every row each time.
    static func newRows<T>(
        from fetched: [(metric: HealthMetric, date: Date, value: Double, uuid: String)],
        existingUUIDs: Set<String>,
        make: (HealthMetric, Date, Double, String) -> T
    ) -> [T] {
        var seen = existingUUIDs
        var out: [T] = []
        for row in fetched {
            // Guard against duplicates within one fetch as well as against
            // what is already stored.
            guard !seen.contains(row.uuid) else { continue }
            seen.insert(row.uuid)
            out.append(make(row.metric, row.date, row.value, row.uuid))
        }
        return out
    }

    /// Fetch the session's window and store anything new.
    @discardableResult
    static func refresh(
        session: FlightSession,
        service: HealthKitService,
        context: ModelContext
    ) async -> Int {
        guard service.isEnabled else { return 0 }

        // An in-progress flight has no end yet; read up to now.
        let start = session.recordingStartedAt
        let end = session.recordingEndedAt ?? Date()
        guard end > start else { return 0 }

        let fetched = await service.allSamples(from: start, to: end)
        guard !fetched.isEmpty else { return 0 }

        let existing = Set(session.healthSamples.map(\.sampleUUID))
        let additions = newRows(from: fetched, existingUUIDs: existing) { metric, date, value, uuid in
            HealthSample(timestamp: date, metric: metric, value: value,
                         sampleUUID: uuid, session: session)
        }
        guard !additions.isEmpty else { return 0 }

        for sample in additions { context.insert(sample) }
        do {
            try context.save()
            logger.info("Merged \(additions.count) health samples of \(fetched.count) fetched")
        } catch {
            logger.error("Failed to save health samples: \(error.localizedDescription, privacy: .public)")
            return 0
        }
        return additions.count
    }
}
