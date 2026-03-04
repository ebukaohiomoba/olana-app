import Foundation
import SwiftData

final class Persistence {
    static let shared = Persistence()

    let container: ModelContainer

    init(inMemory: Bool = false) {
        // Models synced via CloudKit.
        // Calendar models (UserCalendar, CalendarPreferences) live in CalendarPersistence —
        // a separate local-only store, because EKCalendar identifiers are per-device UUIDs.
        let schema = Schema([OlanaEvent.self, UserPreferences.self])

        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        } else {
            // cloudKitDatabase: .automatic uses the app's default iCloud container
            // (iCloud.<bundle-id>). Requires:
            //   1. iCloud capability enabled in Xcode Signing & Capabilities
            //   2. CloudKit checked under iCloud Services
            //   3. A CloudKit container created (Xcode does this automatically on
            //      first run if the container doesn't exist yet)
            configuration = ModelConfiguration(cloudKitDatabase: .automatic)
        }

        do {
            container = try ModelContainer(for: schema, configurations: [configuration])
            print("✅ Persistence: CloudKit-backed container ready.")
        } catch {
            // CloudKit unavailable — most common causes:
            //   • Running in Simulator without a signed-in iCloud account
            //   • iCloud capability not yet configured in Xcode
            //   • First run before CloudKit container has been initialised
            // Fall back to a plain local store so the app stays usable.
            print("⚠️ Persistence: CloudKit init failed (\(error)). Falling back to local store.")

            let appSupport  = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let fallbackURL = appSupport.appendingPathComponent("olana_local.store")
            let fallback    = ModelConfiguration(url: fallbackURL)

            do {
                container = try ModelContainer(for: schema, configurations: [fallback])
                print("✅ Persistence: local fallback store ready.")
            } catch {
                // TODO: For App Store releases replace with VersionedSchema +
                // SchemaMigrationPlan instead of deleting data.
                print("⚠️ Persistence: fallback store failed — deleting and recreating.")
                for suffix in ["", "-shm", "-wal"] {
                    try? FileManager.default.removeItem(
                        at: URL(fileURLWithPath: fallbackURL.path + suffix)
                    )
                }
                do {
                    container = try ModelContainer(for: schema, configurations: [fallback])
                } catch {
                    fatalError("Persistence: unable to create ModelContainer: \(error)")
                }
            }
        }
    }
}
