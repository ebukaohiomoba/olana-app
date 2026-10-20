//
//  EventFacts.swift
//  Olana
//
//  The facts layer (PRD v3 §3.3, §3.8; spec v3 §6.1): code finds the meeting
//  link, the other links, dial-ins and whether the notes say anything real.
//  The model never writes a URL; it only labels links by ID (EventAssist).
//
//  Pure: no SwiftData, no network. FactsChecks runs this file directly.
//

import Foundation

// MARK: - Output

struct FactLink: Equatable, Codable, Hashable {
    /// "L1", "L2"… in order of appearance. The model refers to links by this.
    let id: String
    let url: URL
    /// Host after unwrapping, without "www.".
    let host: String
    /// The code-side label used when the model gives none: "Google Slides", "Figma".
    let domainLabel: String
}

enum MeetingService: String, Codable, CaseIterable {
    case zoom, teams, meet, webex

    var name: String {
        switch self {
        case .zoom:  return "Zoom"
        case .teams: return "Teams"
        case .meet:  return "Google Meet"
        case .webex: return "Webex"
        }
    }
}

struct EventFacts: Equatable {
    /// The notes with HTML, meeting blocks and dial-ins removed. Untrusted text.
    var cleanedNotes: String
    var meetingURL: URL?
    var meetingService: MeetingService?
    /// Stored, never shown as a button (PRD v3 §3.8 phone guard).
    var dialIn: [String]
    var links: [FactLink]
    /// At least one line of 3+ words that isn't a URL, a sign-off or boilerplate.
    var hasRealNotes: Bool

    static let empty = EventFacts(cleanedNotes: "", meetingURL: nil, meetingService: nil,
                                  dialIn: [], links: [], hasRealNotes: false)
}

// MARK: - URL guard

enum URLGuard {
    static let webSchemes: Set<String> = ["https", "http"]
    static let meetingSchemes: Set<String> = ["zoommtg", "msteams", "webex"]

    /// The URL if it may be shown or opened, else nil. Rejects other schemes
    /// (javascript:, data:, file:, mailto:…), IP-literal hosts and hostless web links.
    static func validate(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased() else { return nil }
        if meetingSchemes.contains(scheme) { return url }
        guard webSchemes.contains(scheme), let host = url.host?.lowercased(), !host.isEmpty,
              host.contains("."), !isIPLiteral(host) else { return nil }
        return url
    }

    static func isIPLiteral(_ host: String) -> Bool {
        let h = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if h.contains(":") { return true }                       // IPv6
        let parts = h.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }

    /// Outlook Safe Links and Google redirect links, unwrapped (once per layer).
    static func unwrap(_ url: URL) -> URL {
        var current = url
        for _ in 0..<3 {
            guard let host = current.host?.lowercased(),
                  let items = URLComponents(url: current, resolvingAgainstBaseURL: false)?.queryItems else { break }
            let param: String?
            if host.hasSuffix("safelinks.protection.outlook.com") { param = "url" }
            else if (host == "google.com" || host == "www.google.com") && current.path == "/url" { param = "q" }
            else { param = nil }
            guard let param, let value = items.first(where: { $0.name == param })?.value,
                  let inner = URL(string: value) else { break }
            current = inner
        }
        return current
    }

    /// Lowercased host, no "www.", no fragment, tracking parameters removed.
    /// Used to dedupe links and in cache keys.
    static func normalized(_ url: URL) -> String {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        c.host = c.host?.lowercased()
        if let h = c.host, h.hasPrefix("www.") { c.host = String(h.dropFirst(4)) }
        c.fragment = nil
        let tracking: Set<String> = ["fbclid", "gclid", "mc_cid", "mc_eid", "ref", "ref_src"]
        let kept = c.queryItems?.filter { !$0.name.lowercased().hasPrefix("utm_") && !tracking.contains($0.name.lowercased()) }
        c.queryItems = (kept?.isEmpty ?? true) ? nil : kept
        var s = c.string ?? url.absoluteString
        if s.hasSuffix("/") { s.removeLast() }
        return s
    }

    static func displayHost(_ url: URL) -> String {
        let h = url.host?.lowercased() ?? ""
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }
}

// MARK: - Meeting links

