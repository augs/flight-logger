//
//  HealthKitService.swift
//  flight-logger
//
//  Created by august huber on 9/8/26.
//

import Foundation
import HealthKit
import Observation
import os

/// Reads physiological samples recorded during a flight.
///
/// Read-only, opt-in, and narrow: authorization is requested for four metrics
/// and nothing else, with no write access at all. This is personal data rather
/// than cabin environment, so nothing here runs unless the user has switched it
/// on in Settings — see `DESIGN.md` → Data Collection and Consent.
///
/// **Opportunistic by necessity.** HealthKit offers no way to trigger a
/// measurement. SpO2 in particular is sampled by the Watch on its own schedule,
/// largely when the wearer is still, so a flight may yield a handful of readings
/// or none. Heart rate could be driven at a ~5s cadence, but only from a
/// watchOS app running an `HKWorkoutSession` — a separate target, tracked
/// separately.
@Observable
final class HealthKitService {

    enum Status: Equatable {
        case unavailable        // no HealthKit on this device
        case notRequested
        case denied
        case authorized
    }

    private(set) var status: Status = .notRequested
    private(set) var lastError: String?

    private let store = HKHealthStore()
    private let logger = Logger(subsystem: "org.pbx.flight-logger", category: "Health")

    /// Settings key. Default off; flipping it on is what triggers the system
    /// permission prompt, so nothing is requested speculatively at launch.
    static let enabledKey = "healthKitEnabled"

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    // MARK: - Types

    private var readTypes: Set<HKObjectType> {
        Set(HealthMetric.allCases.compactMap { Self.quantityType(for: $0) })
    }

    static func quantityType(for metric: HealthMetric) -> HKQuantityType? {
        let identifier: HKQuantityTypeIdentifier = switch metric {
        case .oxygenSaturation: .oxygenSaturation
        case .heartRate: .heartRate
        case .heartRateVariability: .heartRateVariabilitySDNN
        case .respiratoryRate: .respiratoryRate
        }
        return HKQuantityType.quantityType(forIdentifier: identifier)
    }

    /// HealthKit's native unit for each metric, converted to this app's
    /// canonical unit on the way in.
    static func healthKitUnit(for metric: HealthMetric) -> HKUnit {
        switch metric {
        case .oxygenSaturation:
            // HealthKit stores saturation as a 0–1 fraction. Using `.percent()`
            // here yields 0.97, not 97 — the conversion below rescales it.
            .percent()
        case .heartRate, .respiratoryRate:
            HKUnit.count().unitDivided(by: .minute())
        case .heartRateVariability:
            .secondUnit(with: .milli)
        }
    }

    /// Rescales a HealthKit value into the unit this app stores.
    static func canonicalValue(_ raw: Double, for metric: HealthMetric) -> Double {
        switch metric {
        case .oxygenSaturation: raw * 100      // fraction → percent
        default: raw
        }
    }

    // MARK: - Authorization

    func refreshStatus() {
        guard HKHealthStore.isHealthDataAvailable() else {
            status = .unavailable
            return
        }
        guard isEnabled else {
            status = .notRequested
            return
        }
        // Read authorization is deliberately opaque in HealthKit: it will not
        // tell you whether reading is permitted, to avoid leaking that a user
        // declined. So this reflects our own toggle, and an empty result is
        // indistinguishable from a denial — which is why the UI says "no
        // samples found" rather than claiming access was refused.
        status = .authorized
    }

    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            status = .unavailable
            return
        }
        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
            status = .authorized
            lastError = nil
            logger.info("Health authorization requested for \(self.readTypes.count) read types")
        } catch {
            status = .denied
            lastError = error.localizedDescription
            logger.error("Health authorization failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Querying

    /// Samples overlapping a flight window, one metric at a time.
    ///
    /// Returns everything found; de-duplication against what is already stored
    /// happens at the merge step, keyed on HealthKit's sample UUID.
    func samples(
        for metric: HealthMetric,
        from start: Date,
        to end: Date,
        limit: Int = 5000
    ) async -> [(date: Date, value: Double, uuid: String)] {
        guard HKHealthStore.isHealthDataAvailable(), isEnabled,
              let type = Self.quantityType(for: metric) else { return [] }

        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
        let unit = Self.healthKitUnit(for: metric)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type, predicate: predicate, limit: limit, sortDescriptors: sort
            ) { _, samples, error in
                if let error {
                    self.logger.error("Health query for \(metric.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                    continuation.resume(returning: [])
                    return
                }

                let rows = (samples as? [HKQuantitySample] ?? []).compactMap { sample -> (Date, Double, String)? in
                    let value = Self.canonicalValue(sample.quantity.doubleValue(for: unit), for: metric)
                    // A value outside the plausible range is a bad reading, and
                    // charting it would distort the axis for everything else.
                    guard metric.plausibleRange.contains(value) else { return nil }
                    return (sample.startDate, value, sample.uuid.uuidString)
                }
                continuation.resume(returning: rows)
            }
            store.execute(query)
        }
    }

    /// Every configured metric across the window.
    func allSamples(from start: Date, to end: Date) async -> [(metric: HealthMetric, date: Date, value: Double, uuid: String)] {
        var out: [(HealthMetric, Date, Double, String)] = []
        for metric in HealthMetric.allCases {
            for row in await samples(for: metric, from: start, to: end) {
                out.append((metric, row.date, row.value, row.uuid))
            }
        }
        return out
    }
}
