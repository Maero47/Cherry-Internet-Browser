//
//  ImportSQLite.swift
//  Cherry Browser
//
//  Minimal SQLite reader for browser-import. The source database may be
//  locked/WAL while the other browser is running, so the file (plus any
//  sibling -wal/-shm/-journal) is copied to a private temp directory first
//  and only the copy is ever opened. The temp directory is removed when the
//  database is closed/deinitialized. The original files are never written.
//

import Foundation
import SQLite3

/// One row of a running query. Only valid inside the `forEachRow` callback.
struct ImportSQLiteRow {
    fileprivate let statement: OpaquePointer

    func text(_ column: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: cString)
    }

    func int64(_ column: Int32) -> Int64 {
        sqlite3_column_int64(statement, column)
    }

    func double(_ column: Int32) -> Double {
        sqlite3_column_double(statement, column)
    }

    func blob(_ column: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0 else { return nil }
        return Data(bytes: bytes, count: count)
    }

    func isNull(_ column: Int32) -> Bool {
        sqlite3_column_type(statement, column) == SQLITE_NULL
    }
}

/// Opens a temp copy of a SQLite database read-only and iterates queries.
final class ImportSQLiteDatabase {
    private var handle: OpaquePointer?
    private let tempDirectory: URL

    /// Copies `source` (and -wal/-shm/-journal siblings) into a fresh temp
    /// directory, then opens the copy. Throws `ImportError` on failure —
    /// including `.fullDiskAccessRequired` when the copy is denied by TCC.
    init(copying source: URL) throws {
        let fileManager = FileManager.default
        tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("CherryImport-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let copy = tempDirectory.appendingPathComponent(source.lastPathComponent)
        do {
            try fileManager.copyItem(at: source, to: copy)
            for suffix in ["-wal", "-shm", "-journal"] {
                let sibling = URL(fileURLWithPath: source.path + suffix)
                if fileManager.fileExists(atPath: sibling.path) {
                    try? fileManager.copyItem(at: sibling, to: URL(fileURLWithPath: copy.path + suffix))
                }
            }
        } catch {
            try? fileManager.removeItem(at: tempDirectory)
            throw ImportError.wrapping(error)
        }

        // READONLY is the goal; a WAL database whose -shm needs rebuilding can
        // refuse a read-only open, and since this is our own temp copy a
        // read-write fallback is still safe for the source.
        var db: OpaquePointer?
        if sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            sqlite3_close(db)
            db = nil
            if sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READWRITE, nil) != SQLITE_OK {
                let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open database copy"
                sqlite3_close(db)
                try? fileManager.removeItem(at: tempDirectory)
                throw ImportError.databaseError(message)
            }
        }
        handle = db
    }

    deinit {
        close()
    }

    func close() {
        if let handle {
            sqlite3_close(handle)
            self.handle = nil
        }
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    /// Runs `sql` and invokes `body` once per row.
    func forEachRow(_ sql: String, _ body: (ImportSQLiteRow) -> Void) throws {
        guard let handle else { throw ImportError.databaseError("database is closed") }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ImportError.databaseError(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }

        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
                body(ImportSQLiteRow(statement: statement))
            } else if result == SQLITE_DONE {
                break
            } else {
                throw ImportError.databaseError(String(cString: sqlite3_errmsg(handle)))
            }
        }
    }
}