enum MeetingLinks {
    /// The service a link joins, from its host and path. Only real join links
    /// count: a zoom.us marketing page is a plain link.
    static func service(of url: URL) -> MeetingService? {
        switch url.scheme?.lowercased() {
        case "zoommtg": return .zoom
        case "msteams": return .teams
        case "webex":   return .webex
        default: break
        }
        let host = URLGuard.displayHost(url), path = url.path.lowercased()
        if host == "zoom.us" || host.hasSuffix(".zoom.us") {
            return path.hasPrefix("/j/") || path.hasPrefix("/my/") || path.hasPrefix("/w/") || path.hasPrefix("/s/") ? .zoom : nil
        }
        if host == "teams.microsoft.com" || host == "teams.live.com" {
            return path.contains("meetup-join") || path.hasPrefix("/meet/") || path.hasPrefix("/l/meet") ? .teams : nil
        }
        if host == "meet.google.com" { return path.count > 1 ? .meet : nil }
        if host.hasSuffix(".webex.com") {
            return path.contains("/j.php") || path.contains("/meet/") || path.contains("/join") || path.contains("/wbxmjs/") ? .webex : nil
        }
        return nil
    }
}

extension MeetingLinks {
    /// Google's join link: the conferenceData video entry point, else
    /// hangoutLink. Phone and SIP entries are never the join link.
    static func googleJoinURL(hangoutLink: String?, entryPoints: [(type: String?, uri: String?)]) -> URL? {
        let video = entryPoints.first { $0.type == "video" }?.uri
        return [video, hangoutLink].compactMap { $0 }.compactMap(URL.init(string:)).compactMap(URLGuard.validate).first
    }

    /// EventKit's URL field holds a join link for many Teams and Zoom invites;
    /// only a real join link counts.
    static func eventKitJoinURL(_ url: URL?) -> URL? {
        guard let url = url.map(URLGuard.unwrap).flatMap(URLGuard.validate), service(of: url) != nil else { return nil }
        return url
    }
}

// MARK: - Notes cleaner

enum NotesCleaner {

    /// Lines that belong to a meeting block, matched case-insensitively (a
    /// lookup table of known formats, extended from the M0 invite corpus).
    static let meetingMarkers = [
        // Teams
        "microsoft teams meeting", "join on your computer", "join the meeting now", "click here to join",
        "meeting id:", "meeting id :", "passcode:", "phone conference id", "call in (audio only)",
        "find a local number", "reset pin", "meeting options", "for organizers:", "join with a video conferencing device",
        "video conferencing device", "video conference id", "alternate vtc instructions", "or call in",
        "learn more about teams", "need help?", "download teams", "join on the web",
        // Zoom
        "join zoom meeting", "zoom meeting", "one tap mobile", "dial by your location", "find your local number",
        "join by sip", "join by h.323", "meeting password", "password:",
        // Meet
        "join with google meet", "join by phone", "more phone numbers", "learn more about meet", "pin:",
        // Webex
        "webex meeting", "join by video system", "join by phone", "access code", "attendee id", "join from the webex app",
        "tap to join from a mobile device", "can't join the meeting?",
    ]

    /// Lines that aren't real content even though they have words.
    static let genericLines: [String] = [
        "see you there", "see you then", "looking forward", "talk soon", "thanks", "thank you", "best",
        "regards", "best regards", "kind regards", "cheers", "hi all", "hi everyone", "hello all", "hello everyone",
        "please join", "please see below", "agenda to follow", "details to follow", "this is an invitation",
        "you have been invited", "invitation from google calendar", "reply for", "view all guest info",
        "forwarding this invitation", "learn more", "sent from my iphone", "do not reply",
    ]

    static func clean(notes: String?, location: String? = nil, conferenceURL: URL? = nil) -> EventFacts {
        let text = plainText(notes ?? "")
        var meeting: URL?
        var dialIn: [String] = []
        var kept: [String] = []

        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            if line.isEmpty { kept.append(""); continue }
            if isRule(line) { continue }

            let urls = detectURLs(in: line).map(URLGuard.unwrap)
            if let m = urls.first(where: { MeetingLinks.service(of: $0) != nil }) {
                if meeting == nil { meeting = URLGuard.validate(m) }
                // A line that is only the link (or a marker plus the link) goes.
                if lineIsMostlyLinks(line) || isMarker(lower) { continue }
            }
            if isMarker(lower) { continue }
            if let phone = dialInNumber(line) { dialIn.append(phone); continue }
            kept.append(line)
        }

        let cleaned = collapse(kept)

