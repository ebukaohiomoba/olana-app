//
//  CalendarPersistence.swift
//  Olana
//
//  Local-only SwiftData container for UserCalendar and CalendarPreferences.
//  These models are intentionally NOT in the CloudKit-backed Persistence store
//  because EKCalendar identifiers are per-device UUIDs — syncing them cross-device
//  would produce meaningless duplicate records.
//

import Foundation
import SwiftData

final class CalendarPersistence {
    static let shared = CalendarPersistence()

    let container: ModelContainer

    init(inMemory: Bool = false) {
        let schema = Schema([UserCalendar.self, CalendarPreferences.self])

        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let storeURL   = appSupport.appendingPathComponent("olana_calendar.store")
            configuration  = ModelConfiguration(schema: schema, url: storeURL)
        }

        do {
            container = try ModelContainer(for: schema, configurations: [configuration])
            print("✅ CalendarPersistence: local store ready.")
        } catch {
            // Wipe and recreate — calendar data is re-populated from EventKit on next sync.
            print("⚠️ CalendarPersistence: store failed — deleting and recreating. Error: \(error)")
            let appSupport  = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let storeURL    = appSupport.appendingPathComponent("olana_calendar.store")
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(
                    at: URL(fileURLWithPath: storeURL.path + suffix)
                )
            }
            do {
                let freshConfig = ModelConfiguration(schema: schema, url: storeURL)
                container = try ModelContainer(for: schema, configurations: [freshConfig])
                print("✅ CalendarPersistence: recreated clean store.")
            } catch {
                fatalError("CalendarPersistence: unable to create ModelContainer: \(error)")
            }
        }
    }
}
