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
    @AppStorage(AirlineConfigLoader.discoveryURLKey) private var discoveryURL: String = ""
    @AppStorage(CapturePolicy.captureEnabledKey) private var captureEnabled: Bool = false
    @AppStorage(CapturePolicy.reportingEnabledKey) private var reportingEnabled: Bool = false
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
                    Toggle("Capture airline responses", isOn: $captureEnabled)
                    Toggle("Offer to report captures", isOn: $reportingEnabled)
                } header: {
                    Text("Airline API capture")
                } footer: {
                    Text("""
                    Capturing keeps each airline response that says something new — when unknown fields appear, when the status text changes, and when the aircraft touches down — plus one every five minutes otherwise. It runs unattended for the whole flight and stays on your device.

                    These APIs are only reachable in the air, and no config in this app has ever been checked against a real response, so a captured flight is the only way to confirm or fix them. United in particular has no on-ground field: its landing wording exists only after touchdown.

                    Reporting is separate and sends nothing by itself — it adds a button that opens a pre-filled GitHub issue with values redacted, which you submit yourself.
                    """)
                }

                Section {
                    TextField("https://portal.example.com/api/flightdata", text: $discoveryURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospaced())
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        #endif
                } header: {
                    Text("Unknown airline API")
                } footer: {
                    Text("For an in-flight portal this app does not recognise. Unlike the configs, this accepts any JSON and maps nothing — it captures the response so its fields can be read off afterwards and turned into a real config. Find it in your browser's network inspector, or try the address the map page loads from.")
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
