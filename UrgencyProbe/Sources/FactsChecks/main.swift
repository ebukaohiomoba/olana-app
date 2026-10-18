//
//  main.swift
//  FactsChecks
//
//  The facts layer against PRD v3 §3.3 and §3.8, spec v3 §6.1. EventFacts.swift
//  is a symlink into the app, so this checks what ships.
//  Run: swift run FactsChecks
//

import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool, _ got: @autoclosure () -> String = "") {
    print(ok ? "PASS" : "FAIL", name)
    if !ok { failures += 1; print("     got:", got()) }
}
func u(_ s: String) -> URL { URL(string: s)! }

// MARK: Invites (shapes from real Teams, Zoom, Meet and Webex invites)

let teams = """
<html><body><p>Walk through the Q3 numbers before the board meeting.</p>
<p>Deck: <a href="https://nam02.safelinks.protection.outlook.com/?url=https%3A%2F%2Fdocs.google.com%2Fpresentation%2Fd%2Fabc123%2Fedit&data=05%7C01">Q3 deck</a></p>
<div>________________________________________________________________________________</div>
<div><b>Microsoft Teams meeting</b></div>
<div>Join on your computer, mobile app or room device</div>
<div><a href="https://teams.microsoft.com/l/meetup-join/19%3ameeting_ZmE3%40thread.v2/0?context=%7b%22Tid%22%7d">Click here to join the meeting</a></div>
<div>Meeting ID: 245 112 893 012</div>
<div>Passcode: aB3dE9</div>
<div>Download Teams | Join on the web</div>
<div>Or call in (audio only)</div>
<div>+1 646-555-0134,,123456789#   United States, New York City</div>
<div>Phone Conference ID: 123 456 789#</div>
<div>Find a local number | Reset PIN</div>
<div>Learn More | Meeting options</div>
<div>________________________________________________________________________________</div>
</body></html>
"""
let t = NotesCleaner.clean(notes: teams)
check("teams: meeting link found and is Teams",
      t.meetingService == .teams && t.meetingURL?.host == "teams.microsoft.com", "\(String(describing: t.meetingURL))")
check("teams: Safe Links unwrapped to the real deck", t.links.map(\.host) == ["docs.google.com"], "\(t.links)")
check("teams: deck labeled Google Slides", t.links.first?.domainLabel == "Google Slides")
check("teams: dial-in kept apart, not in the text",
      t.dialIn.count == 1 && t.dialIn[0].hasPrefix("+1 646-555-0134") && !t.cleanedNotes.contains("646"), "\(t.dialIn) | \(t.cleanedNotes)")
check("teams: the meeting block is gone",
      !t.cleanedNotes.localizedCaseInsensitiveContains("meeting id") && !t.cleanedNotes.contains("Passcode")
        && !t.cleanedNotes.contains("____") && !t.cleanedNotes.contains("Reset PIN"), t.cleanedNotes)
check("teams: the real line survives and counts as real notes",
      t.cleanedNotes.hasPrefix("Walk through the Q3 numbers") && t.hasRealNotes, t.cleanedNotes)
check("teams: links are numbered L1…", t.links.first?.id == "L1")

let zoom = """
Hi all,

Agenda: review the onboarding funnel and pick two experiments.

Join Zoom Meeting
https://us02web.zoom.us/j/81234567890?pwd=QWErty123

Meeting ID: 812 3456 7890
Passcode: 445566
One tap mobile
+16465588656,,81234567890#,,,,*445566# US (New York)
+13017158592,,81234567890#,,,,*445566# US (Washington DC)

Dial by your location
        +1 646 558 8656 US (New York)
Find your local number: https://us02web.zoom.us/u/kdYz1
"""
let z = NotesCleaner.clean(notes: zoom)
check("zoom: join link found", z.meetingService == .zoom && z.meetingURL?.path == "/j/81234567890", "\(String(describing: z.meetingURL))")
check("zoom: the local-number page is not a material", z.links.isEmpty, "\(z.links)")
check("zoom: three dial-ins captured", z.dialIn.count == 3, "\(z.dialIn)")
check("zoom: agenda kept, greeting and block gone",
      z.cleanedNotes == "Hi all,\n\nAgenda: review the onboarding funnel and pick two experiments.", z.cleanedNotes)
check("zoom: agenda is real content", z.hasRealNotes)

let meet = """
Join with Google Meet: https://meet.google.com/abc-defg-hij
Join by phone
(US) +1 413-555-0199 PIN: 284 555 712#
More phone numbers: https://tel.meet/abc-defg-hij?pin=2845557121234
Learn more about Meet at: https://support.google.com/a/users/answer/9282720

Invitation from Google Calendar: https://calendar.google.com/calendar/
You are receiving this email because you are an attendee on the event.
"""
let m = NotesCleaner.clean(notes: meet)
check("meet: join link found", m.meetingService == .meet && m.meetingURL == u("https://meet.google.com/abc-defg-hij"))
check("meet: no dial-in or help page in materials",
      !m.links.contains { $0.host.contains("tel.meet") || $0.host.contains("support.google") }, "\(m.links)")

