//
//  FieldReportView.swift
//  flight-logger
//
//  Created by august huber on 9/20/26.
//

import SwiftUI

/// Review screen for reporting unrecognised fields from an airline response.
///
/// Deliberately a review screen rather than a "Send" button. The payload is
/// going to a public issue tracker, so the user sees the redacted text in full
/// before anything opens, and the act of filing happens on GitHub's own page
/// where they can still back out.
struct FieldReportView: View {
    let session: FlightSession

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var showingRawPayload = false
    @State private var copied = false

    private var unmapped: [PayloadInspector.Leaf] { session.unmappedFields }

    private var payload: [String: Any] {
        guard let data = session.rawFirstResponse.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return json
    }

    private var draft: FieldReport.Draft {
        FieldReport.draft(
            provider: session.apiProvider.isEmpty ? "Unknown" : session.apiProvider,
            endpoint: AirlineConfigLoader.loadConfig(named: session.apiProvider)?.url ?? "(unrecorded)",
            unmapped: unmapped,
            payload: payload
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if unmapped.isEmpty {
                        Label("Everything in this response was recognised",
                              systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(unmapped, id: \.path) { leaf in
                            HStack {
                                Text(leaf.path)
                                    .font(.caption.monospaced())
                                Spacer()
                                Text(leaf.type)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text(unmapped.isEmpty ? "Fields" : "^[\(unmapped.count) unrecognised field](inflect: true)")
                } footer: {
                    Text("Every airline config in this app is derived from other people's code, not from a real response. Reporting these is how they get mapped.")
                }

                Section {
                    DisclosureGroup("Exactly what will be sent", isExpanded: $showingRawPayload) {
                        Text(PayloadInspector.redactedJSONText(payload))
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                    }
                } footer: {
                    Text("Values are redacted. Keys, structure and types are kept — that is what a field mapping is built from. Numbers are kept so feet can be told from metres, except coordinates. Your flight number, tail number, gate and seat are replaced with their type.")
                }

                Section {
                    if draft.fitsInURL, let url = FieldReport.issueURL(for: draft) {
                        Button {
                            openURL(url)
                        } label: {
                            Label("Open a pre-filled issue…", systemImage: "arrow.up.forward.square")
                        }
                    }

                    Button {
                        copyToPasteboard(draft.body)
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy report", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                } footer: {
                    if draft.fitsInURL {
                        Text("Opens GitHub with the report filled in. Nothing is posted until you press submit there, and nothing is sent from this app.")
                    } else {
                        Text("This payload is too large to pre-fill a GitHub issue, so copy it and paste it into a new issue instead. Nothing is sent from this app.")
                    }
                }
            }
            .navigationTitle("Report fields")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func copyToPasteboard(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
