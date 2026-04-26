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
        VStack(alignment: .leading, spacing: 4) {
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
            Text(session.recordingStartedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    FlightListView()
        .modelContainer(for: FlightSession.self, inMemory: true)
}