let webex = """
Quarterly vendor review.
Join from the meeting link
https://acme.webex.com/acme/j.php?MTID=m1234567890abcdef
Join by meeting number
Meeting number (access code): 2345 678 9012
Meeting password: Vendor2026
Tap to join from a mobile device (attendees only)
+1-415-655-0001,,23456789012## US Toll
"""
let w = NotesCleaner.clean(notes: webex)
check("webex: join link found", w.meetingService == .webex, "\(String(describing: w.meetingURL))")
check("webex: password and access code removed",
      !w.cleanedNotes.contains("Vendor2026") && !w.cleanedNotes.contains("2345"), w.cleanedNotes)

// MARK: Precedence and sources

let conf = u("https://meet.google.com/zzz-yyyy-xxx")
check("conferenceData wins over a notes link",
      NotesCleaner.clean(notes: zoom, conferenceURL: conf).meetingURL == conf)
check("a meeting link in the location field counts",
      NotesCleaner.clean(notes: "Bring the forms.", location: "https://zoom.us/j/555123123").meetingService == .zoom)
check("no notes: empty facts", NotesCleaner.clean(notes: nil) == .empty)

// MARK: Links

let mixed = """
Prep doc https://docs.google.com/document/d/xyz/edit?usp=sharing
Same doc again: https://www.docs.google.com/document/d/xyz/edit?usp=sharing&utm_source=email
Board https://www.figma.com/file/abc/Design?node-id=1
Redirected: https://www.google.com/url?q=https://www.notion.so/team/Plan-123&sa=D
Bad: javascript:alert(1)
Local http://192.168.1.10/admin
"""
let l = NotesCleaner.clean(notes: mixed)
check("links: deduped across www and tracking params, redirect unwrapped, unsafe dropped",
      l.links.map(\.domainLabel) == ["Google Doc", "Figma", "Notion"], "\(l.links.map(\.url))")
check("links: ids are dense after dedupe", l.links.map(\.id) == ["L1", "L2", "L3"])

check("guard: javascript, data and file links rejected",
      URLGuard.validate(u("javascript:alert(1)")) == nil && URLGuard.validate(u("data:text/html,hi")) == nil
        && URLGuard.validate(u("file:///etc/passwd")) == nil)
check("guard: IP literals rejected, v4 and v6",
      URLGuard.validate(u("https://10.0.0.1/x")) == nil && URLGuard.validate(u("https://[::1]/x")) == nil)
check("guard: meeting schemes allowed", URLGuard.validate(u("zoommtg://zoom.us/join?confno=1")) != nil
        && URLGuard.validate(u("msteams://l/meetup-join/x")) != nil)
check("guard: a number-like host with three parts is not an IP literal",
      URLGuard.validate(u("https://123.example.com")) != nil)
check("normalized: host lowercased, www and utm removed",
      URLGuard.normalized(u("https://WWW.Example.com/a?utm_source=x&id=2#frag")) == "https://example.com/a?id=2")
check("meeting: a zoom.us marketing page is not a join link", MeetingLinks.service(of: u("https://zoom.us/pricing")) == nil)
check("meeting: Teams consumer links count", MeetingLinks.service(of: u("https://teams.live.com/meet/9876")) == .teams)

// MARK: Real content (PRD v3 §3.3)

check("content: 'Bring printed agenda' is real", NotesCleaner.hasRealContent("Bring printed agenda"))
check("content: 'See you there' is not", !NotesCleaner.hasRealContent("See you there!"))
check("content: sign-offs and greetings are not", !NotesCleaner.hasRealContent("Hi all,\nThanks,\nBest regards"))
check("content: a bare link is not", !NotesCleaner.hasRealContent("https://docs.google.com/document/d/x"))
check("content: two-word lines are not", !NotesCleaner.hasRealContent("Quick sync\nAgenda TBD"))
check("content: a figure in a sentence stays in the text",
      NotesCleaner.clean(notes: "We need 3 volunteers for the booth").cleanedNotes == "We need 3 volunteers for the booth")
check("content: 'spin: class' is not a PIN line", NotesCleaner.clean(notes: "spin: class with the whole team").hasRealNotes)

// MARK: HTML

check("html: entities decoded, tags removed, blocks become lines",
      NotesCleaner.plainText("<p>Tom &amp; Jerry&nbsp;review</p><p>Bring &lt;laptop&gt;</p>") == "Tom & Jerry review\nBring <laptop>\n",
      NotesCleaner.plainText("<p>Tom &amp; Jerry&nbsp;review</p><p>Bring &lt;laptop&gt;</p>"))
