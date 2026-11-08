import Foundation
import SQLite3

/// A minimal SQLite connection. Not thread-safe: the owner confines it to one
/// serial queue.
final class SQLiteDB {
    private var handle: OpaquePointer?
    let path: String

    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    init(path: String, readOnly: Bool = false) throws {
        self.path = path
        var db: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            sqlite3_close(db)
            throw Failure(description: "open \(path): \(message)")
        }
        handle = db
        sqlite3_busy_timeout(db, 5_000)
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? lastError
            sqlite3_free(error)
            throw Failure(description: message)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw Failure(description: "prepare: \(lastError)")
        }
        return Statement(stmt, db: self)
    }

    /// Runs `body` in a transaction, rolling back if it throws.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    var lastError: String { String(cString: sqlite3_errmsg(handle)) }
    var changes: Int { Int(sqlite3_changes(handle)) }

    func quickCheck() throws -> Bool {
        let stmt = try prepare("PRAGMA quick_check")
        guard try stmt.step(), stmt.text(0) == "ok" else { return false }
        return try !stmt.step()
    }

    /// One row's first column as an integer, or nil when there is no row or it is NULL.
    func scalar(_ sql: String, _ args: [Value] = []) throws -> Int64? {
        let stmt = try prepare(sql)
        try stmt.bind(args)
        guard try stmt.step() else { return nil }
        return stmt.isNull(0) ? nil : stmt.int(0)
    }

    func run(_ sql: String, _ args: [Value] = []) throws {
        let stmt = try prepare(sql)
        try stmt.bind(args)
        while try stmt.step() {}
    }

    enum Value {
        case int(Int64)
        case real(Double)
        case text(String)
        case null

        static func optional(_ s: String?) -> Value { s.map(Value.text) ?? .null }
        static func optionalReal(_ d: Double?) -> Value { d.map(Value.real) ?? .null }
    }

    final class Statement {
        private let stmt: OpaquePointer
        private let db: SQLiteDB

        fileprivate init(_ stmt: OpaquePointer, db: SQLiteDB) {
            self.stmt = stmt
            self.db = db
        }

        deinit { sqlite3_finalize(stmt) }

        private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        func bind(_ values: [Value]) throws {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            for (i, value) in values.enumerated() {
                let index = Int32(i + 1)
                let rc: Int32 = switch value {
                case .int(let v): sqlite3_bind_int64(stmt, index, v)
                case .real(let v): sqlite3_bind_double(stmt, index, v)
                case .text(let v): sqlite3_bind_text(stmt, index, v, -1, Self.transient)
                case .null: sqlite3_bind_null(stmt, index)
                }
                guard rc == SQLITE_OK else { throw Failure(description: "bind: \(db.lastError)") }
            }
        }

        /// Advances one row; false when done.
        func step() throws -> Bool {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW: return true
            case SQLITE_DONE: return false
            default: throw Failure(description: "step: \(db.lastError)")
            }
        }

        func int(_ column: Int32) -> Int64 { sqlite3_column_int64(stmt, column) }
        func real(_ column: Int32) -> Double { sqlite3_column_double(stmt, column) }
        func isNull(_ column: Int32) -> Bool { sqlite3_column_type(stmt, column) == SQLITE_NULL }
        func text(_ column: Int32) -> String? {
            guard let p = sqlite3_column_text(stmt, column) else { return nil }
            return String(cString: p)
        }
    }
}
