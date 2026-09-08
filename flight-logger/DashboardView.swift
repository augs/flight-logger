//
//  DashboardView.swift
//  flight-logger
//
//  Created by august huber on 4/4/26.
//

import SwiftUI
import SwiftData
import Charts

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<FlightSession> { $0.recordingEndedAt == nil },
           sort: \FlightSession.recordingStartedAt, order: .reverse)
    private var activeSessions: [FlightSession]

    @Environment(DataCollectionManager.self) private var manager
    @AppStorage("unitPreference") private var units: UnitPreference = .system
    @State private var showStartSheet = false

    private var activeSession: FlightSession? { activeSessions.first }

    var body: some View {
        NavigationStack {
            Group {
                if let session = activeSession {
                    activeRecordingView(session)
                } else {
                    idleView
                }
            }
            .navigationTitle("Dashboard")
        }
        .onChange(of: activeSession) { oldValue, newValue in
            if let session = newValue {
                manager.startSession(session, modelContext: modelContext)
            } else {
                manager.stopSession()
            }
        }
    }

    // MARK: - Active Recording

    private func activeRecordingView(_ session: FlightSession) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                flightBanner(session)
                connectionStatusBadge
                bleStatusBadge
                backgroundStatusBadge
                historySyncCard
                persistenceErrorBadge
                sensorReadoutsCard(session)
                flightDataCard(session)
                liveChartCard(session)
                stopButton(session)
            }
            .padding()
        }
    }

    private func flightBanner(_ session: FlightSession) -> some View {
        VStack(spacing: 4) {
            Text(session.displayTitle)
                .font(.title2.bold())
            if !session.routeDescription.isEmpty {
                Text(session.routeDescription)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            if let minutes = manager.apiService.timeRemainingMinutes {
                let hours = Int(minutes) / 60
                let mins = Int(minutes) % 60
                Text(hours > 0 ? "\(hours)h \(mins)m remaining" : "\(mins)m remaining")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Image(systemName: "record.circle")
                    .foregroundStyle(.red)
                Text("Recording")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Connection Status

    private var connectionStatusBadge: some View {
        HStack(spacing: 8) {
            switch manager.apiService.status {
            case .idle:
                EmptyView()
            case .detecting:
                ProgressView()
                    .controlSize(.small)
                Text("Detecting airline WiFi...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case .connected(let airline):
                Image(systemName: "wifi")
                    .foregroundStyle(.green)
                Text("Connected to \(airline)")
                    .font(.subheadline)
                    .foregroundStyle(.green)
                if let lastPoll = manager.apiService.lastPollTime {
                    Spacer()
                    Text(lastPoll, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            case .noAPI:
                Image(systemName: "wifi.slash")
                    .foregroundStyle(.secondary)
                Text("No airline API detected — manual mode")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case .error(let message):
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    // MARK: - BLE Status

    private var bleStatusBadge: some View {
        HStack(spacing: 8) {
            switch manager.bleScanner.status {
            case .idle:
                EmptyView()
            case .scanning:
                ProgressView()
                    .controlSize(.small)
                Text("Scanning for RuuviTag...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case .found(let name):
                Image(systemName: "sensor.fill")
                    .foregroundStyle(.green)
                Text(name)
                    .font(.subheadline)
                    .foregroundStyle(.green)
                if let lastRead = manager.bleScanner.lastReading {
                    Spacer()
                    Text(lastRead, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            case .bluetoothOff:
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .foregroundStyle(.secondary)
                Text("Bluetooth is off")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case .unauthorized:
                Image(systemName: "hand.raised")
                    .foregroundStyle(.orange)
                Text("Bluetooth access not authorized")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            case .unavailable:
                Image(systemName: "sensor")
                    .foregroundStyle(.secondary)
                Text("Bluetooth not configured")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    // MARK: - Background Status

    /// Without location authorization the app is suspended shortly after the
    /// screen locks and logging stops — the single most important thing to tell
    /// the user before they put the phone away for a flight.
    @ViewBuilder
    private var backgroundStatusBadge: some View {
        HStack(spacing: 8) {
            switch manager.locationKeepAlive.status {
            case .active:
                Image(systemName: "moon.zzz.fill")
                    .foregroundStyle(.green)
                Text("Will keep logging with the screen off")
                    .font(.subheadline)
                    .foregroundStyle(.green)
            case .denied, .restricted:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Logging stops when the screen locks")
                        .font(.subheadline.bold())
                        .foregroundStyle(.orange)
                    Text("Allow location access to record for the whole flight.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            case .idle:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    // MARK: - Tag History Sync

    /// Live BLE stops the moment the screen locks, so the tag's onboard log is
    /// the only source of cabin data for a backgrounded flight. When a sync
    /// fails it's almost always because another app holds the tag's single
    /// connection slot — which the user can fix, but only if we say so.
    @ViewBuilder
    private var historySyncCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Tag History", systemImage: "arrow.down.circle")
                    .font(.headline)
                Spacer()
                switch manager.bleScanner.historyState {
                case .connecting:
                    ProgressView().controlSize(.small)
                    Text("Connecting…").font(.caption).foregroundStyle(.secondary)
                case .downloading(let frames):
                    ProgressView().controlSize(.small)
                    Text("\(frames) frames").font(.caption).foregroundStyle(.secondary)
                case .idle, .failed:
                    Button("Sync Now") {
                        manager.bleScanner.syncHistoryForActiveSession()
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                }
            }

            switch manager.bleScanner.lastSyncResult {
            case .never:
                Text("Backfills cabin readings missed while the screen was locked.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .merged(let count, let at):
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(count > 0 ? "Added \(count) readings" : "Already up to date")
                        .foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.secondary)
                    Text(at, style: .relative).foregroundStyle(.secondary)
                }
                .font(.caption2)
            case .failed(let reason, _):
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(reason)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Persistence Errors

    /// Saves can fail without any other symptom — most likely data protection
    /// blocking the store while the screen is locked. Make that visible rather
    /// than losing a flight silently.
    @ViewBuilder
    private var persistenceErrorBadge: some View {
        let message = manager.bleScanner.persistenceError ?? manager.apiService.persistenceError
        if let message {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Not saving data")
                        .font(.subheadline.bold())
                        .foregroundStyle(.red)
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Sensor Readouts

    private func sensorReadoutsCard(_ session: FlightSession) -> some View {
        let latest = session.sensorReadings.sorted { $0.timestamp > $1.timestamp }.first

        return VStack(alignment: .leading, spacing: 12) {
            Label("Cabin Sensors", systemImage: "sensor")
                .font(.headline)
            HStack(spacing: 16) {
                readout(label: "Temp", value: latest.map { units.formatCabinTemp($0.temperatureCelsius) } ?? "--")
                readout(label: "Humidity", value: latest.map { String(format: "%.0f%%", $0.humidityPercent) } ?? "--")
                readout(label: "Pressure", value: latest.map { String(format: "%.0f hPa", $0.pressureHPa) } ?? "--")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Flight Data

    private func flightDataCard(_ session: FlightSession) -> some View {
        let latest = session.flightDataPoints.sorted { $0.timestamp > $1.timestamp }.first

        return VStack(alignment: .leading, spacing: 12) {
            Label("Flight Data", systemImage: "airplane")
                .font(.headline)
            HStack(spacing: 16) {
                readout(label: "Altitude", value: latest.map { units.formatAltitude($0.altitudeFt) } ?? "--")
                readout(label: "Speed", value: latest.map { units.formatSpeed($0.groundSpeedMPH) } ?? "--")
                readout(label: "Air Temp", value: latest.map { units.formatOutsideTemp($0.outsideAirTempF) } ?? "--")
            }
            if let status = latest?.flightStatus, !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Live Chart

    private func liveChartCard(_ session: FlightSession) -> some View {
        let cutoff = Date().addingTimeInterval(-600) // last 10 minutes
        let sensorData = session.sensorReadings
            .filter { $0.timestamp >= cutoff }
            .sorted { $0.timestamp < $1.timestamp }
        let flightData = session.flightDataPoints
            .filter { $0.timestamp >= cutoff }
            .sorted { $0.timestamp < $1.timestamp }

        let hasData = !sensorData.isEmpty || !flightData.isEmpty

        return VStack(alignment: .leading, spacing: 12) {
            Label("Live Chart", systemImage: "chart.xyaxis.line")
                .font(.headline)

            if hasData {
                if !sensorData.isEmpty {
                    miniChart(title: "Pressure (hPa)", color: .orange) {
                        ForEach(sensorData) { reading in
                            LineMark(
                                x: .value("Time", reading.timestamp),
                                y: .value("Pressure", reading.pressureHPa)
                            )
                        }
                    }

                    miniChart(title: "Humidity (%)", color: .cyan) {
                        ForEach(sensorData) { reading in
                            LineMark(
                                x: .value("Time", reading.timestamp),
                                y: .value("Humidity", reading.humidityPercent)
                            )
                        }
                    }
                }

                if !flightData.isEmpty {
                    miniChart(title: units.altitudeLabel, color: .blue) {
                        ForEach(flightData) { point in
                            LineMark(
                                x: .value("Time", point.timestamp),
                                y: .value("Altitude", units.altitudeValue(point.altitudeFt))
                            )
                        }
                    }
                }
            } else {
                Text("Waiting for data...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func miniChart<C: ChartContent>(title: String, color: Color, @ChartContentBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Chart {
                content()
            }
            .foregroundStyle(color)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisValueLabel()
                        .font(.system(size: 8))
                }
            }
            .frame(height: 60)
        }
    }

    private func readout(label: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title3.monospacedDigit().bold())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func stopButton(_ session: FlightSession) -> some View {
        Button(role: .destructive) {
            session.recordingEndedAt = Date()
            manager.stopSession()
        } label: {
            Label("Stop Recording", systemImage: "stop.circle.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .controlSize(.large)
    }

    // MARK: - Idle State

    private var idleView: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "airplane.circle")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("No Active Recording")
                .font(.title2)
                .foregroundStyle(.secondary)
            Button {
                showStartSheet = true
            } label: {
                Label("Start Recording", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 40)
            Spacer()
        }
        .sheet(isPresented: $showStartSheet) {
            StartRecordingSheet()
        }
    }
}

#Preview {
    DashboardView()
        .environment(DataCollectionManager())
        .modelContainer(for: FlightSession.self, inMemory: true)
}
