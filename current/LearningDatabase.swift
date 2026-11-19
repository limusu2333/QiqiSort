import Foundation
import SQLite3

// The journal is authoritative. Derived classifiers can always be rebuilt from these rows.
final class LearningDatabase {
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard sqlite3_open_v2(directory.appendingPathComponent("feedback.sqlite").path, &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw GatherError.message("无法打开长期经验数据库")
        }
        sqlite3_busy_timeout(db, 5000)
        try execute("PRAGMA journal_mode=DELETE")
        try execute("PRAGMA synchronous=FULL")
        try execute("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS feedback (seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT UNIQUE NOT NULL, task TEXT NOT NULL, basis TEXT NOT NULL, exception TEXT NOT NULL, payload BLOB NOT NULL, revoked TEXT)")
        try execute("CREATE INDEX IF NOT EXISTS feedback_task ON feedback(task,basis,exception)")
        try transaction {
            if try scalar("SELECT value FROM metadata WHERE key='schema'") == nil {
                let legacy = directory.appendingPathComponent("feedback.json")
                if FileManager.default.fileExists(atPath: legacy.path) {
                    let journal = try CurationFiles.read(LearningJournal.self, legacy)
                    guard journal.schemaVersion == 1 else { throw GatherError.message("旧经验格式不受支持，原文件已保留") }
                    for example in journal.examples { try put(example) }
                }
                try execute("INSERT INTO metadata(key,value) VALUES('schema','2')")
            }
            if try scalar("SELECT value FROM metadata WHERE key='schema'") == "1" {
                try execute("ALTER TABLE feedback ADD COLUMN revoked TEXT")
                let legacy = try examples()
                for example in legacy { try put(example) }
                try execute("UPDATE metadata SET value='2' WHERE key='schema'")
            }
            guard try scalar("SELECT value FROM metadata WHERE key='schema'") == "2" else {
                throw GatherError.message("长期经验数据库版本不受支持")
            }
        }
    }
    deinit { sqlite3_close(db) }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        return statement
    }
    private func failure() -> GatherError {
        GatherError.message("长期经验数据库错误：" + String(cString: sqlite3_errmsg(db)))
    }
    private func bind(_ values: [String], to statement: OpaquePointer) throws {
        for (index, value) in values.enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) == SQLITE_OK else { throw failure() }
        }
    }
    func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    func transaction(_ operation: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try operation(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private func scalar(_ sql: String) throws -> String? {
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { throw failure() }
        return String(cString: value)
    }
    func dataVersion() throws -> String {
        guard let version = try scalar("PRAGMA data_version") else { throw failure() }
        return version
    }
    func examples(where condition: String = "1", values: [String] = []) throws -> [LearningExample] {
        let statement = try prepare("SELECT payload,revoked FROM feedback WHERE " + condition + " ORDER BY seq")
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        var result = [LearningExample]()
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW, let pointer = sqlite3_column_blob(statement, 0) else { throw failure() }
            let bytes = Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, 0)))
            var example = try JSONDecoder().decode(LearningExample.self, from: bytes)
            if let revoked = sqlite3_column_text(statement, 1) { example.revokedAt = String(cString: revoked) }
            result.append(example)
        }
    }
    func put(_ example: LearningExample) throws {
        let statement = try prepare("INSERT INTO feedback(id,task,basis,exception,payload,revoked) VALUES(?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload,revoked=excluded.revoked")
        defer { sqlite3_finalize(statement) }
        try bind([example.id, example.taskID, example.basis, example.exception.id], to: statement)
        let bytes = try JSONEncoder().encode(example)
        let code = bytes.withUnsafeBytes { sqlite3_bind_blob(statement, 5, $0.baseAddress, Int32($0.count), transient) }
        if let revoked = example.revokedAt {
            guard sqlite3_bind_text(statement, 6, revoked, -1, transient) == SQLITE_OK else { throw failure() }
        }
        guard code == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }
    func supersede(_ example: LearningExample) throws {
        let statement = try prepare("UPDATE feedback SET revoked=? WHERE task=? AND basis=? AND exception=? AND revoked IS NULL")
        defer { sqlite3_finalize(statement) }
        try bind([example.createdAt, example.taskID, example.basis, example.exception.id], to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }
}
