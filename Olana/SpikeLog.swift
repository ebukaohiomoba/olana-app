//
//  SpikeLog.swift
//  Olana
//
//  DEBUG only. An append-only JSONL log for the M0 device spikes (spec v3 §2.1):
//  S1 background model budget, S2 scheduled Live Activity, S3 locked since
//  reboot, S4 EventAssist latency, and the card's picks over a week of real use.
//
//  The file lives in the app's Documents folder and never leaves the phone
//  unless exported from Settings › Developer › M0 spikes.
//

#if DEBUG
import Foundation

enum SpikeLog {

    struct Entry: Codable, Identifiable {
        var id = UUID()
        let at: Date
        /// "s1", "s2", "s3", "s4", "card", "bg"
        let spike: String
        let event: String
        var fields: [String: String] = [:]
    }

    static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("m0_spikes.jsonl")
    }

    private static let queue = DispatchQueue(label: "olana.spikelog")

    static func write(_ spike: String, _ event: String, _ fields: [String: String] = [:]) {
        let entry = Entry(at: Date(), spike: spike, event: event, fields: fields)
        queue.sync {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            guard var data = try? enc.encode(entry) else { return }
            data.append(0x0A)
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(data)
                try? h.close()
            } else {
                // Readable before first unlock, so S3 can record that it ran.
                try? data.write(to: url, options: .noFileProtection)
            }
        }
        print("🧪 [\(spike)] \(event) \(fields)")
    }

    static func read() -> [Entry] {
        queue.sync {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            return text.split(separator: "\n").compactMap {
                try? dec.decode(Entry.self, from: Data($0.utf8))
            }
        }
    }

    static func clear() {
        queue.sync { try? FileManager.default.removeItem(at: url) }
    }
}
#endif
