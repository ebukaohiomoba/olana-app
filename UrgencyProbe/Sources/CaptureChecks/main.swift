//
//  main.swift
//  CaptureChecks
//
//  Capture parse (PRD v6 §1.7a, §3.4a). Capture.swift and EventFacts.swift are
//  symlinks into the app, so this checks what ships.
//
//  swift run CaptureChecks                  code checks (no model)
//  swift run CaptureChecks model capture.txt  the shipping prompt on a labeled set
//

import Foundation
import FoundationModels

var failures = 0
func check(_ name: String, _ ok: Bool, _ got: @autoclosure () -> String = "") {
    print(ok ? "PASS" : "FAIL", name)
    if !ok { failures += 1; print("     got:", got()) }
}

let args = CommandLine.arguments

if args.count >= 3 && args[1] == "model" {
    // MARK: - Model run
    // Format: message | place ("-" none, "/" alternatives) | items (";", "-" none) |
    //         arrive-early minutes ("-" none) | attendance (inPerson virtual unsure, "?" skip) | travel (yes no ?) | group
    guard case .available = SystemLanguageModel.default.availability else { print("Apple Intelligence unavailable"); exit(1) }
    let rows = try String(contentsOfFile: args[2], encoding: .utf8).split(separator: "\n").compactMap { line -> [String]? in
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !t.hasPrefix("#") else { return nil }
        let r = t.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        return r.count >= 7 ? r : nil
    }
    func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "-" : "\(a * 100 / b)%" }
    func pad(_ s: String, _ n: Int) -> String { s.count >= n ? String(s.prefix(n - 1)) + " " : s + String(repeating: " ", count: n - s.count) }
    func norm(_ s: String) -> String { CaptureCode.squash(s).replacingOccurrences(of: #"^(the|my) "#, with: "", options: .regularExpression) }
    struct T { var n = 0, fails = 0, place = 0, noPlaceN = 0, noPlaceOK = 0, placeN = 0, placeOK = 0
               var items = 0, itemsN = 0, invented = 0, early = 0, earlyN = 0, att = 0, attN = 0, travel = 0, travelN = 0 }
    var tallies: [String: T] = [:]
    print(pad("MESSAGE", 58) + pad("PLACE", 22) + pad("ITEMS", 32) + pad("EARLY", 6) + pad("ATT", 10) + pad("TRV", 5) + "WRONG")
    for r in rows {
        let message = r[0], group = r[6]
        var t = tallies[group] ?? T(); t.n += 1
        let out = await CaptureParser.parse(message)
        guard let out else { t.fails += 1; tallies[group] = t; print(message, "FAIL"); continue }
        let res = CaptureCode.combine(message: message, title: message, model: out)
        var wrong: [String] = []

        let wantPlace = r[1].split(separator: "/").map { norm(String($0)) }
        let gotPlace = norm(res.placeText ?? "")
        if r[1] == "-" {
            t.noPlaceN += 1
            if gotPlace.isEmpty { t.noPlaceOK += 1; t.place += 1 } else { wrong.append("invented place") }
        } else {
            t.placeN += 1
            if wantPlace.contains(gotPlace) { t.placeOK += 1; t.place += 1 } else { wrong.append("place") }
        }

        let wantItems = r[2] == "-" ? [] : r[2].split(separator: ";").map { norm(String($0)) }
        let gotItems = res.items.map { norm($0.text) }
        for w in wantItems {
            t.itemsN += 1
            if gotItems.contains(where: { $0 == w || $0.contains(w) || w.contains($0) }) { t.items += 1 } else { wrong.append("missed item \(w)") }
        }
        let extra = gotItems.filter { g in !wantItems.contains { $0 == g || $0.contains(g) || g.contains($0) } }
        if !extra.isEmpty { t.invented += extra.count; wrong.append("extra item \(extra.joined(separator: ","))") }

        if r[3] != "?" {
            t.earlyN += 1
            let want = r[3] == "-" ? nil : Int(r[3])
            if res.arriveEarlyMinutes == want { t.early += 1 } else { wrong.append("early") }
        }
        if r[4] != "?" {
            t.attN += 1
            if res.attendance?.rawValue == r[4] { t.att += 1 } else { wrong.append("att") }
        }
        if r[5] != "?" {
            t.travelN += 1
            if (res.likelyNeedsTravel ? "yes" : "no") == r[5] { t.travel += 1 } else { wrong.append("travel") }
        }
        tallies[group] = t
        let early = res.arriveEarlyMinutes.map(String.init) ?? "-"
        print(pad(message, 58) + pad(res.placeText ?? "-", 22) + pad(res.items.map { ($0.isBring ? "bring:" : "do:") + $0.text }.joined(separator: "; "), 32)
              + pad(early, 6) + pad(res.attendance?.rawValue ?? "-", 10) + pad(res.likelyNeedsTravel ? "yes" : "no", 5) + wrong.joined(separator: ", "))
        if !res.dropped.isEmpty { print("     dropped by code:", res.dropped.joined(separator: "; ")) }
        if !wrong.isEmpty { print("     model said:", out) }
    }
    print("\n" + pad("GROUP", 7) + pad("N", 4) + pad("NO PLACE OK", 13) + pad("PLACE OK", 10) + pad("ITEMS", 8) + pad("EXTRA", 7) + pad("EARLY", 8) + pad("ATTEND", 8) + pad("TRAVEL", 8) + "FAILS")
    func row(_ g: String, _ t: T) -> String {
        pad(g, 7) + pad("\(t.n)", 4) + pad(pct(t.noPlaceOK, t.noPlaceN), 13) + pad(pct(t.placeOK, t.placeN), 10) + pad(pct(t.items, t.itemsN), 8)
            + pad("\(t.invented)", 7) + pad(pct(t.early, t.earlyN), 8) + pad(pct(t.att, t.attN), 8) + pad(pct(t.travel, t.travelN), 8) + "\(t.fails)"
    }
    var a = T()
    for g in tallies.keys.sorted() {
        let t = tallies[g]!
        a.n += t.n; a.fails += t.fails; a.noPlaceN += t.noPlaceN; a.noPlaceOK += t.noPlaceOK; a.placeN += t.placeN; a.placeOK += t.placeOK
        a.items += t.items; a.itemsN += t.itemsN; a.invented += t.invented; a.early += t.early; a.earlyN += t.earlyN
        a.att += t.att; a.attN += t.attN; a.travel += t.travel; a.travelN += t.travelN
        print(row(g, t))
    }
    print(row("ALL", a))
    print("Bars (PRD v6 §3.14): no place returned ≥ 98% · place words ≥ 90% · items found ≥ 90% · none invented ≥ 98%")
    exit(0)
}

// MARK: - Code checks

let m1 = "Dentist tomorrow 3pm at Smile Dental, bring insurance card, be there 10 min early"
let r1 = CaptureCode.combine(message: m1, title: "Dentist at Smile Dental, bring insurance card, be there 10 min early",
                             model: CaptureModelOutput(placeText: "Smile Dental", prepItems: ["insurance card"],
                                                       arriveEarlyText: "10 min early", arriveEarlyBucket: .quarter,
                                                       attendance: .inPerson, likelyNeedsTravel: true))
check("scenario 30: place, bring and arrive-early all read",
      r1.placeText == "Smile Dental" && r1.bring == ["Insurance card"] && r1.arriveEarlyMinutes == 10 && r1.likelyNeedsTravel, "\(r1)")
check("scenario 30: a number in the words beats the bucket", r1.arriveEarlyMinutes == 10)
let t1 = CaptureCode.title("Dentist at Smile Dental, bring insurance card, be there 10 min early",
                           removing: CaptureCode.chipPhrases(r1, message: m1))
check("scenario 30: title is just 'Dentist'", t1 == "Dentist", t1)
let t1b = CaptureCode.title("Dentist at Smile Dental, bring insurance card, be there 10 min early",
                            removing: ["Smile Dental", "10 min early"])
check("scenario 31: removing the 🎒 chip puts its words back in the title", t1b == "Dentist, bring insurance card", t1b)

let invented = CaptureCode.combine(message: "dentist 3pm", title: "Dentist",
                                   model: CaptureModelOutput(placeText: "Bright Smiles Dental", attendance: .inPerson, likelyNeedsTravel: true))
check("substring check: a place not in the message is dropped and logged",
      invented.placeText == nil && invented.dropped == ["place: Bright Smiles Dental"], "\(invented)")
let copied = CaptureCode.combine(message: "gym 6pm", title: "Gym", model: CaptureModelOutput(placeText: "gym"))
check("the activity copied as the place is dropped", copied.placeText == nil && !copied.dropped.isEmpty, "\(copied)")
let timePlace = CaptureCode.combine(message: "call with Sam at 4", title: "Call with Sam", model: CaptureModelOutput(placeText: "4"))
check("a time is never a place", timePlace.placeText == nil, "\(timePlace)")
check("time phrases recognized", CaptureCode.isTimePhrase("at 3") && CaptureCode.isTimePhrase("noon") && CaptureCode.isTimePhrase("10:30 pm")
        && !CaptureCode.isTimePhrase("Room 4B"))

let zoomMsg = "Interview Thursday 10am https://us02web.zoom.us/j/8123456789 review my portfolio first"
let rz = CaptureCode.combine(message: zoomMsg, title: zoomMsg,
                             model: CaptureModelOutput(prepItems: ["review my portfolio"], attendance: .inPerson, likelyNeedsTravel: true))
check("scenario 29: a meeting link makes it virtual, the model can't override, no travel",
      rz.meetingService == .zoom && rz.attendance == .virtual && !rz.likelyNeedsTravel, "\(rz)")
check("a 'do' item is a prep step, not a bring item", rz.steps == ["Review my portfolio"] && rz.bring.isEmpty, "\(rz.items)")
let tz = CaptureCode.title("Interview https://us02web.zoom.us/j/8123456789 review my portfolio first", removing: CaptureCode.chipPhrases(rz, message: zoomMsg))
check("the link and the step leave the title", tz == "Interview first" || tz == "Interview", tz)

let addr = "pick up keys 22 Oak Ave, Springfield, IL 62704 at 5pm"
let ra = CaptureCode.combine(message: addr, title: "Pick up keys", model: nil)
check("street address found by the detector, model not needed",
      ra.placeIsStreetAddress && (ra.placeText?.contains("22 Oak Ave") ?? false) && ra.attendance == .inPerson, "\(ra)")

let flight = CaptureCode.combine(message: "flight fri 7:30am JFK T4 2 hrs early bring passport", title: "Flight JFK T4",
                                 model: CaptureModelOutput(placeText: "JFK T4", prepItems: ["passport"], arriveEarlyText: "2 hrs early",
                                                           arriveEarlyBucket: .airport, attendance: .inPerson, likelyNeedsTravel: true))
check("several at once: place, early (120) and bring", flight.placeText == "JFK T4" && flight.arriveEarlyMinutes == 120
        && flight.bring == ["Passport"], "\(flight)")
let flightBucket = CaptureCode.combine(message: "flight to Austin friday", title: "Flight to Austin",
                                       model: CaptureModelOutput(arriveEarlyBucket: .airport, attendance: .inPerson, likelyNeedsTravel: true))
check("flight with no words: airport bucket gives 120", flightBucket.arriveEarlyMinutes == 120)
let vague = CaptureCode.combine(message: "party at Jo's, get there early", title: "Party",
                                model: CaptureModelOutput(placeText: "Jo's", arriveEarlyText: "get there early", arriveEarlyBucket: .quarter))
check("no number: the bucket decides", vague.arriveEarlyMinutes == 15, "\(vague)")
let wrongEarly = CaptureCode.combine(message: "lunch at noon", title: "Lunch",
                                     model: CaptureModelOutput(arriveEarlyText: "15 minutes early", arriveEarlyBucket: .quarter))
check("arrive-early words not in the message are dropped", wrongEarly.arriveEarlyMinutes == nil && wrongEarly.dropped.count == 1)

check("minutes: '15 min early'", CaptureCode.minutes(fromArriveEarly: "15 min early") == 15)
check("minutes: 'half an hour early'", CaptureCode.minutes(fromArriveEarly: "half an hour early") == 30)
check("minutes: 'an hour early'", CaptureCode.minutes(fromArriveEarly: "an hour early") == 60)
check("minutes: 'two hours early'", CaptureCode.minutes(fromArriveEarly: "two hours early") == 120)
check("minutes: '1.5 hrs'", CaptureCode.minutes(fromArriveEarly: "1.5 hrs before") == 90)
check("minutes: capped at 180", CaptureCode.minutes(fromArriveEarly: "5 hours early") == 180)
check("minutes: no number → nil", CaptureCode.minutes(fromArriveEarly: "get there early") == nil)

let multi = CaptureCode.combine(message: "interview thu 10, bring 2 copies of resume and review the job post", title: "Interview",
                                model: CaptureModelOutput(prepItems: ["2 copies of resume", "review the job post", "made up item"]))
check("items: bring vs do, user digits kept, invented item dropped",
      multi.bring == ["2 copies of resume"] && multi.steps == ["Review the job post"] && multi.dropped == ["item: made up item"], "\(multi)")
check("items: duplicates collapse", CaptureCode.combine(message: "bring ID", title: "x",
      model: CaptureModelOutput(prepItems: ["ID", "id"])).items.count == 1)

let refused = CaptureCode.combine(message: "court date monday 9am", title: "Court date", model: nil)
check("scenario 26: model refused → saves as today, nothing invented",
      refused.placeText == nil && refused.items.isEmpty && !refused.modelRan, "\(refused)")

check("squash: case, curly quotes and spaces", CaptureCode.appears("mom’s  place", in: "Dinner at Mom's place"))
check("title: 'at' before the place is removed with it", CaptureCode.title("Gym at Equinox Flatiron", removing: ["Equinox Flatiron"]) == "Gym")
check("title: nothing to remove keeps the title", CaptureCode.title("Team standup", removing: []) == "Team standup")
check("title: never empty", CaptureCode.title("Smile Dental", removing: ["Smile Dental"]) == "Smile Dental")

let activity = CaptureCode.combine(message: "board meeting monday 9, print the agenda", title: "Board meeting, print the agenda",
                                   model: CaptureModelOutput(placeText: "board meeting", prepItems: ["print the agenda"]))
check("the words the message starts with are the activity, not the place", activity.placeText == nil && activity.steps == ["Print the agenda"], "\(activity)")
let earlyItem = CaptureCode.combine(message: "dentist 3pm at smile dental, be there 15 min early", title: "Dentist",
                                    model: CaptureModelOutput(placeText: "smile dental", prepItems: ["be there 15 min early"],
                                                              arriveEarlyText: "be there 15 min early", attendance: .inPerson))
check("arrive-early words never become an item", earlyItem.items.isEmpty && earlyItem.arriveEarlyMinutes == 15, "\(earlyItem)")
check("a named place attended in person means travel", earlyItem.likelyNeedsTravel)
let home = CaptureCode.combine(message: "game night at my place friday", title: "Game night",
                               model: CaptureModelOutput(placeText: "my place", attendance: .inPerson))
check("home is a place but not travel", home.placeText == "my place" && !home.likelyNeedsTravel, "\(home)")
let notEarly = CaptureCode.combine(message: "parent teacher conference wed 6pm", title: "Parent teacher conference",
                                   model: CaptureModelOutput(arriveEarlyText: "6pm", arriveEarlyBucket: .quarter))
check("arrive-early text must say early", notEarly.arriveEarlyMinutes == nil, "\(notEarly)")
check("'need to be there' is arrive-early talk, not an item", CaptureCode.isArriveEarlyPhrase("need to be there"))
let lead = CaptureCode.combine(message: "drinks at the tipsy cow", title: "Drinks", model: CaptureModelOutput(placeText: "at the tipsy cow"))
check("the place loses its 'at'", lead.placeText == "the tipsy cow", "\(lead)")
let eventItem = CaptureCode.combine(message: "pick up keys 22 oak ave 5pm", title: "Pick up keys", model: CaptureModelOutput(prepItems: ["pick up keys"]))
check("the event itself is never an item", eventItem.items.isEmpty)

print(failures == 0 ? "\nAll checks passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
