//
//  RecordingStartMode.swift
//  flight-logger
//
//  Created by august huber on 4/4/26.
//

import Foundation

/// User preference for how flight recording sessions are initiated.
enum RecordingStartMode: String, CaseIterable, Identifiable {
    /// Try to detect airline WiFi first; if not found, prompt for manual entry.
    case autoWithFallback = "auto-fallback"
    /// Always attempt auto-detect; show error if no API found.
    case autoDetect = "auto-detect"
    /// Always prompt the user to enter flight details manually.
    case manual = "manual"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .autoWithFallback: return "Auto-detect with fallback"
        case .autoDetect: return "Auto-detect only"
        case .manual: return "Always manual"
        }
    }

    var description: String {
        switch self {
        case .autoWithFallback: return "Try airline WiFi first, then ask for manual entry"
        case .autoDetect: return "Only use airline WiFi API — error if not found"
        case .manual: return "Always enter flight details manually"
        }
    }
}
