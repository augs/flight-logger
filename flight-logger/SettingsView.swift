//
//  SettingsView.swift
//  flight-logger
//
//  Created by august huber on 4/4/26.
//

import SwiftUI

struct SettingsView: View {
    @AppStorage("recordingStartMode") private var startMode: RecordingStartMode = .autoWithFallback
    @AppStorage("unitPreference") private var unitPreference: UnitPreference = .system

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Session start", selection: $startMode) {
                        ForEach(RecordingStartMode.allCases) { mode in
                            VStack(alignment: .leading) {
                                Text(mode.displayName)
                                Text(mode.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(mode)
                        }
                    }
                    .pickerStyle(.inline)
                } header: {
                    Text("Recording")
                } footer: {
                    Text("Controls what happens when you tap Start Recording. The default tries to detect airline WiFi and falls back to manual entry.")
                }

                Section {
                    Picker("Units", selection: $unitPreference) {
                        ForEach(UnitPreference.allCases) { pref in
                            VStack(alignment: .leading) {
                                Text(pref.displayName)
                                Text(pref.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(pref)
                        }
                    }
                    .pickerStyle(.inline)
                } header: {
                    Text("Units")
                } footer: {
                    Text("Choose how altitude, speed, and temperature are displayed. System Default uses your device's region settings.")
                }
            }
            .navigationTitle("Settings")
        }
    }
}

#Preview {
    SettingsView()
}
