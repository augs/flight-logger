//
//  DiagnosticsView.swift
//  flight-logger
//
//  Created by august huber on 9/8/26.
//

import SwiftUI
import SwiftData

/// Developer-facing view of the background-collection probe.
///
/// These samples exist because background behaviour is otherwise unobservable:
/// logs can't be streamed from a normally-launched app, and attaching a
/// debugger changes the suspension behaviour being measured. Reading them used
/// to require pulling the SQLite store over USB — this makes the same answers
/// available on the device, which matters when the interesting run just
/// happened and the laptop is elsewhere.
struct DiagnosticsView: View {

    @Query(sort: \DiagnosticSample.timestamp, order: .reverse)
    private var samples: [DiagnosticSample]

    private var recent: [DiagnosticSample] { Array(samples.prefix(200)) }

    var body: some View {
        List {
            if recent.isEmpty {
                ContentUnavailableView(
                    "No diagnostics yet",
                    systemImage: "stethoscope",
                    description: Text("Samples are recorded once a minute while a flight is recording.")
                )
            } else {
                Section("Last run") {
                    summaryRows
                }
                Section("Samples") {
                    ForEach(recent) { sample in
                        row(sample)
                    }
                }
            }
        }
        .navigationTitle("Diagnostics")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: - Summary

    @ViewBuilder
    private var summaryRows: some View {
        let window = recent
        let linked = window.filter(\.linkReady).count
        let storeFails = window.filter { !$0.storeReadable }.count
        let netFails = window.filter { !$0.networkOK && $0.networkError != "skipped" }.count
        let worstGap = window.map(\.secondsSincePrevious).max() ?? 0

        LabeledContent("Samples", value: "\(window.count)")
        LabeledContent("Link up", value: "\(linked) / \(window.count)")
        // The worst gap is the honest measure of suspension; an average would
        // hide a single long stall inside otherwise healthy data.
        LabeledContent("Largest gap", value: String(format: "%.0fs", worstGap))
        LabeledContent("Store failures", value: "\(storeFails)")
            .foregroundStyle(storeFails > 0 ? .red : .primary)
        LabeledContent("Network failures", value: "\(netFails)")

        if let battery = window.first(where: { $0.batteryLevel >= 0 }) {
            LabeledContent("Battery", value: "\(Int(battery.batteryLevel * 100))% \(battery.batteryState)")
        }
    }

    // MARK: - Rows

    private func row(_ sample: DiagnosticSample) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(sample.linkReady ? .green : .orange)
                    .frame(width: 7, height: 7)
                Text(sample.timestamp.formatted(date: .omitted, time: .standard))
                    .font(.caption.monospacedDigit())
                Spacer()
                Text(sample.appState)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if sample.batteryLevel >= 0 {
                    Text("\(Int(sample.batteryLevel * 100))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 6) {
                Text("gap \(String(format: "%.0fs", sample.secondsSincePrevious))")
                Text("· \(sample.readingCount) readings")
                if !sample.storeReadable {
                    Text("· STORE BLOCKED").foregroundStyle(.red)
                }
                if !sample.networkOK && sample.networkError != "skipped" {
                    Text("· net fail").foregroundStyle(.orange)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            if !sample.bleStatus.isEmpty {
                Text(sample.bleStatus)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 1)
    }
}
