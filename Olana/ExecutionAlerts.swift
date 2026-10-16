//
//  ExecutionAlerts.swift
//  Olana
//
//  The execution alert namespace (PRD v6 §3.9, spec v3 §5.2). Built in M1-A,
//  empty until M1-C plans prep, get-ready, leave and join alerts. Pure
//  Foundation, so it runs in UrgencyProbe/Sources/PlannerChecks.
//
//  IDs are `olana.exec.{kind}.{eventUUID}.{planVersion}`. planVersion hashes
//  every input that decides an alert's time or text, so any change gives a new
//  ID and the diff replan always removes the stale one.
//

import Foundation

// MARK: - Kinds

/// Spec §5.2 lists prep, getReady, leave and leaveSnooze. PRD §3.9 also has a
/// Join alert (start − 1 min, Critical only); the PRD wins, so join is here.
enum ExecKind: String, CaseIterable, Codable {
    case prep, getReady, leave, leaveSnooze, join
}

extension AlertID {
    static func exec(_ kind: ExecKind, event: UUID, planVersion: String) -> String {
        exec(kind: kind.rawValue, event: event, planVersion: planVersion)
    }

    /// The parts of an execution ID, or nil for anything else.
    static func parseExec(_ id: String) -> (kind: ExecKind, event: UUID, planVersion: String)? {
        guard isExec(id) else { return nil }
        let parts = id.dropFirst(execPrefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let kind = ExecKind(rawValue: String(parts[0])),
              let event = UUID(uuidString: String(parts[1])), !parts[2].isEmpty else { return nil }
        return (kind, event, String(parts[2]))
    }
}

// MARK: - planVersion

/// Everything spec §5.2 says feeds planVersion. The M1-C fields are optional
/// so an event without them still gets a stable version.
struct ExecPlanInputs: Equatable {
    var start: Date
    var end: Date
    var leaveBy: Date?
    var getReadyAt: Date?
    var prepStartBy: Date?
    var assistMode: String?
    /// Series and event override versions, in that order.
    var overrideVersions: [Int] = []
    var settingsVersion: Int = 0

    /// 16 hex characters. FNV-1a over a canonical string, not `Hasher`, which
    /// is seeded per launch and would give every alert a new ID each launch.
    var planVersion: String {
        func t(_ d: Date?) -> String { d.map { "\(Int($0.timeIntervalSince1970))" } ?? "-" }
        let canonical = [
            t(start), t(end), t(leaveBy), t(getReadyAt), t(prepStartBy),
            assistMode ?? "-", overrideVersions.map(String.init).joined(separator: ","), "\(settingsVersion)",
        ].joined(separator: "|")
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in canonical.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }
}

// MARK: - Store

/// Pending execution IDs per event, with their planVersion (spec §8). Separate
/// from NotificationEngine's floor records. The replan rewrites it from the
/// plan it just applied, so it never drifts from what was asked of iOS.
final class ExecutionAlertStore {

    struct Entry: Codable, Equatable {
        let planVersion: String
        let ids: [String]
        let eventStart: Date
    }

    private(set) var entries: [UUID: Entry] = [:]
    private let url: URL

    static let shared = ExecutionAlertStore(url:
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("olana_exec_alerts.json"))

    init(url: URL) {
        self.url = url
        load()
    }

    func ids(for event: UUID) -> [String] { entries[event]?.ids ?? [] }

    var allIDs: Set<String> { Set(entries.values.flatMap(\.ids)) }

    /// Replace everything with the execution slots the replan kept.
    func replace(with kept: [AlertSlot]) {
        var next: [UUID: Entry] = [:]
        for (event, group) in Dictionary(grouping: kept.filter { $0.kind == .exec }, by: \.eventID) {
            let sorted = group.sorted { ($0.fireDate, $0.id) < ($1.fireDate, $1.id) }
            let version = AlertID.parseExec(sorted[0].id)?.planVersion ?? ""
            next[event] = Entry(planVersion: version, ids: sorted.map(\.id), eventStart: sorted[0].eventStart)
        }
        guard next != entries else { return }
        entries = next
        save()
    }

    func remove(_ event: UUID) {
        guard entries.removeValue(forKey: event) != nil else { return }
        save()
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        entries = Dictionary(uniqueKeysWithValues: decoded.compactMap { k, v in UUID(uuidString: k).map { ($0, v) } })
    }

    private func save() {
        let encoded = Dictionary(uniqueKeysWithValues: entries.map { ($0.key.uuidString, $0.value) })
        guard let data = try? JSONEncoder().encode(encoded) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Readable by background runs once the phone has been unlocked since restart (spec §8).
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
