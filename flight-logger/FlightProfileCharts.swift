//
//  FlightProfileCharts.swift
//  flight-logger
//
//  Created by august huber on 9/8/26.
//

import SwiftUI
import Charts

/// Stacked flight-profile charts sharing one time axis.
///
/// The series live in separate charts rather than one chart with several Y
/// axes: pressure (hPa), humidity (%) and altitude (ft/m) have no common scale,
/// and Swift Charts has no real dual-axis support. Stacking them is also how
/// you actually read a flight profile — the question is almost always "what did
/// cabin pressure do *when* we climbed", which needs the panels vertically
/// aligned on a shared X domain.
///
/// That sharing is the point: pan, zoom and scrubbing are driven by state held
/// here and applied to every panel, so the panels cannot drift out of step.
/// Previously each chart scrolled independently, which made correlating them
/// impossible.
struct FlightProfileCharts: View {

    let sensorReadings: [SensorReading]
    let flightDataPoints: [FlightDataPoint]
    let deviceReadings: [DeviceReading]
    let units: UnitPreference

    @Binding var showAltitude: Bool
    @Binding var showPressure: Bool
    @Binding var showHumidity: Bool

    /// Width of the visible time window. `nil` means "fit all data", which is
    /// the default and keeps tracking newly arriving points during a live
    /// recording rather than pinning to a stale window.
    @State private var visibleSeconds: TimeInterval?
    @State private var scrollPosition = Date()
    @State private var zoomBase: TimeInterval?
    @State private var selectedTime: Date?

    /// Don't allow zooming past a window this small — beyond it the line is
    /// noise between two samples.
    private static let minimumWindow: TimeInterval = 120

    private var panelHeight: CGFloat { 150 }

    /// Device rows carrying a usable barometric pressure.
    private var phonePressure: [DeviceReading] {
        deviceReadings.filter { $0.pressureHPa != nil }
    }

    /// Device rows with a GNSS altitude the fix actually supports. Cabin fixes
    /// are frequently poor, and plotting a 200 m-accuracy sample beside the
    /// airline's figure would invent a disagreement that isn't real.
    private var gpsAltitude: [DeviceReading] {
        deviceReadings.filter {
            guard $0.gpsAltitudeMeters != nil, let accuracy = $0.gpsVerticalAccuracy else { return false }
            return accuracy > 0 && accuracy < 50
        }
    }

    // MARK: - Domain

    private var timeBounds: (start: Date, end: Date)? {
        let stamps = sensorReadings.map(\.timestamp)
            + flightDataPoints.map(\.timestamp)
            + deviceReadings.map(\.timestamp)
        guard let first = stamps.min(), let last = stamps.max() else { return nil }
        // A single sample, or several within the same instant, would give a
        // zero-width domain that Charts renders as an empty panel.
        return last.timeIntervalSince(first) < 60
            ? (first, first.addingTimeInterval(60))
            : (first, last)
    }

    private var fullSpan: TimeInterval {
        guard let bounds = timeBounds else { return 3600 }
        return bounds.end.timeIntervalSince(bounds.start)
    }

    /// Window actually applied to the charts.
    private var window: TimeInterval {
        min(visibleSeconds ?? fullSpan, fullSpan)
    }

