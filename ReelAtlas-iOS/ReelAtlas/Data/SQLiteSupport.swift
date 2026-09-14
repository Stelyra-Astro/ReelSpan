import Foundation
import SQLite3

enum SQLiteError: Error, LocalizedError {
    case open(String)
    case prepare(String)
    case step(String)
    case bind(String)

    var errorDescription: String? {
        switch self {
        case .open(let message), .prepare(let message), .step(let message), .bind(let message): return message
        }
    }
}

enum SQLiteBindValue {
    case int(Int)
    case double(Double)
    case text(String)
    case null
}

final class SQLiteDatabase {
    let handle: OpaquePointer

    init(url: URL, readOnly: Bool) throws {
        var db: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX)
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open SQLite database"
            if let db { sqlite3_close(db) }
            throw SQLiteError.open(message)
        }
        handle = db
        sqlite3_busy_timeout(handle, 1500)
    }

    deinit { sqlite3_close(handle) }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(error)
            throw SQLiteError.step(message)
        }
    }

    func prepare(_ sql: String, bindings: [SQLiteBindValue] = []) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteError.prepare(String(cString: sqlite3_errmsg(handle)))
        }
        do {
            for (offset, value) in bindings.enumerated() { try bind(value, to: statement, index: Int32(offset + 1)) }
            return statement
        } catch {
            sqlite3_finalize(statement)
            throw error
        }
    }

    private func bind(_ value: SQLiteBindValue, to statement: OpaquePointer, index: Int32) throws {
        let result: Int32
        switch value {
        case .int(let value): result = sqlite3_bind_int64(statement, index, sqlite3_int64(value))
        case .double(let value): result = sqlite3_bind_double(statement, index, value)
        case .text(let value):
            result = value.withCString { sqlite3_bind_text(statement, index, $0, -1, SQLITE_TRANSIENT) }
        case .null: result = sqlite3_bind_null(statement, index)
        }
        guard result == SQLITE_OK else { throw SQLiteError.bind(String(cString: sqlite3_errmsg(handle))) }
    }

    func step(_ statement: OpaquePointer) throws -> Bool {
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW { return true }
        if result == SQLITE_DONE { return false }
        throw SQLiteError.step(String(cString: sqlite3_errmsg(handle)))
    }

    func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL, let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    func int(_ statement: OpaquePointer, _ index: Int32) -> Int { Int(sqlite3_column_int64(statement, index)) }
    func double(_ statement: OpaquePointer, _ index: Int32) -> Double { sqlite3_column_double(statement, index) }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
