//
//  FlightDetailView.swift
//  flight-logger
//
//  Created by august huber on 4/4/26.
//

import SwiftUI
import SwiftData
import Charts

struct FlightDetailView: View {
    let session: FlightSession

    @AppStorage("unitPreference") private var units: UnitPreference = .system
    @State private var showPressure = true
    @State private var showHumidity = true
    @State private var showAltitude = true

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                metadataSection
                if !session.sensorReadings.isEmpty || !session.flightDataPoints.isEmpty {
                    chartSection
                }
            }
            .padding()
        }
        .navigationTitle(session.displayTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: - Metadata

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
            units: units,
            showAltitude: $showAltitude,
            showPressure: $showPressure,
            showHumidity: $showHumidity
        )
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
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