    private var isZoomed: Bool {
        guard let visibleSeconds else { return false }
        return visibleSeconds < fullSpan - 1
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            seriesToggles
            if !phonePressure.isEmpty || !gpsAltitude.isEmpty {
                HStack(spacing: 12) {
                    legend("Tag / Airline", .orange, dashed: false)
                    legend("Phone sensors", .purple, dashed: true)
                }
            }

            if timeBounds == nil {
                ContentUnavailableView(
                    "No data yet",
                    systemImage: "chart.xyaxis.line",
                    description: Text("Readings will appear here as they are collected.")
                )
                .frame(height: panelHeight)
            } else {
                if showAltitude && !(flightDataPoints.isEmpty && gpsAltitude.isEmpty) {
                    panel(title: units.altitudeLabel, color: .blue) {
                        ForEach(flightDataPoints) { point in
                            LineMark(
                                x: .value("Time", point.timestamp),
                                y: .value("Altitude", units.altitudeValue(point.altitudeFt)),
                                series: .value("Source", "Airline")
                            )
                            .foregroundStyle(.blue)
                        }
                        // GNSS altitude is not pressure altitude and will not
                        // match the airline's figure; both are kept rather than
                        // reconciled.
                        ForEach(gpsAltitude) { reading in
                            LineMark(
                                x: .value("Time", reading.timestamp),
                                y: .value("Altitude", units.altitudeValue((reading.gpsAltitudeMeters ?? 0) / 0.3048)),
                                series: .value("Source", "GPS")
                            )
                            .foregroundStyle(.teal)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        }
                    }
                }
                if showPressure && !(sensorReadings.isEmpty && phonePressure.isEmpty) {
                    panel(title: "Cabin Pressure (hPa)", color: .orange) {
                        ForEach(sensorReadings) { reading in
                            LineMark(
                                x: .value("Time", reading.timestamp),
                                y: .value("Pressure", reading.pressureHPa),
                                series: .value("Source", "Tag")
                            )
                            .foregroundStyle(.orange)
                        }
                        // Same quantity, independent sensor. Plotted together
                        // deliberately — divergence between them is the signal.
                        ForEach(phonePressure) { reading in
                            LineMark(
                                x: .value("Time", reading.timestamp),
                                y: .value("Pressure", reading.pressureHPa ?? 0),
                                series: .value("Source", "Phone")
                            )
                            .foregroundStyle(.purple)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        }
                    }
                }
                if showHumidity && !sensorReadings.isEmpty {
                    panel(title: "Humidity (%)", color: .cyan) {
                        ForEach(sensorReadings) { reading in
                            LineMark(
                                x: .value("Time", reading.timestamp),
                                y: .value("Humidity", reading.humidityPercent)
                            )
                        }
                    }
                }
                hint
            }
        }
        .onAppear { scrollPosition = timeBounds?.start ?? Date() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Flight Profile")
                .font(.headline)
            Spacer()
            if let selectedTime {
                Text(selectedTime.formatted(date: .omitted, time: .standard))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else if isZoomed {
                Button("Fit All") {
                    withAnimation {
                        visibleSeconds = nil
                        scrollPosition = timeBounds?.start ?? Date()
                    }
                }
                .font(.caption)
                .buttonStyle(.bordered)
            } else {
                Text(Self.formatSpan(fullSpan))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var hint: some View {
        if selectedTime == nil {
            Text(isZoomed ? "Drag to pan · pinch to zoom · touch a chart to inspect"
                          : "Pinch to zoom · touch a chart to inspect")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Panels

    @ViewBuilder
    private func panel<C: ChartContent>(
        title: String,
        color: Color,
        @ChartContentBuilder content: () -> C
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                // Value at the scrubbed time, so the panels can be read
                // together rather than eyeballed against each other.
                if let selectedTime, let reading = valueText(at: selectedTime, for: title) {
                    Text(reading)
                        .font(.caption.monospacedDigit().bold())
                        .foregroundStyle(color)
                }
            }

            Chart {
                content()

                if let selectedTime {
                    RuleMark(x: .value("Selected", selectedTime))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .foregroundStyle(color)
            .chartXScale(domain: timeBounds.map { $0.start...$0.end } ?? Date()...Date())
            .chartScrollableAxes(.horizontal)
            .chartXVisibleDomain(length: window)
            .chartScrollPosition(x: $scrollPosition)
            // Native selection coexists with scroll panning; a raw DragGesture
            // overlay would fight it.
            .chartXSelection(value: $selectedTime)
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine()
                    AxisValueLabel().font(.system(size: 9))
                }
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour().minute())
                        .font(.system(size: 9))
                }
            }
            .frame(height: panelHeight)
            .gesture(zoomGesture)
        }
    }

    // MARK: - Zoom

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = zoomBase ?? window
                if zoomBase == nil { zoomBase = base }
                // Pinch out (magnification > 1) shows less time, i.e. zooms in.
                let proposed = base / value.magnification
                visibleSeconds = min(max(proposed, Self.minimumWindow), fullSpan)
            }
            .onEnded { _ in zoomBase = nil }
    }

    // MARK: - Scrub readout

    /// Nearest sample to the scrubbed time, formatted for the given panel.
    private func valueText(at time: Date, for title: String) -> String? {
        if title == units.altitudeLabel {
            guard let point = nearest(flightDataPoints, to: time, key: \.timestamp) else { return nil }
            return units.formatAltitude(point.altitudeFt)
        }
        guard let reading = nearest(sensorReadings, to: time, key: \.timestamp) else { return nil }
        if title.hasPrefix("Cabin Pressure") {
            return String(format: "%.1f hPa", reading.pressureHPa)
        }
        if title.hasPrefix("Humidity") {
            return String(format: "%.1f%%", reading.humidityPercent)
        }
        return nil
    }

    private func nearest<T>(_ items: [T], to time: Date, key: KeyPath<T, Date>) -> T? {
        items.min {
            abs($0[keyPath: key].timeIntervalSince(time)) < abs($1[keyPath: key].timeIntervalSince(time))
        }
    }

    // MARK: - Toggles

    private var seriesToggles: some View {
        HStack(spacing: 8) {
            toggle("Altitude", .blue, $showAltitude)
            toggle("Pressure", .orange, $showPressure)
            toggle("Humidity", .cyan, $showHumidity)
        }
    }

    private func legend(_ label: String, _ color: Color, dashed: Bool) -> some View {
        HStack(spacing: 4) {
            Rectangle()
                .fill(color)
                .frame(width: dashed ? 6 : 14, height: 2)
            if dashed {
                Rectangle().fill(color).frame(width: 6, height: 2)
            }
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func toggle(_ label: String, _ color: Color, _ isOn: Binding<Bool>) -> some View {
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
            .background(isOn.wrappedValue ? color.opacity(0.12) : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    static func formatSpan(_ interval: TimeInterval) -> String {
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(Int(interval))s"
    }
}
