import Foundation
import SQLite3

// Tells SQLite to copy bound text instead of borrowing the pointer.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct StoreError: Error, CustomStringConvertible {
    public let message: String
    public init(message: String) { self.message = message }
    public var description: String { message }
}

/// Minimal SQLite wrapper. Not thread-safe: the owning engine serializes access.
final class SQLiteDB {
    private(set) var handle: OpaquePointer?

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        if sqlite3_open_v2(path, &handle, flags, nil) != SQLITE_OK {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            // A failed open still returns a handle; deinit closes it, so it must not close here too.
            throw StoreError(message: "SQLite açılamadı (\(path)): \(msg)")
        }
        sqlite3_busy_timeout(handle, 5000)
    }

    deinit { sqlite3_close(handle) }

    var errorMessage: String { String(cString: sqlite3_errmsg(handle)) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(err)
            throw StoreError(message: "SQL hatası: \(msg)")
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw StoreError(message: "SQL hazırlanamadı: \(errorMessage)")
        }
        return Statement(stmt: stmt, db: self)
    }

    func userVersion() throws -> Int {
        Int(try prepare("PRAGMA user_version").firstInt() ?? 0)
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let r = try body()
            try exec("COMMIT")
            return r
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
}

final class Statement {
    let stmt: OpaquePointer
    unowned let db: SQLiteDB

    init(stmt: OpaquePointer, db: SQLiteDB) {
        self.stmt = stmt
        self.db = db
    }

    deinit { sqlite3_finalize(stmt) }

    func reset() {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
    }

    func bind(_ index: Int32, _ value: String?) {
        if let value { sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, index) }
    }
    func bind(_ index: Int32, _ value: Int64) { sqlite3_bind_int64(stmt, index, value) }
    func bind(_ index: Int32, _ value: Double) { sqlite3_bind_double(stmt, index, value) }

    @discardableResult
    func step() throws -> Bool {
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_ROW { return true }
        if rc == SQLITE_DONE { return false }
        throw StoreError(message: "SQL adımı başarısız: \(db.errorMessage)")
    }

    func string(_ col: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: c)
    }
    func int(_ col: Int32) -> Int64 { sqlite3_column_int64(stmt, col) }
    func isNull(_ col: Int32) -> Bool { sqlite3_column_type(stmt, col) == SQLITE_NULL }
    func double(_ col: Int32) -> Double { sqlite3_column_double(stmt, col) }

    func firstInt() throws -> Int64? {
        try step() ? int(0) : nil
    }
}