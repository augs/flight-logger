//
//  FlightListView.swift
//  flight-logger
//
//  Created by august huber on 4/4/26.
//

import SwiftUI
import SwiftData

struct FlightListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FlightSession.recordingStartedAt, order: .reverse)
    private var sessions: [FlightSession]

    @State private var sortOrder: SortOrder = .date

    enum SortOrder: String, CaseIterable {
        case date = "Date"
        case flightNumber = "Flight #"
    }

    private var sortedSessions: [FlightSession] {
        switch sortOrder {
        case .date:
            return sessions // already sorted by @Query
        case .flightNumber:
            return sessions.sorted { a, b in
                a.flightNumber.localizedStandardCompare(b.flightNumber) == .orderedAscending
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(sortedSessions) { session in
                    NavigationLink(value: session) {
                        FlightSessionRow(session: session)
                    }
                }
                .onDelete { offsets in
                    deleteSessions(from: sortedSessions, at: offsets)
                }
            }
            .navigationTitle("Flights")
            .navigationDestination(for: FlightSession.self) { session in
                FlightDetailView(session: session)
            }
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Picker("Sort", selection: $sortOrder) {
                        ForEach(SortOrder.allCases, id: \.self) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }
            .overlay {
                if sessions.isEmpty {
                    ContentUnavailableView(
                        "No Flights",
                        systemImage: "airplane.circle",
                        description: Text("Recorded flights will appear here.")
                    )
                }
            }
        }
    }

    private func deleteSessions(from list: [FlightSession], at offsets: IndexSet) {
        withAnimation {
            for index in offsets {
                modelContext.delete(list[index])
            }
        }
    }
}

// MARK: - Row

struct FlightSessionRow: View {
    let session: FlightSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(session.displayTitle)
                    .font(.headline)
                Spacer()
                if session.isRecording {
                    Label("Live", systemImage: "record.circle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            if !session.routeDescription.isEmpty {
                Text(session.routeDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Text(session.recordingStartedAt.formatted(date: .abbreviated, time: .shortened))
                if let duration = session.duration {
                    Text("·")
                    Text(FlightDetailView.formatDuration(duration))
                }
                if session.hasFlightData {
                    Text("·")
                    Image(systemName: "airplane").font(.caption2)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            // Without this a 20-second aborted test and a real flight look
            // identical in the list.
            CoverageSummary(session: session)
        }
        .padding(.vertical, 2)
    }
}

/// One-line verdict on whether a session actually captured usable data.
struct CoverageSummary: View {
    let session: FlightSession

    var body: some View {
        let coverage = session.coverage

        HStack(spacing: 6) {
            if coverage.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("No sensor data")
                    .foregroundStyle(.orange)
            } else {
                Image(systemName: icon(for: coverage))
                    .foregroundStyle(tint(for: coverage))
                Text("\(coverage.readings) readings")
                    .foregroundStyle(.secondary)

                if let range = session.pressureRange, range.high - range.low >= 1 {
                    Text("·").foregroundStyle(.secondary)
                    Text(String(format: "%.0f–%.0f hPa", range.low, range.high))
                        .foregroundStyle(.secondary)
                }

                // Surface the worst hole rather than an average, which would
                // hide a single long outage inside otherwise dense data.
                if coverage.largestGap > 600 {
                    Text("·").foregroundStyle(.secondary)
                    Text("gap \(FlightProfileCharts.formatSpan(coverage.largestGap))")
                        .foregroundStyle(.orange)
                }
            }
        }
        .font(.caption2)
    }

    private func icon(for coverage: FlightSession.Coverage) -> String {
        if coverage.largestGap > 600 { return "chart.line.downtrend.xyaxis" }
        return coverage.liveFraction > 0.5 ? "waveform.path.ecg" : "clock.arrow.circlepath"
    }

    private func tint(for coverage: FlightSession.Coverage) -> Color {
        if coverage.largestGap > 600 { return .orange }
        return coverage.liveFraction > 0.5 ? .green : .secondary
    }
}

#Preview {
    FlightListView()
        .modelContainer(for: FlightSession.self, inMemory: true)
}
