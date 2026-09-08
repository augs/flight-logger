//
//  RecordingStatusView.swift
//  flight-logger
//
//  Created by august huber on 9/8/26.
//

import SwiftUI

/// One-line health summary for an active recording, expandable to detail.
///
/// The dashboard had grown five separate status badges — airline API, BLE,
/// background capability, tag history, persistence — each justified on its own
/// but together pushing the actual readings below the fold. Mid-flight the only
/// questions that matter are "is it recording" and "will it keep recording with
/// the screen off"; everything else is diagnostics and belongs behind a tap.
struct RecordingStatusView: View {

    let manager: DataCollectionManager
    @State private var expanded = false

    // MARK: - Severity

    private enum Health {
        case good, warning, bad

        var tint: Color {
            switch self {
            case .good: .green
            case .warning: .orange
            case .bad: .red
            }
        }

        var icon: String {
            switch self {
            case .good: "checkmark.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .bad: "xmark.octagon.fill"
            }
        }
    }

    /// Worst problem wins — a summary that reported the *best* news would be
    /// worse than none.
    private var health: Health {
        if manager.bleScanner.persistenceError != nil { return .bad }
        if manager.apiService.persistenceError != nil { return .bad }
        if manager.bleScanner.status == .idle { return .bad }
        if manager.bleScanner.status == .unauthorized { return .bad }
        if manager.bleScanner.status == .bluetoothOff { return .bad }
        if manager.locationKeepAlive.status != .active { return .warning }
        if !manager.bleScanner.linkReady { return .warning }
        return .good
    }

    private var headline: String {
        if manager.bleScanner.persistenceError != nil || manager.apiService.persistenceError != nil {
            return "Not saving data"
        }
        switch manager.bleScanner.status {
        case .idle: return "Sensor collection stopped"
        case .unauthorized: return "Bluetooth not authorised"
        case .bluetoothOff: return "Bluetooth is off"
        case .unavailable: return "Bluetooth unavailable"
        case .scanning: return "Looking for tag…"
        case .found(let name):
            if manager.locationKeepAlive.status != .active {
                return "\(name) — stops when screen locks"
            }
            return manager.bleScanner.linkReady
                ? "\(name) — logging with screen off"
                : "\(name) — reconnecting"
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: health.icon)
                        .foregroundStyle(health.tint)
                    Text(headline)
                        .font(.subheadline)
                        .foregroundStyle(health == .good ? .primary : health.tint)
                        .multilineTextAlignment(.leading)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    detail("Tag", bleDetail)
                    detail("Airline API", apiDetail)
                    detail("Background", locationDetail)
                    detail("Tag history", historyDetail)
                    if let error = manager.bleScanner.persistenceError ?? manager.apiService.persistenceError {
                        detail("Storage", error, tint: .red)
                    }

                    Button("Sync Tag History Now") {
                        manager.bleScanner.syncHistoryForActiveSession()
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .padding(.top, 2)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func detail(_ label: String, _ value: String, tint: Color = .secondary) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 82, alignment: .leading)
            Text(value)
                .font(.caption2)
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Detail strings

    private var bleDetail: String {
        switch manager.bleScanner.status {
        case .idle: "Not collecting — recovering"
        case .scanning: "Scanning for advertisements"
        case .found(let name):
            manager.bleScanner.linkReady
                ? "\(name), connected · \(manager.bleScanner.readingCount) readings"
                : "\(name), broadcast only · \(manager.bleScanner.readingCount) readings"
        case .bluetoothOff: "Bluetooth is off"
        case .unauthorized: "Access denied in Settings"
        case .unavailable: "Not configured"
        }
    }

    private var apiDetail: String {
        switch manager.apiService.status {
        case .idle: "Idle"
        case .detecting: "Looking for airline WiFi"
        case .connected(let airline): "Connected to \(airline)"
        case .noAPI: "None found — manual mode"
        case .error(let message): message
        }
    }

    private var locationDetail: String {
        switch manager.locationKeepAlive.status {
        case .active: "Keeping app awake with screen off"
        case .denied: "Location denied — logging stops when locked"
        case .restricted: "Location restricted — logging stops when locked"
        case .idle: "Not started"
        }
    }

    private var historyDetail: String {
        switch manager.bleScanner.lastSyncResult {
        case .never: "Not synced yet"
        case .merged(let count, let at):
            "\(count) entries · \(at.formatted(date: .omitted, time: .shortened))"
        case .failed(let reason, _): reason
        }
    }
}
