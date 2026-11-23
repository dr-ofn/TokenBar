import Foundation
import SQLite3

/// `~/.gemini/antigravity-cli/conversations/<id>.db`. Every model call is a `steps` row with
/// `step_type = 15`; its protobuf `metadata` holds the creation time (field 1), completion
/// time (8) and usage (9: 1 model enum, 2 input, 3 output incl. thinking, 4 cache write,
/// 5 cache read, 9 thinking). `gen_metadata` rows name the model: enum at 1.3, name at 1.19.
enum AntigravityReader {
    /// No single call reaches this; a larger number means Antigravity moved its fields.
    private static let impossibleCount: UInt64 = 1 << 40

    static func events(dbPath: String, conversation: String) throws -> [UsageEvent] {
        // Not immutable: a `-wal` beside the database holds the newest calls, and ExternalDB reads such a pair from a copy.
        let db = try ExternalDB(path: dbPath, immutable: false)
        let models = try loadModels(from: db)
        return try loadEvents(from: db, models: models, conversation: conversation, dbPath: dbPath)
    }

    private static func loadModels(from db: ExternalDB) throws -> [UInt64: String] {
        var models: [UInt64: String] = [:]
        try db.query("SELECT data FROM gen_metadata ORDER BY idx") { st in
            let data = ExternalDB.blob(st, 0)
            guard let f1 = Proto.first(data, path: [1]) else { return }
            guard let modelEnum = Proto.varints(f1)[3] else { return }
            guard let name = Proto.first(f1, path: [19]).flatMap({ String(data: $0, encoding: .utf8) }), !name.isEmpty else { return }
            models[modelEnum] = name
        }
        return models
    }

    private static func loadEvents(from db: ExternalDB, models: [UInt64: String], conversation: String, dbPath: String) throws -> [UsageEvent] {
        var out: [UsageEvent] = []
        try db.query("SELECT idx, metadata FROM steps WHERE step_type = 15 ORDER BY idx") { st in
            let idx = sqlite3_column_int64(st, 0)
            let meta = ExternalDB.blob(st, 1)
            guard let usage = Proto.first(meta, path: [9]) else { return }
            let u = Proto.varints(usage)
            guard [2, 3, 4, 5, 9].allSatisfy({ (u[$0] ?? 0) < impossibleCount }) else {
                throw StoreError(message: L10n.t("\(dbPath): adım \(idx) kullanım alanları anlaşılmadı", "\(dbPath): step \(idx): usage fields not understood"))
            }
            let modelEnum = u[1] ?? 0
            let name = models[modelEnum] ?? "antigravity-model-\(modelEnum)"
            let tokens = TokenCounts(input: Int64(u[2] ?? 0),
                                     cacheRead: Int64(u[5] ?? 0),
                                     cacheWrite: Int64(u[4] ?? 0),
                                     output: Int64(u[3] ?? 0),
                                     reasoning: Int64(u[9] ?? 0))
            guard !tokens.isZero else { return }
            let ts = Proto.timestamp(meta, field: 8) ?? Proto.timestamp(meta, field: 7) ?? Proto.timestamp(meta, field: 1) ?? 0
            out.append(UsageEvent(key: "ag:\(conversation):\(idx)", provider: "google-antigravity",
                                  model: name, timestamp: ts, tokens: tokens, session: conversation,
                                  file: dbPath))
        }
        return out
    }
}

/// Minimal protobuf wire-format reader.
enum Proto {
    /// Top-level fields as (number, wireType, varint value, length-delimited bytes).
    static func fields(_ d: Data) -> [(Int, Int, UInt64, Data?)]? {
        var out: [(Int, Int, UInt64, Data?)] = []
        var i = d.startIndex
        func varint() -> UInt64? {
            var r: UInt64 = 0, s: UInt64 = 0
            while i < d.endIndex {
                let b = d[i]; i += 1
                r |= UInt64(b & 0x7f) << s
                if b < 0x80 { return r }
                s += 7
                if s > 63 { return nil }
            }
            return nil
        }
        while i < d.endIndex {
            guard let key = varint() else { return nil }
            let f = Int(key >> 3), w = Int(key & 7)
            switch w {
            case 0:
                guard let v = varint() else { return nil }
                out.append((f, 0, v, nil))
            case 1:
                guard d.endIndex - i >= 8 else { return nil }
                i += 8
                out.append((f, 1, 0, nil))
            case 2:
                guard let l = varint(), l <= UInt64(d.endIndex - i) else { return nil }
                let sub = d[i..<(i + Int(l))]
                i += Int(l)
                out.append((f, 2, 0, Data(sub)))
            case 5:
                guard d.endIndex - i >= 4 else { return nil }
                i += 4
                out.append((f, 5, 0, nil))
            default:
                return nil
            }
        }
        return out
    }

    /// First length-delimited value at a field path.
    static func first(_ d: Data, path: [Int]) -> Data? {
        var cur = d
        for p in path {
            guard let fs = fields(cur), let next = fs.first(where: { $0.0 == p && $0.1 == 2 })?.3 else { return nil }
            cur = next
        }
        return cur
    }

    static func varints(_ d: Data) -> [Int: UInt64] {
        var out: [Int: UInt64] = [:]
        for f in fields(d) ?? [] where f.1 == 0 {
            out[f.0] = f.2
        }
        return out
    }

    /// google.protobuf.Timestamp at `field` → Unix seconds.
    static func timestamp(_ d: Data, field: Int) -> Double? {
        guard let t = first(d, path: [field]) else { return nil }
        let v = varints(t)
        guard let s = v[1], s > 1_000_000_000 else { return nil }
        return Double(s) + Double(v[2] ?? 0) / 1e9
    }
}
