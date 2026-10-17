import Foundation
import SQLite3

final class Database {
    let handle: OpaquePointer
    let path: String
    init(_ path: String, writable: Bool = false, create: Bool = false) throws {
        self.path = path
        var db: OpaquePointer?
        let flags = writable ? SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0) : SQLITE_OPEN_READONLY
        guard sqlite3_open_v2(path, &db, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw StudioError(L("Could not open Launchpad data. Check file access permissions."))
        }
        handle = db
        sqlite3_busy_timeout(db, 2500)
    }
    deinit { sqlite3_close(handle) }
    func execute(_ sql: String, _ params: [String?] = []) throws {
        _ = try rows(sql, params)
    }
    func rows(_ sql: String, _ params: [String?] = []) throws -> [[String: String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StudioError(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in params.enumerated() {
            if let value {
                sqlite3_bind_text(
                    statement, Int32(index + 1), value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            } else {
                sqlite3_bind_null(statement, Int32(index + 1))
            }
        }
        var result: [[String: String]] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            var row: [String: String] = [:]
            for i in 0..<sqlite3_column_count(statement) {
                if let val = sqlite3_column_text(statement, i) {
                    row[String(cString: sqlite3_column_name(statement, i))] = String(cString: val)
                }
            }
            result.append(row)
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw StudioError(String(cString: sqlite3_errmsg(handle))) }
        return result
    }
    func snapshot(to url: URL) throws {
        let dest = try Database(url.path, writable: true, create: true)
        guard let backup = sqlite3_backup_init(dest.handle, "main", handle, "main") else {
            throw StudioError(L("Could not start the backup."))
        }
        let status = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard status == SQLITE_DONE, finish == SQLITE_OK else {
            throw StudioError(L("Could not create a consistent backup. Try again."))
        }
        guard try dest.rows("PRAGMA integrity_check").first?.values.first == "ok" else {
            throw StudioError(L("Backup integrity check failed."))
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
