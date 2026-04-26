//
//  ContentView.swift
//  flight-logger
//
//  Created by august huber on 4/4/26.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    var body: some View {
        TabView {
            Tab("Dashboard", systemImage: "gauge.with.dots.needle.33percent") {
                DashboardView()
            }
            Tab("Flights", systemImage: "list.bullet.clipboard") {
                FlightListView()
            }
            Tab("Settings", systemImage: "gear") {
                SettingsView()
            }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: FlightSession.self, inMemory: true)
}
