//
//  GoogleAPIModels.swift
//  Olana
//
//  Codable structs for Google Calendar v3 API responses.
//  Phase 2 (v1.1) — not yet connected to any live code path.
//

import Foundation

// MARK: - Calendar List

struct GCalendarListResponse: Codable {
    let kind: String?
    let items: [GCalendarListEntry]
}

struct GCalendarListEntry: Codable {
    let id: String
    let summary: String
    let backgroundColor: String?
    let foregroundColor: String?
    let selected: Bool?
    let primary: Bool?
    let accessRole: String?
}

// MARK: - Events List

struct GEventListResponse: Codable {
    let kind: String?
    let summary: String?
    let nextPageToken: String?
    let items: [GEvent]
}

struct GEvent: Codable {
    let id: String
    let summary: String?
    let description: String?
    let location: String?
    let status: String?         // "confirmed", "tentative", "cancelled"
    let start: GEventDateTime
    let end: GEventDateTime
    let recurrence: [String]?
    let updated: String?        // RFC 3339
    let htmlLink: String?
}

struct GEventDateTime: Codable {
    let dateTime: String?  // RFC 3339 — for timed events
    let date: String?      // YYYY-MM-DD — for all-day events
    let timeZone: String?
}
