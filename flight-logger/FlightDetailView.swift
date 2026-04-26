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
            LabeledContent("Sensor readings", value: "\(session.sensorReadings.count)")
            LabeledContent("Flight data points", value: "\(session.flightDataPoints.count)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Charts

    private var chartSection: some View {
        let sensorData = session.sensorReadings.sorted { $0.timestamp < $1.timestamp }
        let flightData = session.flightDataPoints.sorted { $0.timestamp < $1.timestamp }

        return VStack(alignment: .leading, spacing: 16) {
            Text("Flight Profile")
                .font(.headline)

            seriesToggles

            if showAltitude && !flightData.isEmpty {
                seriesChart(title: units.altitudeLabel, color: .blue) {
                    ForEach(flightData) { point in
                        LineMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Altitude", units.altitudeValue(point.altitudeFt))
                        )
                    }
                }
            }

            if showPressure && !sensorData.isEmpty {
                seriesChart(title: "Cabin Pressure (hPa)", color: .orange) {
                    ForEach(sensorData) { reading in
                        LineMark(
                            x: .value("Time", reading.timestamp),
                            y: .value("Pressure", reading.pressureHPa)
                        )
                    }
                }
            }

            if showHumidity && !sensorData.isEmpty {
                seriesChart(title: "Humidity (%)", color: .cyan) {
                    ForEach(sensorData) { reading in
                        LineMark(
                            x: .value("Time", reading.timestamp),
                            y: .value("Humidity", reading.humidityPercent)
                        )
                    }
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var seriesToggles: some View {
        HStack(spacing: 12) {
            seriesToggle(label: "Altitude", color: .blue, isOn: $showAltitude)
            seriesToggle(label: "Pressure", color: .orange, isOn: $showPressure)
            seriesToggle(label: "Humidity", color: .cyan, isOn: $showHumidity)
        }
    }

    private func seriesToggle(label: String, color: Color, isOn: Binding<Bool>) -> some View {
        Button {
            withAnimation { isOn.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(isOn.wrappedValue ? color : .gray.opacity(0.3))
                    .frame(width: 8, height: 8)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(isOn.wrappedValue ? .primary : .secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                isOn.wrappedValue ? color.opacity(0.1) : Color.clear,
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
    }

    private func seriesChart<C: ChartContent>(title: String, color: Color, @ChartContentBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Chart {
                content()
            }
            .foregroundStyle(color)
            .chartScrollableAxes(.horizontal)
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine()
                    AxisValueLabel()
                        .font(.system(size: 9))
                }
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour().minute())
                        .font(.system(size: 9))
                }
            }
            .frame(height: 160)
        }
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
