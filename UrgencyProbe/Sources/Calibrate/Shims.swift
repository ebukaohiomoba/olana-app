//
//  Shims.swift
//  Calibrate
//
//  The one app type UrgencyCombiner needs that lives in a file with SwiftData
//  and SwiftUI dependencies. Copied from NovelEvent.swift; raw values must match.
//

public enum EventUrgency: Int, Codable, CaseIterable, Sendable {
    case low = 0
    case medium = 1
    case high = 2
}
