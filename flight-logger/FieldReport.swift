//
//  FieldReport.swift
//  flight-logger
//
//  Created by august huber on 9/20/26.
//

import Foundation

/// Builds a report about unrecognised fields in an airline response, ready for
/// the user to file as an issue.
///
/// **Nothing is ever sent automatically.** This produces text and a pre-filled
/// URL; the user reads the redacted payload, then decides. That is the same
/// reasoning `DATA_SHARING.md` reaches for contributions — no backend, no
/// account, no upload the user did not perform themselves — and it matters more
/// here, because an issue tracker is public and permanent.
enum FieldReport {

    /// Where reports go. One constant so a fork does not silently file issues
    /// against this repository.
    static let repository = "augs/flight-logger"

    /// GitHub rejects very long URLs, and the limit is not documented
    /// precisely. Keep well under the commonly cited ~8 KB so a report never
    /// fails at the last step, and fall back to the share sheet beyond it.
    static let urlBodyLimit = 6000

    struct Draft {
        let title: String
        let body: String
        /// True when the body fits in a pre-filled URL. When false the caller
        /// should offer copy/share instead of opening a browser.
        var fitsInURL: Bool { body.count <= urlBodyLimit }
    }

    /// A report for one provider's response.
    ///
    /// - Parameters:
    ///   - provider: the config that was detected, or a description of the
    ///     custom endpoint when the user supplied one.
    ///   - unmapped: paths the config did not read.
    ///   - payload: the raw response, redacted before it reaches the body.
    static func draft(
        provider: String,
        endpoint: String,
        unmapped: [PayloadInspector.Leaf],
        payload: [String: Any],
        appVersion: String = Bundle.main.shortVersion
    ) -> Draft {
        let title = unmapped.isEmpty
            ? "Payload capture: \(provider)"
            : "Unmapped fields (\(unmapped.count)) in \(provider) response"

        var body = """
        Captured by flight-logger \(appVersion) from an in-flight portal.

        **Provider:** \(provider)
        **Endpoint:** `\(endpoint)`

        """

        if unmapped.isEmpty {
            body += """

            No unmapped fields — the config covers everything in this response.
            Filed as a capture, since every config in `AIRLINE_APIS.md` is
            derived from third-party clients rather than a real response.

            """
        } else {
            body += """

            ### Fields the config does not read

            | Path | Type |
            |---|---|

            """
            for leaf in unmapped {
                body += "| `\(leaf.path)` | \(leaf.type) |\n"
            }
        }

        body += """

        ### Response

        Values are redacted: keys, structure and types are preserved, which is
        what a field mapping is built from. Numbers are kept so units can be
        told apart, except coordinates. Identifying values — flight number,
        tail number, gate, seat — are replaced with their type.

        ```json
        \(PayloadInspector.redactedJSONText(payload))
        ```
        """

        return Draft(title: title, body: body)
    }

    /// Pre-filled "new issue" URL.
    ///
    /// A plain GET into the browser rather than the API: no token to store, no
    /// network permission, and the user sees exactly what will be posted on
    /// GitHub's own page before pressing submit.
    static func issueURL(for draft: Draft) -> URL? {
        var components = URLComponents(string: "https://github.com/\(repository)/issues/new")
        components?.queryItems = [
            URLQueryItem(name: "title", value: draft.title),
            URLQueryItem(name: "labels", value: "airline-api"),
            URLQueryItem(name: "body", value: draft.body),
        ]
        return components?.url
    }
}

extension Bundle {
    var shortVersion: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
