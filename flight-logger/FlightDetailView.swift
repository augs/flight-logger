//
//  FlightDetailView.swift
//  flight-logger
//
//  Created by august huber on 4/4/26.
//

import SwiftUI
import SwiftData
import Charts
#if os(iOS)
import UIKit
#endif

struct FlightDetailView: View {
    let session: FlightSession
    @Environment(\.modelContext) private var modelContext

    @AppStorage("unitPreference") private var units: UnitPreference = .system
    @AppStorage(CapturePolicy.reportingEnabledKey) private var reportingEnabled: Bool = false
    @State private var showPressure = true
    @State private var showHumidity = true
    @State private var showAltitude = true
    @State private var exportFormat: SessionExport.Format?
    @State private var exportURLs: [URL] = []
    @State private var exportError: String?
    @State private var health = HealthKitService()
    @State private var healthMerged: Int?
    @State private var showingFieldReport = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                metadataSection
                unmappedFieldsCard
                if !session.sensorReadings.isEmpty || !session.flightDataPoints.isEmpty
                    || !session.deviceReadings.isEmpty {
                    chartSection
                }
            }
            .padding()
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Menu {
                    ForEach(SessionExport.Format.allCases) { format in
                        Button {
                            export(format)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(format.label)
                                Text(format.detail).font(.caption)
                            }
                        }
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(session.sensorReadings.isEmpty && session.flightDataPoints.isEmpty)
            }
        }
        .sheet(isPresented: Binding(get: { !exportURLs.isEmpty },
                                    set: { if !$0 { exportURLs = [] } })) {
            ShareSheet(items: exportURLs)
        }
        .alert("Export failed", isPresented: Binding(get: { exportError != nil },
                                                     set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
        .task {
            // Refreshed on open rather than only at session end: Watch data
            // syncs on its own schedule, so samples for a flight often arrive
            // well after landing. The merge is idempotent.
            healthMerged = await HealthSampleMerge.refresh(
                session: session, service: health, context: modelContext)
        }
        .navigationTitle(session.displayTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: - Metadata

    /// Offers to report the airline response.
    ///
    /// Shown rather than popped as a dialog: this is never urgent, and a modal
    /// interrupting someone mid-flight to ask about JSON would be the wrong
    /// trade. It waits on the flight detail screen until they are interested.
    ///
    /// Offered for *any* captured payload, not only one with unknown fields. A
    /// response where everything mapped is still worth having: every config in
    /// this app is derived from third-party code rather than a real capture,
    /// so a clean match is the only evidence that a derivation was correct.
    @ViewBuilder
    private var unmappedFieldsCard: some View {
        if !session.payloadCaptures.isEmpty {
            NavigationLink {
                CaptureListView(session: session)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "tray.full")
                        .font(.title2)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("^[\(session.payloadCaptures.count) captured response](inflect: true)")
                            .font(.subheadline.weight(.medium))
                        Text("Recorded through the flight, with values. Stored on this device.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding()
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }

        // Reporting is its own opt-in: capturing is local, sending is not.
        if reportingEnabled, !session.rawFirstResponse.isEmpty {
            let unknown = session.unmappedFields.count
            Button {
                showingFieldReport = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: unknown > 0 ? "questionmark.square.dashed" : "checkmark.square.dashed")
                        .font(.title2)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(unknown > 0
                             ? "^[\(unknown) unrecognised field](inflect: true)"
                             : "Share this capture")
                            .font(.subheadline.weight(.medium))
                        Text(unknown > 0
                             ? "This response had fields the app does not map. Reporting them helps every future flight on this fleet."
                             : "Everything here was recognised. Sending it confirms the field map is right — no config in this app has ever been checked against a real response.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding()
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showingFieldReport) {
                FieldReportView(session: session)
            }
        }
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !session.routeDescription.isEmpty {
                LabeledContent("Route", value: session.routeDescription)
            }
            if !session.airline.isEmpty {
                LabeledContent("Airline", value: session.airline)
            }
            if !session.aircraftModel.isEmpty {
                LabeledContent("Aircraft", value: session.aircraftModel)
            }
            if !session.tailNumber.isEmpty {
                LabeledContent("Registration", value: session.tailNumber)
            }
            if !session.equipmentCode.isEmpty {
                LabeledContent("Equipment", value: session.equipmentCode)
            }
            if !session.departureGate.isEmpty || !session.departureTerminal.isEmpty {
                LabeledContent("Departure gate",
                               value: [session.departureTerminal, session.departureGate]
                                   .filter { !$0.isEmpty }.joined(separator: " · "))
            }
            if !session.arrivalGate.isEmpty || !session.arrivalTerminal.isEmpty {
                LabeledContent("Arrival gate",
                               value: [session.arrivalTerminal, session.arrivalGate]
                                   .filter { !$0.isEmpty }.joined(separator: " · "))
            }
            if !session.originCity.isEmpty || !session.destinationCity.isEmpty {
                LabeledContent("Cities",
                               value: "\(session.originCity) → \(session.destinationCity)")
            }
            if !session.apiProvider.isEmpty {
                LabeledContent("Data source", value: session.apiProvider)
            }
            if !session.healthSamples.isEmpty {
                Divider()
                ForEach(HealthMetric.allCases, id: \.self) { metric in
                    let values = session.healthSamples
                        .filter { $0.healthMetric == metric }
                        .map(\.value)
                    if !values.isEmpty {
                        LabeledContent(metric.label, value: Self.summary(values, unit: metric.unit))
                    }
                }
            }
            LabeledContent("Started", value: session.recordingStartedAt.formatted(date: .abbreviated, time: .shortened))
            if let ended = session.recordingEndedAt {
                LabeledContent("Ended", value: ended.formatted(date: .abbreviated, time: .shortened))
            }
            if let duration = session.duration {
                LabeledContent("Duration", value: Self.formatDuration(duration))
            }
            LabeledContent("Mode", value: session.recordingMode)
            LabeledContent("Flight data points", value: "\(session.flightDataPoints.count)")

            Divider()

            // How the readings were obtained matters as much as how many there
            // are: backfilled rows are 5-minute resolution, live ones a minute.
            let coverage = session.coverage
            LabeledContent("Sensor readings", value: "\(coverage.readings)")
            if coverage.readings > 0 {
                if coverage.provenanceUnknown {
                    LabeledContent("Source", value: "Recorded before provenance tracking")
                        .foregroundStyle(.secondary)
                } else {
                    LabeledContent("Source",
                                   value: "\(coverage.highResolution) live · \(coverage.backfilled) backfilled")
                }
                LabeledContent("Largest gap",
                               value: FlightProfileCharts.formatSpan(coverage.largestGap))
                    .foregroundStyle(coverage.largestGap > 600 ? .orange : .primary)
                if let interval = session.backfillInterval {
                    LabeledContent("Tag log interval",
                                   value: FlightProfileCharts.formatSpan(interval))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Charts

    private var chartSection: some View {
        FlightProfileCharts(
            sensorReadings: session.sensorReadings.sorted { $0.timestamp < $1.timestamp },
            flightDataPoints: session.flightDataPoints.sorted { $0.timestamp < $1.timestamp },
            deviceReadings: session.deviceReadings.sorted { $0.timestamp < $1.timestamp },
            units: units,
            showAltitude: $showAltitude,
            showPressure: $showPressure,
            showHumidity: $showHumidity
        )
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func export(_ format: SessionExport.Format) {
        do {
            exportURLs = try SessionExport.write(session, as: format)
        } catch {
            // Surfaced rather than swallowed: a silent no-op after tapping
            // Export is indistinguishable from the feature being broken.
            exportError = error.localizedDescription
        }
    }

    /// Range plus sample count, since these series are sparse and irregular —
    /// a mean alone would hide that a "reading" is a single measurement.
    static func summary(_ values: [Double], unit: String) -> String {
        guard let low = values.min(), let high = values.max() else { return "—" }
        let count = values.count
        if count == 1 || abs(high - low) < 0.05 {
            return String(format: "%.0f %@ (%d)", high, unit, count)
        }
        return String(format: "%.0f–%.0f %@ (%d)", low, high, unit, count)
    }

    // MARK: - Helpers

    static func formatDuration(_ interval: TimeInterval) -> String {
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}

#Preview {
    NavigationStack {
        FlightDetailView(session: FlightSession(
            flightNumber: "UA 1885",
            airline: "United",
            origin: "EWR",
            destination: "SFO",
            recordingStartedAt: Date().addingTimeInterval(-7200),
            recordingEndedAt: Date(),
            recordingMode: "api-auto"
        ))
    }
    .modelContainer(for: FlightSession.self, inMemory: true)
}
