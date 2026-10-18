//
//  Logistics.swift
//  Spikes
//
//  Spike-only schema for the "model names it, code sets the numbers" idea:
//  the model says what kind of thing an event is and where it happens; prep
//  leads, effort and buffers come from a table in code. Nothing here ships.
//

import FoundationModels

@Generable
enum EventKind: String, CaseIterable {
    case exam, performance, presentation, deliverable, hosting, interview, procedure
    case paperwork, meeting, appointment, `class`, workout, social, trip, errand, task, marker
}

@Generable
enum LogisticsAttendance: String, CaseIterable {
    case inPerson, virtual, none
}

@Generable
struct EventLogisticsV1 {
    @Guide(description: "What the person is actually doing at this event.")
    var kind: EventKind
    @Guide(description: "True ONLY if the text names a specific place, usually after \"at\", \"in\" or \"from\". False for titles like Dentist, Gym or Team meeting.")
    var namesPlace: Bool
    @Guide(description: "When namesPlace is true, that place copied word for word. Otherwise empty.")
    var place: String
    @Guide(description: "inPerson if they must be somewhere physically, virtual if it happens on a video or phone call, none if it is not something they attend.")
    var attendance: LogisticsAttendance
    @Guide(description: "True ONLY if the title itself names something to bring, review, send or finish before the event.")
    var cue: Bool
}

enum LogisticsPrompt {
    static let instructions = """
    You read calendar event titles for a planning app. You get a short title and sometimes the
    name of the calendar it came from. Answer only from what the title says.

    KIND — what the person is actually doing.
      exam          a test they take. Bar exam, Chemistry midterm, Citizenship test.
      performance   they compete or perform. 10K race, Dance recital, Chess tournament.
      presentation  they present or speak to others. Sales demo, Keynote, Wedding toast.
      deliverable   work they produce that is due. Essay due, Budget draft due, Lab report.
      hosting       they host people. Hosting brunch, Throwing a baby shower.
      interview     they are interviewed. Phone screen, Panel interview, Embassy interview.
      procedure     a medical visit that needs prep such as fasting. Endoscopy, Surgery, MRI with contrast.
      paperwork     forms or filings. Lease renewal forms, FAFSA, Expense claim.
      meeting       a work or school meeting, including any 1:1. Staff meeting, Design sync, Retro,
                    Weekly 1:1 with Priya, Skip-level.
      appointment   a visit to a professional. Eye exam, Vet visit, Barber, Bank appointment.
      class         a class, lecture or course. Chemistry lecture, Pottery class, Online course.
      workout       exercise or practice. Pilates, Swim practice, Evening jog.
      social        time with friends or family, including calling them or watching them.
                    Brunch with Ana, Game night, Wedding, Call grandma, Leo's basketball game.
      trip          travel itself. Flight to Austin, Bus to Philly, Check out of hotel.
      errand        a quick out-and-back. Grocery run, Return package, Pick up kids.
      task          a to-do that is itself the work. Clean the garage, Pack for camping, Repaint bedroom.
      marker        nothing to do or attend; it just marks the day. Holiday, Rent posts, Out of office,
                    Remote day.

    NAMESPLACE and PLACE — a place is anywhere you could look up on a map: a business, a venue,
      an address, a room, or a generic spot like the bank, the airport, the post office or a
      school. "Brunch at Tartine" names Tartine. "Renew passport at the post office" names the
      post office. "Dentist", "Gym", "Team meeting" and "Coffee with Sam" name no place:
      namesPlace is false and place is empty. Never copy the title or the activity as the place,
      and never add a place the text does not contain. A city you travel TO on a flight, train or
      bus is not the place; the departure point is, if the text names one.

    ATTENDANCE — inPerson, virtual, or none.
      virtual   any call or video: Zoom, Teams, Meet, FaceTime, webinar, phone, "call Ana",
                "ring grandpa". Calling someone is always virtual.
      none      things that are not attended, like deadlines, tasks and markers.

    CUE — true only when the title itself says to bring, review, send, read or finish
      something first. "Staff meeting" is false. "Staff meeting, bring Q3 numbers" is true.
    """

    static func prompt(title: String, calendarName: String?) -> String {
        if let calendarName { return "Title: \(title)\nCalendar: \(calendarName)" }
        return "Title: \(title)"
    }

    /// Travel is code's call: in person, a kind you go out for, and an in-person
    /// meeting only when it names a place (otherwise assume the office you're at).
    /// In-person presentations travel: a talk is usually somewhere else.
    static func needsTravel(_ l: EventLogisticsV1) -> Bool {
        guard l.attendance == .inPerson else { return false }
        switch l.kind {
        case .hosting, .task, .marker, .deliverable, .paperwork: return false
        case .meeting: return l.namesPlace
        default: return true
        }
    }

    /// The place, only if the model named one and it is really in the text. Small
    /// models copy places out of their own prompt examples; this drops those.
    static func place(_ l: EventLogisticsV1, in text: String) -> String {
        let p = l.place.trimmingCharacters(in: .whitespacesAndNewlines)
        guard l.namesPlace, !p.isEmpty, text.range(of: p, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        else { return "" }
        return p
    }

    /// The code-side table: which kinds get prep at all.
    static let prepKinds: Set<EventKind> = [.exam, .performance, .presentation, .deliverable,
                                            .hosting, .interview, .procedure, .paperwork, .trip]
}
