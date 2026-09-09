//
//  CabinAir.swift
//  flight-logger
//
//  Created by august huber on 9/8/26.
//

import Foundation

/// Psychrometric conversions for cabin air.
///
/// Exists because **relative humidity is the wrong thing to compare aircraft
/// on.** RH is a ratio to saturation, and saturation depends strongly on
/// temperature: two cabins both reading 12% RH at 19 °C and 24 °C hold
/// different amounts of water. A chart of RH partly plots how warm the cabin is
/// being run.
///
/// Mixing ratio is the quantity that answers "how much water is in this air".
/// It is conserved when air is compressed or heated, so it isolates what the
/// aircraft puts into the cabin from how the cabin is conditioned — which makes
/// it comparable between aircraft, and between one flight and the next.
///
/// The app already records temperature, humidity and pressure, so all of this
/// is derivable from data already on disk. Pure functions, no state.
enum CabinAir {

    /// Saturation vapour pressure in hPa, by the Magnus approximation.
    ///
    /// Accurate to well under 1% between roughly −40 °C and +50 °C, which
    /// covers every cabin condition and most outside-air ones.
    static func saturationVapourPressure(temperatureC t: Double) -> Double {
        6.112 * exp((17.67 * t) / (t + 243.5))
    }

    /// Actual vapour pressure in hPa.
    static func vapourPressure(temperatureC t: Double, humidityPercent rh: Double) -> Double {
        (rh / 100.0) * saturationVapourPressure(temperatureC: t)
    }

    /// Mixing ratio: grams of water vapour per kilogram of **dry** air.
    ///
    /// The headline metric. 621.97 is 1000·(Mᵥ/M_d), the ratio of the molar
    /// masses of water and dry air.
    ///
    /// Needs pressure as well as temperature and humidity, which is exactly why
    /// it is worth having a barometer alongside the tag: at cruise the cabin
    /// sits near 800 hPa, and using sea-level pressure here would overstate the
    /// result by about a quarter.
    static func mixingRatio(temperatureC t: Double, humidityPercent rh: Double, pressureHPa p: Double) -> Double? {
        let e = vapourPressure(temperatureC: t, humidityPercent: rh)
        // Vapour pressure cannot exceed total pressure; a reading implying that
        // is a sensor fault, not a very humid cabin.
        guard p > e, p > 0 else { return nil }
        return 621.97 * e / (p - e)
    }

    /// Absolute humidity: grams of water vapour per cubic metre.
    ///
    /// More intuitive than mixing ratio, but *not* conserved under compression —
    /// the same air moved to a different pressure reports a different value. Use
    /// mixing ratio for comparisons; this is for display.
    static func absoluteHumidity(temperatureC t: Double, humidityPercent rh: Double) -> Double {
        let e = vapourPressure(temperatureC: t, humidityPercent: rh)
        return 216.68 * e / (t + 273.15)
    }

    /// Dew point in °C, by inverting the Magnus formula.
    static func dewPoint(temperatureC t: Double, humidityPercent rh: Double) -> Double? {
        let e = vapourPressure(temperatureC: t, humidityPercent: rh)
        guard e > 0 else { return nil }
        let ln = log(e / 6.112)
        guard 17.67 - ln != 0 else { return nil }
        return 243.5 * ln / (17.67 - ln)
    }

    // MARK: - Cabin altitude

    static let seaLevelPressureHPa = 1013.25

    /// Pressure altitude in metres, by the ISA barometric formula.
    ///
    /// This is **cabin** altitude, not aircraft altitude — a pressurised cabin
    /// sits near a 6,000–8,000 ft equivalent regardless of how high the
    /// aircraft is. That is the quantity of interest here: it is what the
    /// occupants experience, and its integral over time is the
    /// "time at pressure" term.
    static func pressureAltitudeMeters(pressureHPa p: Double) -> Double? {
        guard p > 0 else { return nil }
        return 44330.0 * (1.0 - pow(p / seaLevelPressureHPa, 1.0 / 5.255))
    }

    static func pressureAltitudeFeet(pressureHPa p: Double) -> Double? {
        pressureAltitudeMeters(pressureHPa: p).map { $0 / 0.3048 }
    }
}
