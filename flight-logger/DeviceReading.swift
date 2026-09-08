//
//  DeviceReading.swift
//  flight-logger
//
//  Created by august huber on 9/8/26.
//

import Foundation
import SwiftData

/// Measurements taken by the phone itself, independent of the RuuviTag and of
/// the airline API.
///
/// Deliberately a separate model rather than extra columns on `FlightDataPoint`
/// or `SensorReading`. Three sources measure overlapping quantities — the tag's
/// pressure, the phone's barometer, the airline's reported altitude, the
/// phone's GPS altitude — and they will disagree. Pressure altitude is not GPS
/// altitude, and neither is what the airline reports. Merging them into shared
/// columns would hide exactly the comparison this data exists to support.
///
/// One row per collection tick carrying whatever was known at that moment, so
/// rows line up on the shared chart time axis without needing to join across
/// differing sensor cadences.
@Model
final class DeviceReading {
    var timestamp: Date

    /// Barometric pressure in hPa, from `CMAltimeter`. The phone's own reading
    /// of cabin pressure — directly comparable with `SensorReading.pressureHPa`.
    var pressureHPa: Double?

    /// Altitude change since the barometer started, in metres. Useful for cabin
    /// pressurisation profile even when absolute altitude is unavailable.
    var relativeAltitudeMeters: Double?

    /// GNSS altitude above sea level, in metres. Not the same quantity as
    /// pressure altitude, and usually not equal to the airline's figure.
    var gpsAltitudeMeters: Double?
    /// Reported vertical accuracy in metres; negative means invalid. Worth
    /// keeping, because cabin GNSS fixes are often poor and a chart should be
    /// able to distinguish a bad fix from a real change.
    var gpsVerticalAccuracy: Double?

    /// Ground speed in metres per second, or negative when invalid.
    var gpsSpeedMPS: Double?

    var session: FlightSession?

    init(
        timestamp: Date = Date(),
        pressureHPa: Double? = nil,
        relativeAltitudeMeters: Double? = nil,
        gpsAltitudeMeters: Double? = nil,
        gpsVerticalAccuracy: Double? = nil,
        gpsSpeedMPS: Double? = nil,
        session: FlightSession? = nil
    ) {
        self.timestamp = timestamp
        self.pressureHPa = pressureHPa
        self.relativeAltitudeMeters = relativeAltitudeMeters
        self.gpsAltitudeMeters = gpsAltitudeMeters
        self.gpsVerticalAccuracy = gpsVerticalAccuracy
        self.gpsSpeedMPS = gpsSpeedMPS
        self.session = session
    }

    /// True when the row carries nothing worth storing.
    var isEmpty: Bool {
        pressureHPa == nil && gpsAltitudeMeters == nil && gpsSpeedMPS == nil
    }
}
