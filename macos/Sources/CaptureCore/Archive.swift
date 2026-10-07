import Foundation
import SQLite3
import Darwin

public struct Record: Equatable {
    public let id: String
    public let timestamp: Date
    public let text: String
    public let image: Data
}

public enum ArchiveError: LocalizedError {
    case unsafePath, database(String), invalidRecord, invalidRetention
    public var errorDescription: String? {
        switch self {
        case .unsafePath: return "保存先が安全なディレクトリではありません"
        case .database: return "保存データの読み書きに失敗しました"
        case .invalidRecord: return "記録データが不正です"
        case .invalidRetention: return "保持期間は1・3・7日から選択してください"
        }
    }
}

/// Main-thread/serial-owner only. Image and OCR are committed and deleted in one row.
public final class Archive {
    public let root: URL
    private var db: OpaquePointer?
    private let budget: Int64
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    public init(root: URL, budget: Int64 = 2_000_000_000) throws {
        self.root = root; self.budget = budget
        try open()
    }
    deinit { sqlite3_close(db) }
    private func open() throws {
        let fm = FileManager.default
        // Never follow a pre-existing symlink at a storage boundary.
        var parent = root
        while parent.path != "/" {
            if let a = try? fm.attributesOfItem(atPath: parent.path), a[.type] as? FileAttributeType == .typeSymbolicLink {
                throw ArchiveError.unsafePath
            }
            parent.deleteLastPathComponent()
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attrs = try fm.attributesOfItem(atPath: root.path)
        guard attrs[.type] as? FileAttributeType == .typeDirectory,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw ArchiveError.unsafePath }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        var excluded = root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        let path = root.appendingPathComponent("archive.sqlite").path
        for suffix in ["", "-wal", "-shm", "-journal"] {
            if let a = try? fm.attributesOfItem(atPath: path + suffix) {
                guard a[.type] as? FileAttributeType == .typeRegular,
                      (a[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                      (a[.referenceCount] as? NSNumber)?.intValue == 1 else { throw ArchiveError.unsafePath }
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path + suffix)
            }
        }
        let fd = Darwin.open(path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        if fd >= 0 { close(fd) } else if errno != EEXIST { throw ArchiveError.unsafePath }
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw failure() }
        sqlite3_busy_timeout(db, 250)
        try exec("PRAGMA journal_mode=DELETE; PRAGMA secure_delete=ON; PRAGMA synchronous=FULL;")
        try exec("CREATE TABLE IF NOT EXISTS records (id TEXT PRIMARY KEY, ts REAL NOT NULL, text TEXT NOT NULL, image BLOB NOT NULL); CREATE INDEX IF NOT EXISTS records_ts ON records(ts);")
    }
    private func failure() -> ArchiveError { .database(db.map { String(cString: sqlite3_errmsg($0)) } ?? "closed") }
    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw failure() }
        return stmt
    }
    public func save(image: Data, text: String, at date: Date, retentionDays: Int, now: Date = Date()) throws {
        guard [1, 3, 7].contains(retentionDays) else { throw ArchiveError.invalidRetention }
        guard !image.isEmpty, image.count <= 50_000_000, text.utf8.count <= 5_000_000,
              date.timeIntervalSince1970.isFinite, date <= now.addingTimeInterval(60),
              date > now.addingTimeInterval(-Double(retentionDays) * 86400),
              Int64(image.count + text.utf8.count) <= budget else { throw ArchiveError.invalidRecord }
        try exec("BEGIN IMMEDIATE")
        do {
            let stmt = try statement("INSERT INTO records VALUES (?, ?, ?, ?)")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, UUID().uuidString, -1, transient)
            sqlite3_bind_double(stmt, 2, date.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 3, text, Int32(text.utf8.count), transient)
            _ = image.withUnsafeBytes { sqlite3_bind_blob(stmt, 4, $0.baseAddress, Int32(image.count), transient) }
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
            try prune(retentionDays: retentionDays, now: now)
            try exec("COMMIT")
        } catch { try? exec("ROLLBACK"); throw error }
    }
    public func prune(retentionDays: Int, now: Date = Date()) throws {
        guard [1, 3, 7].contains(retentionDays) else { throw ArchiveError.invalidRetention }
        let stmt = try statement("DELETE FROM records WHERE ts <= ?")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, now.timeIntervalSince1970 - Double(retentionDays) * 86400)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
        // Bound both payloads together. An OCR failure never exempts an image from expiry.
        while try payloadBytes() > budget {
            try exec("DELETE FROM records WHERE id = (SELECT id FROM records ORDER BY ts LIMIT 1)")
        }
    }
    public func payloadBytes() throws -> Int64 {
        let stmt = try statement("SELECT COALESCE(SUM(length(image)+length(CAST(text AS BLOB))),0) FROM records")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw failure() }
        return sqlite3_column_int64(stmt, 0)
    }
    public func count() throws -> Int {
        let stmt = try statement("SELECT COUNT(*) FROM records"); defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw failure() }
        return Int(sqlite3_column_int64(stmt, 0))
    }
    public func latest() throws -> Record? {
        let stmt = try statement("SELECT id, ts, text, image FROM records ORDER BY ts DESC LIMIT 1")
        defer { sqlite3_finalize(stmt) }
        let result = sqlite3_step(stmt)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW, let id = sqlite3_column_text(stmt, 0), let text = sqlite3_column_text(stmt, 2), let image = sqlite3_column_blob(stmt, 3) else { throw failure() }
        return Record(id: String(cString: id), timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)), text: String(decoding: UnsafeBufferPointer(start: text, count: Int(sqlite3_column_bytes(stmt, 2))), as: UTF8.self), image: Data(bytes: image, count: Int(sqlite3_column_bytes(stmt, 3))))
    }
    public func deleteAll() throws {
        // Owner stops the session first. No pending capture can repopulate the archive.
        guard sqlite3_close(db) == SQLITE_OK else { throw failure() }
        db = nil
        for name in ["archive.sqlite", "archive.sqlite-journal", "archive.sqlite-wal", "archive.sqlite-shm"] {
            let url = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        try open()
    }
}