check("html: link targets survive tag removal",
      NotesCleaner.plainText(#"<a href="https://figma.com/file/1">Mockups</a>"#) == "Mockups https://figma.com/file/1")

// MARK: Text guard (PRD v3 §3.8)

let g = TextGuard.filter(["Print the agenda", "Bring 2 copies", "Leave by noon", "Review the deck tomorrow",
                          "Insurance card", "insurance card", "",
                          "A very long item that goes on and on well past the sixty character limit"])
check("guard: digits, time words and long items dropped; duplicates and blanks ignored",
      g.kept == ["Print the agenda", "Insurance card"] && g.dropped.count == 4, "\(g)")
check("guard: words containing a time word inside are fine", TextGuard.passes("Pick up the daycare forms"))
check("guard: 'am' as a word is dropped", !TextGuard.passes("Arrive 7 am"))

// MARK: Synced meeting links (spec v3 §6.1 step 6)

check("google: the video entry point wins over hangoutLink, phone ignored",
      MeetingLinks.googleJoinURL(hangoutLink: "https://meet.google.com/aaa-bbbb-ccc",
                                 entryPoints: [("phone", "tel:+1-555-0100"), ("video", "https://meet.google.com/xyz-abcd-efg")])
        == u("https://meet.google.com/xyz-abcd-efg"))
check("google: hangoutLink when there's no video entry",
      MeetingLinks.googleJoinURL(hangoutLink: "https://meet.google.com/aaa-bbbb-ccc", entryPoints: []) == u("https://meet.google.com/aaa-bbbb-ccc"))
check("google: nothing usable, no link", MeetingLinks.googleJoinURL(hangoutLink: nil, entryPoints: [("phone", "tel:+15550100")]) == nil)
check("eventkit: a Teams join link in the URL field counts",
      MeetingLinks.eventKitJoinURL(u("https://teams.microsoft.com/l/meetup-join/19%3ameeting_x/0")) != nil)
check("eventkit: an ordinary web page in the URL field doesn't",
      MeetingLinks.eventKitJoinURL(u("https://example.com/agenda")) == nil && MeetingLinks.eventKitJoinURL(nil) == nil)

// MARK: Places (PRD v6 §3.4a step 6, §3.14)

import CoreLocation
func place(_ name: String, _ lat: Double, _ lon: Double) -> ResolvedPlace {
    ResolvedPlace(name: name, address: nil, latitude: lat, longitude: lon, phone: nil, website: nil)
}
let soho = CLLocationCoordinate2D(latitude: 40.7233, longitude: -74.0030)          // origin, Manhattan
let smileA = place("Smile Dental", 40.7306, -73.9866)                              // ~1.6 km
let smileB = place("Smile Dental", 40.6782, -73.9442)                              // Brooklyn, ~7 km
let smileFar = place("Smile Dental", 34.0522, -118.2437)                           // Los Angeles
check("places: one match nearby is resolved",
      PlaceMatching.decide(words: "Smile Dental", results: [smileA, smileFar], origin: soho) == .resolved(smileA))
check("places: two within 25 km ask which one, nearest first",
      PlaceMatching.decide(words: "Smile Dental", results: [smileB, smileA, smileFar], origin: soho) == .choose([smileA, smileB]))
check("places: one far match is taken (another city)",
      PlaceMatching.decide(words: "1 Main St, Austin", results: [smileFar], origin: soho) == .resolved(smileFar))
check("places: no results leaves the words", PlaceMatching.decide(words: "Zzyzx", results: [], origin: soho) == .none)
check("places: personal places are never geocoded",
      ["mom's", "my place", "the usual", "Sara's place", "TBD"].allSatisfy {
          PlaceMatching.decide(words: $0, results: [smileA], origin: soho) == .personal })
check("places: 'home' uses the saved home, 'work' the saved work",
      PlaceMatching.decide(words: "home", results: [], origin: soho, home: smileB) == .resolved(smileB)
        && PlaceMatching.decide(words: "work", results: [], origin: soho, work: smileA) == .resolved(smileA))
check("places: 'work' with nothing saved is personal, never searched",
      PlaceMatching.decide(words: "work", results: [smileA], origin: soho) == .personal)
check("places: a business name with 's is not personal", !PlaceMatching.isPersonal("Joe's Pizza on Bleecker")
        && !PlaceMatching.isPersonal("McDonald's Times Square"))
check("places: distance is about right", abs(PlaceMatching.km(soho, smileB.coordinate) - 6.9) < 0.6,
      "\(PlaceMatching.km(soho, smileB.coordinate))")
check("places: no origin, several results is a choice",
      PlaceMatching.decide(words: "Starbucks", results: [smileA, smileB], origin: nil) == .choose([smileA, smileB]))

print(failures == 0 ? "\nAll checks passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
