import Foundation
import SQLite3

enum SQLiteValue: Sendable {
    case text(String)
    case int(Int64)
    case double(Double)
    case blob(Data)
    case null

    var stringValue: String? {
        switch self {
        case .text(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .blob: return nil
        case .null: return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .int(let i): return Int(i)
        case .double(let d): return Int(d)
        case .text(let s): return Int(s)
        case .blob, .null: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        case .text(let s): return Double(s)
        case .blob, .null: return nil
        }
    }

    var dataValue: Data? {
        switch self {
        case .blob(let data): return data
        default: return nil
        }
    }
}

enum SQLiteReader {
    static func query(databaseURL: URL, sql: String) -> [[String: SQLiteValue]] {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return []
        }

        if let rows = executeQuery(path: databaseURL.path, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, sql: sql) {
            return rows
        }

        // Fallback for closed WAL databases where -shm cannot be created in read-only mode
        let encoded = databaseURL.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? databaseURL.path
        let immutableURI = "file:\(encoded)?immutable=1"
        return executeQuery(
            path: immutableURI,
            flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX,
            sql: sql
        ) ?? []
    }

    private static func executeQuery(path: String, flags: Int32, sql: String) -> [[String: SQLiteValue]]? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }

        sqlite3_busy_timeout(db, 400)

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        let columnCount = sqlite3_column_count(stmt)
        let columnNames: [String] = (0..<columnCount).map { idx in
            if let cName = sqlite3_column_name(stmt, idx) {
                return String(cString: cName)
            }
            return "col_\(idx)"
        }

        var rows: [[String: SQLiteValue]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: SQLiteValue] = [:]
            row.reserveCapacity(Int(columnCount))
            for idx in 0..<columnCount {
                let name = columnNames[Int(idx)]
                switch sqlite3_column_type(stmt, idx) {
                case SQLITE_INTEGER:
                    row[name] = .int(sqlite3_column_int64(stmt, idx))
                case SQLITE_FLOAT:
                    row[name] = .double(sqlite3_column_double(stmt, idx))
                case SQLITE_TEXT:
                    if let cText = sqlite3_column_text(stmt, idx) {
                        row[name] = .text(String(cString: cText))
                    } else {
                        row[name] = .null
                    }
                case SQLITE_BLOB:
                    if let bytes = sqlite3_column_blob(stmt, idx) {
                        let count = Int(sqlite3_column_bytes(stmt, idx))
                        row[name] = .blob(Data(bytes: bytes, count: count))
                    } else {
                        row[name] = .null
                    }
                default:
                    row[name] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }
}
