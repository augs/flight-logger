//
//  ShareSheet.swift
//  flight-logger
//
//  Created by august huber on 9/8/26.
//

import SwiftUI

#if os(iOS)
import UIKit

/// `UIActivityViewController` wrapper, so exported files can go to Files,
/// AirDrop, mail or anywhere else the user already uses.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#else
/// macOS builds the same target for the test host; the share sheet is iOS-only,
/// so this keeps the view code platform-free.
struct ShareSheet: View {
    let items: [Any]
    var body: some View {
        Text("Sharing is available on iOS.").padding()
    }
}
#endif
