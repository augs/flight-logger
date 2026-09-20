//
//  CaptureListView.swift
//  flight-logger
//
//  Created by august huber on 9/20/26.
//

import SwiftUI

/// The responses captured during one flight.
///
/// Readable on the phone, because the point of the feature is not needing a
/// laptop. Each capture says why it was kept, and the unmapped fields are
/// shown *with their values* — locally, values are the useful part. An
/// altitude that reaches 35,000 is feet; the status text at touchdown is the
/// answer to bug B2.
struct CaptureListView: View {
    let session: FlightSession

    private var captures: [PayloadCapture] {
        session.payloadCaptures.sorted { $0.timestamp < $1.timestamp }
    }

    var body: some View {
        List {
            if captures.isEmpty {
                ContentUnavailableView(
                    "No captures",
                    systemImage: "tray",
                    description: Text("Turn on “Capture airline responses” in Settings before a flight.")
                )
            } else {
                Section {
                    ForEach(captures) { capture in
                        NavigationLink {
                            CaptureDetailView(capture: capture)
                        } label: {
                            row(capture)
                        }
                    }
                } footer: {
                    Text("^[\(captures.count) capture](inflect: true) from this flight. Stored on this device.")
                }
            }
        }
        .navigationTitle("Captures")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func row(_ capture: PayloadCapture) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(capture.captureReason.label)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(capture.timestamp.formatted(date: .omitted, time: .standard))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !capture.unmappedFields.isEmpty {
                Text("^[\(capture.unmappedFields.count) unrecognised field](inflect: true)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// One capture, with values.
struct CaptureDetailView: View {
    let capture: PayloadCapture

    private var unmappedWithValues: [(path: String, type: String, value: String)] {
        guard let json = capture.json else { return [] }
        return capture.unmappedFields.map {
            ($0.path, $0.type, PayloadInspector.valuePreview(json, path: $0.path))
        }
    }

    var body: some View {
        List {
            Section("Why") {
                LabeledContent("Reason", value: capture.captureReason.label)
                LabeledContent("Time", value: capture.timestamp.formatted())
                LabeledContent("Provider", value: capture.provider)
            }

            if !unmappedWithValues.isEmpty {
                Section {
                    ForEach(unmappedWithValues, id: \.path) { field in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(field.path)
                                .font(.caption.monospaced())
                            Text(field.value.isEmpty ? field.type : field.value)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                } header: {
                    Text("Unrecognised fields")
                } footer: {
                    Text("Values shown because they are what identifies a field's meaning. These stay on your device; a report redacts them.")
                }
            }

            Section("Full response") {
                Text(capture.body)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
            }
        }
        .navigationTitle(capture.captureReason.label)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
