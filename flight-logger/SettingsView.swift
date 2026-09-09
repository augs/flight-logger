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
    @AppStorage(AirlineConfigLoader.testURLKey) private var testAPIURL: String = ""
    @AppStorage(HealthKitService.enabledKey) private var healthKitEnabled: Bool = false
    @State private var health = HealthKitService()

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

                Section {
                    Toggle("Record health data", isOn: $healthKitEnabled)
                    if healthKitEnabled, health.status == .unavailable {
                        Label("Health data isn't available on this device",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Health")
                } footer: {
                    Text("Reads heart rate, blood oxygen, HRV and respiratory rate recorded during a flight, so they can be compared against cabin conditions. Read-only, never written, and stays on your device.\n\nBlood oxygen cannot be requested on demand — Apple provides no way to trigger a reading — so samples appear only when your Watch takes one, usually while you are still.")
                }
                .onChange(of: healthKitEnabled) { _, enabled in
                    // Turning the switch on is the consent, so that is when the
                    // system prompt appears — nothing is requested at launch.
                    if enabled {
                        Task { await health.requestAuthorization() }
                    } else {
                        health.refreshStatus()
                    }
                }

                Section {
                    TextField("http://192.168.1.10:8080/…", text: $testAPIURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospaced())
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        #endif
                } header: {
                    Text("Test API URL")
                } footer: {
                    Text("Probed before the bundled airline configs. Point this at Tools-MockAirlineAPI.py on your network to exercise the polling path without flying. Leave empty in normal use.")
                }

                Section {
                    NavigationLink {
                        DiagnosticsView()
                    } label: {
                        Label("Diagnostics", systemImage: "stethoscope")
                    }
                } header: {
                    Text("Advanced")
                } footer: {
                    Text("Background collection health: link state, sampling gaps, storage and battery. Useful for checking whether a flight recorded cleanly.")
                }
            }
            .navigationTitle("Settings")
        }
    }
}

#Preview {
    SettingsView()
}
