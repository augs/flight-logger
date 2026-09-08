//
//  BarometerService.swift
//  flight-logger
//
//  Created by august huber on 9/8/26.
//

import Foundation
import Observation
import os
#if canImport(CoreMotion) && !os(macOS)
import CoreMotion
#endif

/// The phone's own barometer, as a second source of cabin pressure.
///
/// This measures the same physical quantity as the RuuviTag, from a completely
/// independent sensor with no Bluetooth involved. That makes it useful three
/// ways: it corroborates the tag, it covers periods when the tag link is down
/// (a 16-minute outage was observed in testing), and it means a flight records
/// a pressure profile even with no tag present at all.
///
/// Note on permissions: `CMAltimeter` requires Motion & Fitness authorization
/// even though what it reports here is cabin environment rather than anything
/// about the user. That is iOS's classification, not ours — so this asks for
/// the permission as part of recording rather than hiding behind a settings
/// toggle, and degrades quietly to "unavailable" if refused.
@Observable
final class BarometerService {

    enum Status: Equatable {
        case idle
        case unsupported
        case denied
        case active
    }

    private(set) var status: Status = .idle

    /// Most recent barometric pressure in hPa.
    private(set) var pressureHPa: Double?
    /// Altitude change since updates began, in metres.
    private(set) var relativeAltitudeMeters: Double?
    private(set) var lastUpdate: Date?

    private let logger = Logger(subsystem: "org.pbx.flight-logger", category: "Barometer")
    private var running = false

    // CMAltimeter does not exist on macOS. The service still compiles and
    // reports `.unsupported` there so callers need no platform checks of their
    // own — and so the test target, which builds for the Mac, stays buildable.
    #if os(iOS) || os(watchOS)
    private let altimeter = CMAltimeter()
    #endif

    func start() {
        guard !running else { return }

        #if os(iOS) || os(watchOS)
        guard CMAltimeter.isRelativeAltitudeAvailable() else {
            status = .unsupported
            logger.warning("No barometer on this device")
            return
        }

        switch CMAltimeter.authorizationStatus() {
        case .denied, .restricted:
            status = .denied
            logger.warning("Motion access denied — barometer unavailable")
            return
        default:
            break
        }

        running = true
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, error in
            guard let self else { return }

            if let error {
                // A denial arrives here rather than up front when the prompt
                // has not been answered yet.
                self.logger.error("Barometer error: \(error.localizedDescription, privacy: .public)")
                self.status = CMAltimeter.authorizationStatus() == .denied ? .denied : .idle
                return
            }
            guard let data else { return }

            // CoreMotion reports kPa; the app stores hPa throughout so the
            // phone's pressure is directly comparable with the tag's.
            self.pressureHPa = data.pressure.doubleValue * 10.0
            self.relativeAltitudeMeters = data.relativeAltitude.doubleValue
            self.lastUpdate = Date()

            if self.status != .active {
                self.status = .active
                self.logger.info("Barometer active")
            }
        }
        #else
        status = .unsupported
        #endif
    }

    func stop() {
        guard running else { return }
        #if os(iOS) || os(watchOS)
        altimeter.stopRelativeAltitudeUpdates()
        #endif
        running = false
        status = .idle
        pressureHPa = nil
        relativeAltitudeMeters = nil
        logger.info("Barometer stopped")
    }
}
