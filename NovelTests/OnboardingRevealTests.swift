//
//  OnboardingRevealTests.swift
//  NovelTests
//
//  The onboarding reveal's rows and the card it ends on (OnboardingReveal.snapshot).
//

import Foundation
import Testing
@testable import Olana

struct OnboardingRevealTests {
    let now = Date()

    func ev(_ title: String, in minutes: Double, _ u: EventUrgency = .medium, prep: Double? = nil,
            assisted: Bool = true, allDay: Bool = false, task: Bool = false) -> HomeDayBuilder.Input {
        let start = now.addingTimeInterval(minutes * 60)
        return .init(id: UUID(), title: title, start: start, end: start.addingTimeInterval(3600), isAllDay: allDay,
                     isTask: task, completed: false, completedAt: nil, isRecurring: false, location: nil, urgency: u,
                     scored: nil, prepHours: prep, assisted: assisted)
    }

    @Test func rowsAreTheNextTimedEventsThisWeek() {
        let inputs = [ev("Later", in: 300), ev("Soon", in: 30), ev("All day", in: 60, allDay: true),
                      ev("Task", in: 90, task: true), ev("Next week", in: 8 * 24 * 60)]
        let s = OnboardingReveal.snapshot(inputs: inputs, judged: [], now: now, done: false)
        let titles = s.rows.map { $0.title }
        #expect(titles == ["Soon", "Later"])
        #expect(s.card == nil)   // no card until reading is done
    }

    @Test func endsOnTheCardHomeWouldShow() {
        let review = ev("Client review", in: 170, .high, prep: 40.0 / 60)
        let inputs = [ev("Standup", in: 40, .low, assisted: false), review, ev("Dentist", in: 24 * 60)]
        let s = OnboardingReveal.snapshot(inputs: inputs, judged: Set(inputs.map(\.id)), now: now, done: true)
        #expect(s.card?.eventID == review.id)
        #expect(s.card?.lead == "Start prepping by ")
        let standupMatters = s.rows.first { $0.title == "Standup" }?.matters
        let allJudged = s.rows.allSatisfy { $0.judged }
        #expect(standupMatters == false)
        #expect(allJudged)
    }

    @Test func theCardsEventIsAlwaysAmongTheRows() {
        var inputs = (0..<6).map { ev("Routine \($0)", in: Double(30 + $0 * 30), .low, assisted: false) }
        let exam = ev("Exam", in: 3 * 24 * 60, .high, prep: 12)
        inputs.append(exam)
        let s = OnboardingReveal.snapshot(inputs: inputs, judged: [], now: now, done: true)
        #expect(s.rows.count == OnboardingReveal.maxRows)
        let examShown = s.rows.contains { $0.id == exam.id }
        #expect(examShown)
        #expect(s.card?.eventID == exam.id)
    }

    @Test func anEmptyWeekHasNoRowsAndNoCard() {
        let s = OnboardingReveal.snapshot(inputs: [], judged: [], now: now, done: true)
        let empty = s.rows.isEmpty && s.card == nil
        #expect(empty)
    }

    @Test func theStripSaysWhenToStart() {
        let review = ev("Client review", in: 170, .high, prep: 40.0 / 60)
        let dentist = ev("Dentist", in: 300, .medium)
        let standup = ev("Standup", in: 40, .low, assisted: false)
        let exam = ev("Exam", in: 3 * 24 * 60, .high, prep: 2)
        let s = OnboardingReveal.snapshot(inputs: [review, dentist, standup, exam], judged: [], now: now, done: false)
        func line(_ e: HomeDayBuilder.Input) -> String {
            let r = s.rows.first { $0.id == e.id }!
            let l = OnboardingReveal.line(r, now: now)
            return l.text + l.gold
        }
        #expect(line(review) == "40 min prep · start " + HomeFormat.clock(review.start.addingTimeInterval(-40 * 60)))
        #expect(line(dentist) == "matters · no prep needed")
        #expect(line(standup) == "doesn't need you")
        // Days away: by a part of the day, like home's card.
        #expect(line(exam).hasPrefix("2 h prep · prep by "))
    }

    @Test func prepAlreadyDueSaysNow() {
        let soon = ev("Interview", in: 20, .high, prep: 1)
        let s = OnboardingReveal.snapshot(inputs: [soon], judged: [], now: now, done: false)
        let l = OnboardingReveal.line(s.rows[0], now: now)
        #expect(l.text == "1 h prep · start ")
        #expect(l.gold == "now")
    }
}
