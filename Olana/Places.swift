//
//  Places.swift
//  Olana
//
//  Place words → a place (PRD v6 §3.4a step 6, §3.14 location sets; v3 §3.7):
//  MapKit search near the origin. One match is resolved; two or more within
//  25 km ask "Which one?"; none leaves the words on the chip with no leave-by.
//  Personal places ("mom's", "my place") are never geocoded, except "home" and
//  "work" when the user has saved them.
//
//  The decision (`PlaceMatching.decide`) is pure and tested in FactsChecks; the
//  MapKit call is a thin wrapper around it.
//

import Foundation
import CoreLocation
#if canImport(MapKit)
import MapKit
#endif

struct ResolvedPlace: Codable, Equatable, Hashable {
    var name: String
    var address: String?
    var latitude: Double
    var longitude: Double
    var phone: String?
    var website: String?

    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

enum PlaceMatch: Equatable {
    case resolved(ResolvedPlace)
    /// Several within 25 km: "Which Smile Dental?". No leave-by until picked.
    case choose([ResolvedPlace])
    /// Personal or unclear: show the words, never geocode.
    case personal
    case none
}

enum PlaceMatching {
    static let nearbyKm = 25.0

    /// "my place", "mom's", "the usual": words that name a place only the user knows.
    static func isPersonal(_ words: String) -> Bool {
        let t = CaptureCode.squash(words)
        let exact: Set<String> = ["home", "my place", "my house", "my apartment", "my apt", "our place", "our house",
                                  "the usual", "the usual place", "tbd", "tba", "work", "the office", "office",
                                  "their place", "his place", "her place"]
        if exact.contains(t) { return true }
        // "mom's", "sara's", "jen's place": a possessive with nothing after, or "place"/"house".
        return t.range(of: #"^[a-z]+'s( (place|house|apartment|apt))?$"#, options: .regularExpression) != nil
    }

    /// Home and work map to the user's saved places when set.
    static func saved(_ words: String, home: ResolvedPlace?, work: ResolvedPlace?) -> ResolvedPlace? {
        switch CaptureCode.squash(words) {
        case "home", "my place", "my house", "my apartment", "my apt": return home
        case "work", "the office", "office": return work
        default: return nil
        }
    }

    /// The pure decision over search results (already ordered by relevance).
    static func decide(words: String, results: [ResolvedPlace], origin: CLLocationCoordinate2D?,
                       home: ResolvedPlace? = nil, work: ResolvedPlace? = nil) -> PlaceMatch {
        if let s = saved(words, home: home, work: work) { return .resolved(s) }
        if isPersonal(words) { return .personal }
        guard !results.isEmpty else { return .none }
        guard let origin else {
            // No origin: one result is the answer; several are a choice.
            return results.count == 1 ? .resolved(results[0]) : .choose(Array(results.prefix(5)))
        }
        let near = results.filter { km(origin, $0.coordinate) <= nearbyKm }
        if near.count == 1 { return .resolved(near[0]) }
        if near.count > 1 { return .choose(Array(near.sorted { km(origin, $0.coordinate) < km(origin, $1.coordinate) }.prefix(5))) }
        // Nothing nearby: a single far match is taken (another city, §3.13);
        // several far matches are a choice.
        return results.count == 1 ? .resolved(results[0]) : .choose(Array(results.prefix(5)))
    }

    /// Great-circle distance in km.
    static func km(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let r = 6371.0, dLat = (b.latitude - a.latitude) * .pi / 180, dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(a.latitude * .pi / 180) * cos(b.latitude * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }
}

// MARK: - Saved places (home, work)

/// Home and work, for "home"/"work" in messages and as origins (v3 §3.7).
/// Local for now; PRD v3 §3.11 puts UserPlaces in CloudKit (launch).
enum SavedPlaces {
    private static let homeKey = "olanaHomePlace_v1", workKey = "olanaWorkPlace_v1"

    static var home: ResolvedPlace? {
        get { load(homeKey) }
        set { save(newValue, homeKey) }
    }
    static var work: ResolvedPlace? {
        get { load(workKey) }
        set { save(newValue, workKey) }
    }

    private static func load(_ key: String) -> ResolvedPlace? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(ResolvedPlace.self, from: $0) }
    }
    private static func save(_ p: ResolvedPlace?, _ key: String) {
        if let p, let d = try? JSONEncoder().encode(p) { UserDefaults.standard.set(d, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }
}

#if canImport(MapKit) && os(iOS)
// MARK: - MapKit

@MainActor
final class PlaceResolver: NSObject, CLLocationManagerDelegate {
    static let shared = PlaceResolver()
    private let manager = CLLocationManager()
    private var authContinuation: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Where to search from: current location if allowed, else saved home.
    /// Asks for location the first time a place needs finding (PRD v3 §1.11 step 6).
    func origin(askIfNeeded: Bool = true) async -> CLLocationCoordinate2D? {
        if manager.authorizationStatus == .notDetermined && askIfNeeded {
            await withCheckedContinuation { c in
                authContinuation = c
                manager.requestWhenInUseAuthorization()
            }
        }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            if let loc = manager.location, -loc.timestamp.timeIntervalSinceNow < 30 * 60 { return loc.coordinate }
            manager.requestLocation()
            return manager.location?.coordinate ?? SavedPlaces.home?.coordinate
        default:
            return SavedPlaces.home?.coordinate
        }
    }

    func resolve(_ words: String) async -> PlaceMatch {
        let home = SavedPlaces.home, work = SavedPlaces.work
        if PlaceMatching.saved(words, home: home, work: work) != nil || PlaceMatching.isPersonal(words) {
            return PlaceMatching.decide(words: words, results: [], origin: nil, home: home, work: work)
        }
        let origin = await origin()
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = words
        request.resultTypes = [.pointOfInterest, .address]
        if let origin {
            request.region = MKCoordinateRegion(center: origin, latitudinalMeters: 50_000, longitudinalMeters: 50_000)
        }
        let items = (try? await MKLocalSearch(request: request).start().mapItems) ?? []
        let results = items.prefix(10).map(Self.place(from:))
        return PlaceMatching.decide(words: words, results: Array(results), origin: origin, home: home, work: work)
    }

    static func place(from item: MKMapItem) -> ResolvedPlace {
        let c = item.location.coordinate
        return ResolvedPlace(name: item.name ?? "Place", address: item.address?.shortAddress ?? item.address?.fullAddress,
                             latitude: c.latitude, longitude: c.longitude,
                             phone: item.phoneNumber, website: item.url.flatMap(URLGuard.validate)?.absoluteString)
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard manager.authorizationStatus != .notDetermined else { return }
            authContinuation?.resume()
            authContinuation = nil
        }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
#endif