        // Links over what's left; a meeting link found here still counts as one.
        var links: [FactLink] = []
        var seen = Set<String>()
        for url in detectURLs(in: cleaned).map(URLGuard.unwrap) {
            guard let valid = URLGuard.validate(url) else { continue }
            if MeetingLinks.service(of: valid) != nil {
                if meeting == nil { meeting = valid }
                continue
            }
            let key = URLGuard.normalized(valid)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            links.append(FactLink(id: "L\(links.count + 1)", url: valid,
                                  host: URLGuard.displayHost(valid), domainLabel: domainLabel(valid)))
        }
        if let meetingURL = meeting { links.removeAll { URLGuard.normalized($0.url) == URLGuard.normalized(meetingURL) } }

        // A link in the location field ("https://zoom.us/j/…") is a meeting link too.
        if meeting == nil, let loc = location {
            meeting = detectURLs(in: loc).map(URLGuard.unwrap).compactMap(URLGuard.validate)
                .first { MeetingLinks.service(of: $0) != nil }
        }
        // Google conferenceData wins over a notes-derived link (spec §6.1 step 6).
        if let conf = conferenceURL.flatMap(URLGuard.validate) { meeting = conf }

        return EventFacts(cleanedNotes: cleaned, meetingURL: meeting,
                          meetingService: meeting.flatMap(MeetingLinks.service(of:)),
                          dialIn: dialIn, links: links, hasRealNotes: hasRealContent(cleaned))
    }

    // MARK: Pieces (internal for tests)

    /// HTML to plain text. Block tags become line breaks; entities decoded.
    static func plainText(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\r\n", with: "\n")
        // Keep hrefs: <a href="X">label</a> → "label X" so links survive.
        t = t.replacingOccurrences(of: #"<a\s[^>]*href\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a>"#,
                                   with: "$2 $1", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"<\s*(br|/p|/div|/li|/tr|/h[1-6])\s*/?>"#, with: "\n",
                                   options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"<\s*li[^>]*>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"<style[^>]*>.*?</style>"#, with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                        "&#39;": "'", "&apos;": "'", "&#160;": " "]
        for (k, v) in entities { t = t.replacingOccurrences(of: k, with: v, options: .caseInsensitive) }
        t = t.replacingOccurrences(of: "\u{00A0}", with: " ")
        return t
    }

    static func isMarker(_ lower: String) -> Bool {
        // Short markers ("pin:") only at the start of a line, so "spin: class" stays.
        meetingMarkers.contains { $0.count <= 5 ? lower.hasPrefix($0) : lower.contains($0) }
    }

    /// Underscore, dash or box-drawing rules ("________", "-----").
    static func isRule(_ line: String) -> Bool {
        line.count >= 5 && line.allSatisfy { "_-=─━—·*~".contains($0) }
    }

    static func lineIsMostlyLinks(_ line: String) -> Bool {
        var rest = line
        for u in detectURLs(in: line) { rest = rest.replacingOccurrences(of: u.absoluteString, with: "") }
        rest = rest.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
        return rest.split(whereSeparator: { !$0.isLetter }).count <= 3
    }

    /// A dial-in line: a phone number, optionally with an ID or "#,,". Returns the number.
    static func dialInNumber(_ line: String) -> String? {
        guard let r = line.range(of: #"(\+?\d[\d \-().]{6,}\d)(,,[\d#*,]+)?"#, options: .regularExpression) else { return nil }
        let digits = line[r].filter(\.isNumber).count
        guard digits >= 8 else { return nil }
        let number = String(line[r]).trimmingCharacters(in: .whitespaces)
        // A dial string (",," or "#") is a dial-in whatever follows it ("United
        // States, New York City"). Otherwise the number must be most of the line,
        // so a sentence with a figure in it stays.
        if number.contains(",,") || line[r.upperBound...].hasPrefix("#") || number.hasSuffix("#") { return number }
        let words = line.replacingCharacters(in: r, with: "").split(whereSeparator: { !$0.isLetter }).count
        return words <= 4 ? number : nil
    }

    static func detectURLs(in s: String) -> [URL] {
        guard !s.isEmpty, let d = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        return d.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap(\.url)
            .filter { $0.scheme?.lowercased() != "mailto" && $0.scheme?.lowercased() != "tel" }
    }

    static func collapse(_ lines: [String]) -> String {
        var out: [String] = []
        for l in lines where !(l.isEmpty && (out.last?.isEmpty ?? true)) { out.append(l) }
        while out.last?.isEmpty == true { out.removeLast() }
        return out.joined(separator: "\n")
    }

    /// PRD v3 §3.3 content test: a line of 3+ words that isn't a URL, a sign-off,
    /// boilerplate or a generic phrase.
    static func hasRealContent(_ cleaned: String) -> Bool {
        for raw in cleaned.components(separatedBy: "\n") {
            var line = raw
            for u in detectURLs(in: raw) { line = line.replacingOccurrences(of: u.absoluteString, with: "") }
            let lower = line.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            let words = lower.split(whereSeparator: { !$0.isLetter && $0 != "'" }).filter { !$0.isEmpty }
            guard words.count >= 3 else { continue }
            if genericLines.contains(where: { lower == $0 || lower.hasPrefix($0 + " ") && words.count <= 5 }) { continue }
            if isMarker(lower) { continue }
            return true
        }
        return false
    }

    /// Code-side link labels by domain (the fallback when the model labels nothing).
    static func domainLabel(_ url: URL) -> String {
        let host = URLGuard.displayHost(url), path = url.path.lowercased()
        switch true {
        case host == "docs.google.com" && path.hasPrefix("/document"):     return "Google Doc"
        case host == "docs.google.com" && path.hasPrefix("/spreadsheets"): return "Google Sheet"
        case host == "docs.google.com" && path.hasPrefix("/presentation"): return "Google Slides"
        case host == "docs.google.com" && path.hasPrefix("/forms"):        return "Google Form"
        case host == "drive.google.com":                                    return "Google Drive"
        case host.hasSuffix("sharepoint.com"):                              return "SharePoint"
        case host.hasSuffix("onedrive.live.com") || host == "1drv.ms":      return "OneDrive"
        case host.hasSuffix("notion.so") || host.hasSuffix("notion.site"):  return "Notion"
        case host.hasSuffix("figma.com"):                                   return "Figma"
        case host.hasSuffix("github.com"):                                  return "GitHub"
        case host.hasSuffix("dropbox.com"):                                 return "Dropbox"
        case host.hasSuffix("loom.com"):                                    return "Loom"
        case host.hasSuffix("atlassian.net"):                               return path.contains("/wiki") ? "Confluence" : "Jira"
        case host.hasSuffix("miro.com"):                                    return "Miro"
        case host.hasSuffix("canva.com"):                                   return "Canva"
        case host.hasSuffix("airtable.com"):                                return "Airtable"
        case host.hasSuffix("calendly.com"):                                return "Calendly"
        default:                                                            return host
        }
    }
}

// MARK: - Trust guard on model text (PRD v3 §3.8)

enum TextGuard {
    static let timeWords: Set<String> = ["noon", "midnight", "minute", "minutes", "min", "mins", "hour", "hours",
                                         "hr", "hrs", "half", "quarter", "am", "pm", "a.m", "p.m", "morning",
                                         "tonight", "tomorrow", "today", "o'clock", "oclock", "yesterday",
                                         "afternoon", "evening", "week", "weeks", "day", "days"]
    static let maxLength = 60

    struct Result: Equatable { var kept: [String]; var dropped: [String] }

    /// Model-written steps and bring items: drop any with a digit, a time word,
    /// or over 60 characters. Item by item; the rest still show. With `source`
    /// (the invite or message), a number or time word copied from it may stay
    /// ("Read chapter 4", "Fast for 12 hours"); one the model made up never does.
    static func filter(_ items: [String], source: String? = nil) -> Result {
        var r = Result(kept: [], dropped: [])
        var seen = Set<String>()
        for raw in items {
            let item = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !item.isEmpty else { continue }
            let key = item.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            if passes(item, source: source) { r.kept.append(item) } else { r.dropped.append(item) }
        }
        return r
    }

    static func passes(_ item: String, source: String? = nil) -> Bool {
        guard item.count <= maxLength else { return false }
        let copied = source.map(tokens) ?? []
        let words = tokens(item)
        // Numbers and time words only when the same token is in the source.
        if words.contains(where: { $0.contains(where: \.isNumber) && !copied.contains($0) }) { return false }
        return !words.contains { timeWords.contains($0) && !copied.contains($0) }
    }

    /// Lowercased word tokens, plurals folded ("cards" → "card", "w-2s" → "w-2"),
    /// so the same thing matches however it was written.
    static func tokens(_ text: String) -> Set<String> {
        Set(text.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == "'") })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-'")) }
            .filter { !$0.isEmpty }
            .map(singular))
    }

    static func singular(_ w: String) -> String {
        guard w.count > 3, w.hasSuffix("s"), !w.hasSuffix("ss"), !timeWords.contains(w) else { return w }
        return String(w.dropLast())
    }
}
