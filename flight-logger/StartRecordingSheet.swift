//
//  StartRecordingSheet.swift
//  flight-logger
//
//  Created by august huber on 4/4/26.
//

import SwiftUI
import SwiftData

/// Sheet presented when starting a new recording session.
/// Handles auto-detect, manual entry, and fallback flows based on user preference.
struct StartRecordingSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @AppStorage("recordingStartMode") private var startMode: RecordingStartMode = .autoWithFallback

    @State private var phase: Phase = .idle
    @State private var manualLabel = ""
    @State private var detectedConfig: AirlineConfig?
    @State private var detectedJSON: [String: Any]?

    enum Phase {
        case idle
        case detecting
        case detected(airline: String, flightNumber: String, route: String)
        case manualEntry
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                switch phase {
                case .idle:
                    Color.clear.onAppear { beginFlow() }

                case .detecting:
                    detectingView

                case .detected(let airline, let flightNumber, let route):
                    detectedView(airline: airline, flightNumber: flightNumber, route: route)

                case .manualEntry:
                    manualEntryView

                case .failed(let message):
                    failedView(message: message)
                }
            }
            .padding()
            .navigationTitle("Start Recording")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    // MARK: - Flow Logic

    private func beginFlow() {
        switch startMode {
        case .manual:
            phase = .manualEntry
        case .autoDetect:
            phase = .detecting
            Task { await detectAirline() }
        case .autoWithFallback:
            phase = .detecting
            Task { await detectAirline() }
        }
    }

    private func detectAirline() async {
        let configs = AirlineConfigLoader.loadAll()
        let session = URLSession(configuration: {
            let c = URLSessionConfiguration.default
            c.timeoutIntervalForRequest = 8
            return c
        }())

        for config in configs {
            guard let url = URL(string: config.url) else { continue }
            do {
                let (data, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse,
                      (200...299).contains(http.statusCode),
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }

                // Extract preview info
                let fields = config.fields
                let flightNum = resolveString(json: json, path: fields.flightNumber) ?? ""
                let origin = resolveString(json: json, path: fields.origin) ?? ""
                let dest = resolveString(json: json, path: fields.destination) ?? ""
                let route = (origin.isEmpty && dest.isEmpty) ? "" : "\(origin) → \(dest)"

                detectedConfig = config
                detectedJSON = json
                phase = .detected(airline: config.airline, flightNumber: flightNum, route: route)
                return
            } catch {
                continue
            }
        }

        // No API found
        switch startMode {
        case .autoWithFallback:
            phase = .manualEntry
        case .autoDetect:
            phase = .failed("No airline WiFi API detected. Make sure you're connected to in-flight WiFi.")
        case .manual:
            phase = .manualEntry
        }
    }

    // MARK: - Detecting

    private var detectingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("Detecting airline WiFi...")
                .font(.headline)
            Text("Checking for in-flight API")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Detected

    private func detectedView(airline: String, flightNumber: String, route: String) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "wifi")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("Found \(airline) WiFi")
                .font(.title2.bold())
            if !flightNumber.isEmpty {
                Text(flightNumber)
                    .font(.title3)
            }
            if !route.isEmpty {
                Text(route)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                createAutoSession()
            } label: {
                Label("Start Recording", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button("Enter details manually instead") {
                phase = .manualEntry
            }
            .font(.subheadline)
        }
    }

    // MARK: - Manual Entry

    private var manualEntryView: some View {
        VStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Flight Label")
                    .font(.headline)
                Text("Enter a flight number or description")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("e.g. AA 123 / 2026-04-04", text: $manualLabel)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                    #endif
            }

            Spacer()

            Button {
                createManualSession()
            } label: {
                Label("Start Recording", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // MARK: - Failed

    private func failedView(message: String) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "wifi.slash")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Detection Failed")
                .font(.title2.bold())
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button("Enter details manually") {
                phase = .manualEntry
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // MARK: - Session Creation

    private func createAutoSession() {
        guard let config = detectedConfig, let json = detectedJSON else { return }
        let fields = config.fields

        let session = FlightSession(
            flightNumber: resolveString(json: json, path: fields.flightNumber) ?? "",
            airline: config.airline,
            origin: resolveString(json: json, path: fields.origin) ?? "",
            destination: resolveString(json: json, path: fields.destination) ?? "",
            aircraftModel: resolveString(json: json, path: fields.aircraftModel) ?? "",
            recordingMode: "api-auto"
        )
        modelContext.insert(session)
        dismiss()
    }

    private func createManualSession() {
        let session = FlightSession(
            flightNumber: manualLabel.trimmingCharacters(in: .whitespaces),
            recordingMode: "manual"
        )
        modelContext.insert(session)
        dismiss()
    }

    // MARK: - JSON Helpers

    private func resolveString(json: [String: Any], path: String?) -> String? {
        guard let path else { return nil }
        let components = path.split(separator: ".").map(String.init)
        var current: Any = json
        for key in components {
            guard let dict = current as? [String: Any], let next = dict[key] else { return nil }
            current = next
        }
        if let s = current as? String { return s }
        return "\(current)"
    }
}

#Preview {
    StartRecordingSheet()
        .modelContainer(for: FlightSession.self, inMemory: true)
}
