//
//  GoogleCalendarProvider.swift
//  Olana
//
//  Google Calendar REST API v3 calls.
//  Token acquisition and refresh are handled by GoogleOAuthManager; this class
//  only concerns itself with HTTP requests and response decoding.
//

import Foundation

@MainActor
final class GoogleCalendarProvider {

    private let baseURL = "https://www.googleapis.com/calendar/v3"

    // MARK: - Calendar List

    func fetchCalendarList(for accountId: String) async throws -> [GCalendarListEntry] {
        let token = try await GoogleOAuthManager.shared.validAccessToken(for: accountId)
        guard let url = URL(string: "\(baseURL)/users/me/calendarList") else {
            throw CalendarProviderError.networkError("Invalid URL")
        }
        let data = try await get(url: url, token: token)
        return (try JSONDecoder().decode(GCalendarListResponse.self, from: data)).items
    }

    // MARK: - Events

    func fetchEvents(calendarID: String, from start: Date, to end: Date,
                     for accountId: String) async throws -> [GEvent] {
        let token     = try await GoogleOAuthManager.shared.validAccessToken(for: accountId)
        let encodedID = calendarID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarID
        var comps     = URLComponents(string: "\(baseURL)/calendars/\(encodedID)/events")!
        let iso       = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        comps.queryItems = [
            URLQueryItem(name: "timeMin",      value: iso.string(from: start)),
            URLQueryItem(name: "timeMax",      value: iso.string(from: end)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy",      value: "startTime"),
            URLQueryItem(name: "maxResults",   value: "250"),
        ]
        guard let url = comps.url else {
            throw CalendarProviderError.networkError("Could not build request URL")
        }
        let data     = try await get(url: url, token: token)
        let response = try JSONDecoder().decode(GEventListResponse.self, from: data)
        return response.items.filter { $0.status != "cancelled" }
    }

    // MARK: - Private

    private func get(url: URL, token: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CalendarProviderError.networkError("No HTTP response")
        }
        switch http.statusCode {
        case 200...299: return data
        case 401:       throw CalendarProviderError.unauthorized
        case 403:       throw CalendarProviderError.insufficientPermissions
        case 429:       throw CalendarProviderError.rateLimited
        default:        throw CalendarProviderError.networkError("HTTP \(http.statusCode)")
        }
    }
}

// MARK: - Errors

enum CalendarProviderError: LocalizedError {
    case notImplemented
    case unauthorized
    case insufficientPermissions
    case rateLimited
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .notImplemented:          return "This feature is not yet available."
        case .unauthorized:            return "Authentication required. Please reconnect your account."
        case .insufficientPermissions: return "Calendar access was denied. Check Google Account settings."
        case .rateLimited:             return "Too many requests. Please try again in a moment."
        case .networkError(let msg):   return "Network error: \(msg)"
        }
    }
}
