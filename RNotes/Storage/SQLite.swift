//
//  SQLite.swift
//  RNotes — Copyright (c) 2026 RTECH OSS. MIT License.
//
//  A small, dependency-free wrapper around the system SQLite3 library.
//

import Foundation
import SQLite3

enum SQLiteError: Error, LocalizedError {
    case open(String)
    case prepare(String, sql: String)
    case step(String)
    case bind(String)
    case exec(String)

    var errorDescription: String? {
        switch self {
        case .open(let m): return "Could not open database: \(m)"
        case .prepare(let m, let sql): return "SQL prepare failed: \(m) — \(sql)"
        case .step(let m): return "SQL step failed: \(m)"
        case .bind(let m): return "SQL bind failed: \(m)"
        case .exec(let m): return "SQL exec failed: \(m)"
        }
    }
}

/// Values that can be bound to statement parameters.
enum SQLValue {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

/// Tells SQLite to copy bound buffers immediately.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class SQLiteDB {
    fileprivate var handle: OpaquePointer?

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &handle, flags, nil) != SQLITE_OK {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            handle = nil
            throw SQLiteError.open(message)
        }
        try execute("PRAGMA foreign_keys = ON;")
        try execute("PRAGMA journal_mode = WAL;")
        // Overwrite deleted content with zeros so old (encrypted) data isn't left behind in free pages.
        try execute("PRAGMA secure_delete = ON;")
    }

    deinit {
        sqlite3_close(handle)
    }

    var errorMessage: String {
        guard let handle = handle else { return "database closed" }
        return String(cString: sqlite3_errmsg(handle))
    }

    /// Runs one or more SQL statements that return no rows.
    func execute(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(err)
            throw SQLiteError.exec(message)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) != SQLITE_OK || stmt == nil {
            throw SQLiteError.prepare(errorMessage, sql: sql)
        }
        return Statement(stmt: stmt!, db: self)
    }

    /// Runs a single statement with parameters, ignoring any result rows.
    func run(_ sql: String, _ values: [SQLValue] = []) throws {
        let stmt = try prepare(sql)
        try stmt.bind(values)
        while try stmt.step() {}
    }

    /// Runs a query and maps each row.
    func query<T>(_ sql: String, _ values: [SQLValue] = [], map: (Statement) throws -> T) throws -> [T] {
        let stmt = try prepare(sql)
        try stmt.bind(values)
        var results: [T] = []
        while try stmt.step() {
            results.append(try map(stmt))
        }
        return results
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try body()
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    var changes: Int { Int(sqlite3_changes(handle)) }

    func userVersion() throws -> Int {
        try query("PRAGMA user_version;") { Int($0.int(0)) }.first ?? 0
    }

    func setUserVersion(_ v: Int) throws {
        try execute("PRAGMA user_version = \(v);")
    }
}

final class Statement {
    private let stmt: OpaquePointer
    private let db: SQLiteDB

    fileprivate init(stmt: OpaquePointer, db: SQLiteDB) {
        self.stmt = stmt
        self.db = db
    }

    deinit {
        sqlite3_finalize(stmt)
    }

    func bind(_ values: [SQLValue]) throws {
        for (offset, value) in values.enumerated() {
            let idx = Int32(offset + 1)
            let rc: Int32
            switch value {
            case .null:
                rc = sqlite3_bind_null(stmt, idx)
            case .int(let i):
                rc = sqlite3_bind_int64(stmt, idx, i)
            case .double(let d):
                rc = sqlite3_bind_double(stmt, idx, d)
            case .text(let s):
                rc = sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            case .blob(let data):
                if data.isEmpty {
                    rc = sqlite3_bind_zeroblob(stmt, idx, 0)
                } else {
                    rc = data.withUnsafeBytes { buf in
                        sqlite3_bind_blob(stmt, idx, buf.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
                    }
                }
            }
            if rc != SQLITE_OK { throw SQLiteError.bind(db.errorMessage) }
        }
    }

    /// Advances the statement. Returns true when a row is available.
    @discardableResult
    func step() throws -> Bool {
        let rc = sqlite3_step(stmt)
        switch rc {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw SQLiteError.step(db.errorMessage)
        }
    }

    func isNull(_ col: Int32) -> Bool {
        sqlite3_column_type(stmt, col) == SQLITE_NULL
    }

    func int(_ col: Int32) -> Int64 {
        sqlite3_column_int64(stmt, col)
    }

    func double(_ col: Int32) -> Double {
        sqlite3_column_double(stmt, col)
    }

    func text(_ col: Int32) -> String? {
        guard let ptr = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: ptr)
    }

    func blob(_ col: Int32) -> Data? {
        if isNull(col) { return nil }
        let count = Int(sqlite3_column_bytes(stmt, col))
        guard count > 0, let ptr = sqlite3_column_blob(stmt, col) else { return Data() }
        return Data(bytes: ptr, count: count)
    }
}
