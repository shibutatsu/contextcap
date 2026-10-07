import XCTest
import SQLite3
@testable import CaptureCore

final class PrivacyTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("contextcap-test-" + UUID().uuidString)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    func testStoppedAndRestartedSessionsRejectLateResults() {
        var gate = RecordingGate()
        XCTAssertFalse(gate.accepts(gate.token))
        gate.start(); let old = gate.token
        XCTAssertTrue(gate.accepts(old))
        gate.stop(); XCTAssertFalse(gate.accepts(old))
        gate.start(); XCTAssertFalse(gate.accepts(old)); XCTAssertTrue(gate.accepts(gate.token))
    }
    func testPersistenceAndPermissions() throws {
        var archive: Archive? = try Archive(root: root)
        XCTAssertEqual(try archive!.count(), 0)
        try archive!.save(image: Data([1,2,3]), text: "日\0本語", at: Date(), retentionDays: 3)
        archive = nil
        let reopened = try Archive(root: root)
        XCTAssertEqual(try reopened.count(), 1)
        XCTAssertEqual(try reopened.latest()?.text, "日\0本語")
        XCTAssertEqual(try reopened.latest()?.image, Data([1,2,3]))
        XCTAssertEqual(try reopened.payloadBytes(), 13)
        for (url, mode) in [(root!, 0o700), (root.appendingPathComponent("archive.sqlite"), 0o600)] {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, mode)
        }
    }
    func testRetentionBoundaryDeletesBothPayloads() throws {
        let archive = try Archive(root: root)
        let now = Date()
        try archive.save(image: Data([42]), text: "expired", at: now.addingTimeInterval(-86400), retentionDays: 3, now: now)
        try archive.save(image: Data([43]), text: "retained", at: now, retentionDays: 3, now: now)
        try archive.prune(retentionDays: 1, now: now)
        XCTAssertEqual(try archive.count(), 1)
        XCTAssertEqual(try archive.latest()?.text, "retained")
        XCTAssertEqual(try archive.payloadBytes(), 9)
    }
    func testBudgetAndHundredRecords() throws {
        let archive = try Archive(root: root, budget: 300)
        let now = Date()
        for n in 0..<100 { try archive.save(image: Data([1]), text: "ab", at: now.addingTimeInterval(Double(n)-100), retentionDays: 1, now: now) }
        XCTAssertEqual(try archive.count(), 100)
        try archive.save(image: Data([2]), text: "cd", at: now, retentionDays: 1, now: now)
        XCTAssertEqual(try archive.count(), 100)
        XCTAssertEqual(try archive.payloadBytes(), 300)
        XCTAssertEqual(try archive.latest()?.text, "cd")
    }
    func testDeleteAllAndReopen() throws {
        let archive = try Archive(root: root)
        let marker = "PRIVATE-MARKER-123456789"
        try archive.save(image: Data(marker.utf8), text: marker, at: Date(), retentionDays: 3)
        try archive.deleteAll()
        XCTAssertEqual(try archive.count(), 0)
        XCTAssertNil(try archive.latest())
        let bytes = try Data(contentsOf: root.appendingPathComponent("archive.sqlite"))
        XCTAssertNil(bytes.range(of: Data(marker.utf8)))
        XCTAssertEqual(try Archive(root: root).count(), 0)
    }
    func testInvalidInputDoesNotSave() throws {
        let archive = try Archive(root: root)
        XCTAssertThrowsError(try archive.save(image: Data(), text: "x", at: Date(), retentionDays: 3))
        XCTAssertThrowsError(try archive.save(image: Data([1]), text: "x", at: Date(), retentionDays: 0))
        XCTAssertThrowsError(try archive.save(image: Data([1]), text: "x", at: Date().addingTimeInterval(1000), retentionDays: 3))
        XCTAssertThrowsError(try archive.prune(retentionDays: -1))
        XCTAssertEqual(try archive.count(), 0)
    }
    func testSymlinkRejected() throws {
        let target = root.appendingPathExtension("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: target) }
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: target)
        XCTAssertThrowsError(try Archive(root: root))
    }
    func testDatabaseLockFailsWithoutLosingExistingRecord() throws {
        let archive = try Archive(root: root)
        try archive.save(image: Data([1]), text: "existing", at: Date(), retentionDays: 3)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("archive.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil); sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try archive.save(image: Data([2]), text: "failed", at: Date(), retentionDays: 3))
        XCTAssertEqual(try archive.count(), 1)
        XCTAssertEqual(try archive.latest()?.text, "existing")
    }
}
