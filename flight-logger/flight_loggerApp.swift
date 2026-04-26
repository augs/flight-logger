//
//  flight_loggerApp.swift
//  flight-logger
//
//  Created by august huber on 4/4/26.
//

import SwiftUI
import SwiftData

@main
struct flight_loggerApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var dataCollectionManager = DataCollectionManager()

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            FlightSession.self,
            SensorReading.self,
            FlightDataPoint.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(dataCollectionManager)
                .onAppear {
                    dataCollectionManager.resumeActiveSession(modelContainer: sharedModelContainer)
                }
        }
        .modelContainer(sharedModelContainer)
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                dataCollectionManager.handleEnteredBackground()
            case .active:
                dataCollectionManager.handleBecameActive()
            default:
                break
            }
        }
    }
}
