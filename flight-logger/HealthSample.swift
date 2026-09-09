//
//  HealthSample.swift
//  flight-logger
//
//  Created by august huber on 9/8/26.
//

import Foundation
import SwiftData

/// A physiological measurement recorded during a flight, read from HealthKit.
///
/// Personal data, not cabin environment, so it is only ever collected when the
/// user has explicitly turned it on — see `DESIGN.md` → Data Collection and
/// Consent. Stored alongside the session so cabin conditions and physiological
/// response share one timeline.
@Model
final class HealthSample {
    var timestamp: Date

    /// Raw `HealthMetric` value.
    var metric: String = ""
    /// Value in this app's canonical unit for the metric — see `HealthMetric.unit`.
    var value: Double = 0

    /// HealthKit's own sample identifier.
    ///
    /// Health data syncs from the Watch on its own schedule, so the same flight
    /// window queried twice will legitimately return overlapping results. This
    /// makes the merge idempotent rather than duplicating rows every refresh.
    var sampleUUID: String = ""

    var session: FlightSession?

    init(
        timestamp: Date = Date(),
        metric: HealthMetric,
        value: Double,
        sampleUUID: String,
        session: FlightSession? = nil
    ) {
        self.timestamp = timestamp
        self.metric = metric.rawValue
        self.value = value
        self.sampleUUID = sampleUUID
        self.session = session
    }

    var healthMetric: HealthMetric? { HealthMetric(rawValue: metric) }
}

/// The physiological metrics worth correlating with cabin conditions.
///
/// Deliberately a short list. HealthKit exposes hundreds of types, and
/// requesting read access to anything not used here would be asking for data
/// with no purpose.
enum HealthMetric: String, CaseIterable {
    /// Blood oxygen, percent.
    ///
    /// The one people ask about at altitude, and the one that cannot be driven:
    /// HealthKit has no API to trigger a measurement, so samples appear only
    /// when the Watch takes one of its own accord — generally while still.
    /// Log it opportunistically; do not design a cadence around it.
    case oxygenSaturation

    /// Beats per minute. Unlike SpO2 this *can* be driven to a ~5s cadence, but
    /// only by an `HKWorkoutSession` running on a watchOS app — a separate
    /// target and a much larger piece of work. Read opportunistically for now.
    case heartRate

    /// Heart rate variability, SDNN, in milliseconds.
    case heartRateVariability

    /// Breaths per minute.
    case respiratoryRate

    var label: String {
        switch self {
        case .oxygenSaturation: "Blood oxygen"
        case .heartRate: "Heart rate"
        case .heartRateVariability: "HRV (SDNN)"
        case .respiratoryRate: "Respiratory rate"
        }
    }

    /// Canonical unit this app stores the metric in.
    var unit: String {
        switch self {
        case .oxygenSaturation: "%"
        case .heartRate: "bpm"
        case .heartRateVariability: "ms"
        case .respiratoryRate: "breaths/min"
        }
    }

    /// Plausible range, used to reject values that would corrupt a chart.
    var plausibleRange: ClosedRange<Double> {
        switch self {
        case .oxygenSaturation: 50...100
        case .heartRate: 20...240
        case .heartRateVariability: 0...500
        case .respiratoryRate: 4...60
        }
    }
}
