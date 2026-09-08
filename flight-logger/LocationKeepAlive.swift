//
//  LocationKeepAlive.swift
//  flight-logger
//
//  Created by august huber on 9/7/26.
//

import Foundation
import CoreLocation
import Observation
import os

/// Keeps the app running in the background for the duration of a flight
/// recording.
///
/// iOS gives a backgrounded app roughly 30 seconds of runtime via
/// `beginBackgroundTask`, which is nowhere near a flight. An active
/// `CLLocationManager` with `allowsBackgroundLocationUpdates` is the supported
/// way to keep a process alive indefinitely, and it's what makes both the API
/// poll loop and foreground-quality BLE scanning continue with the screen off.
///
/// We do not use the location data itself — only the runtime it buys. Updates
/// are requested at the coarsest useful accuracy to limit battery cost, and the
/// manager runs only while a session is recording, never outside one.
///
/// Note: this does not depend on getting an actual fix. GPS in a cabin is
/// unreliable and COCOM limits can suppress it, but `startUpdatingLocation()`
/// keeps the app alive whether or not fixes arrive.
@Observable
final class LocationKeepAlive: NSObject {

    enum Status: Equatable {
        case idle
        case active
        case denied
        case restricted
    }

    private(set) var status: Status = .idle

    /// Fired on each location callback — a convenient background heartbeat for
    /// work that would otherwise depend on a timer surviving suspension.
    var onHeartbeat: (() -> Void)?

    /// Most recent fix. The manager runs continuously for the keep-alive
    /// regardless, so these were previously discarded — which threw away an
    /// altitude and ground-speed trace available on every flight, including the
    /// majority that have no airline WiFi.
    private(set) var lastLocation: CLLocation?

    private let manager = CLLocationManager()
    private let logger = Logger(subsystem: "org.pbx.flight-logger", category: "Location")
    private var wantsUpdates = false

    override init() {
        super.init()
        manager.delegate = self
        // Coarse is plenty — we want runtime, not position.
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = 1000
        // Critical: iOS otherwise pauses updates when it decides you're
        // stationary, which silently kills the keep-alive mid-flight.
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .otherNavigation
    }

    // MARK: - Lifecycle

    func start() {
        wantsUpdates = true

        switch manager.authorizationStatus {
        case .notDetermined:
            // Updates begin once the user answers, via the delegate callback.
            manager.requestWhenInUseAuthorization()
            logger.info("Requesting location authorization")
        case .denied:
            status = .denied
            logger.warning("Location denied — background recording will stop when suspended")
        case .restricted:
            status = .restricted
            logger.warning("Location restricted — background recording will stop when suspended")
        case .authorizedWhenInUse, .authorizedAlways:
            beginUpdates()
        @unknown default:
            break
        }
    }

    func stop() {
        wantsUpdates = false
        guard status == .active else {
            status = .idle
            return
        }
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        lastLocation = nil
        status = .idle
        logger.info("Location keep-alive stopped")
    }

    // MARK: - Internal

    private func beginUpdates() {
        guard wantsUpdates, status != .active else { return }

        // Must be set only with the `location` background mode present in
        // Info.plist, and only while authorized — otherwise this throws.
        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()
        status = .active
        logger.info("Location keep-alive active")
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationKeepAlive: CLLocationManagerDelegate {

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            beginUpdates()
        case .denied:
            status = .denied
        case .restricted:
            status = .restricted
        case .notDetermined:
            status = .idle
        @unknown default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Keep the newest usable fix. Cabin GNSS is often poor, so accuracy is
        // retained alongside the value rather than filtered here — a consumer
        // charting this needs to tell a bad fix from a real change.
        if let newest = locations.last {
            lastLocation = newest
        }
        onHeartbeat?()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        // A failed fix is expected in a cabin and is not fatal: the app stays
        // alive as long as updates remain requested.
        logger.debug("Location error (non-fatal): \(error.localizedDescription, privacy: .public)")
    }
}
