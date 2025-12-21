import Foundation
import SQLite3

/// Represents a sync record for a calendar event
struct SyncRecord: Codable {
    let macEventID: String
    let googleEventID: String
    var lastSyncedAt: Date
    var macLastModified: Date
    var sourceCalendar: String

    enum CodingKeys: String, CodingKey {
        case macEventID = "mac_event_id"
        case googleEventID = "google_event_id"
        case lastSyncedAt = "last_synced_at"
        case macLastModified = "mac_last_modified"
        case sourceCalendar = "source_calendar"
    }
}

/// Local database for managing sync state using SQLite
class SyncDatabase {
    private let dbFileName = "sync_database.db"
    private let legacyJSONFileName = "sync_database.json"
    private var db: OpaquePointer?
    private let fileURL: URL
    private let legacyJSONURL: URL

    init() {
        let currentDir = FileManager.default.currentDirectoryPath
        fileURL = URL(fileURLWithPath: currentDir).appendingPathComponent(dbFileName)
        legacyJSONURL = URL(fileURLWithPath: currentDir).appendingPathComponent(legacyJSONFileName)

        openDatabase()
        createTableIfNeeded()
        migrateFromJSONIfNeeded()
    }

    deinit {
        closeDatabase()
    }

    // MARK: - Database Setup

    private func openDatabase() {
        if sqlite3_open(fileURL.path, &db) != SQLITE_OK {
            print("Error opening database")
            return
        }
        print("SQLite database opened at: \(fileURL.path)")
    }

    private func closeDatabase() {
        if sqlite3_close(db) != SQLITE_OK {
            print("Error closing database")
        }
        db = nil
    }

    private func createTableIfNeeded() {
        let createTableQuery = """
        CREATE TABLE IF NOT EXISTS sync_records (
            mac_event_id TEXT PRIMARY KEY,
            google_event_id TEXT NOT NULL,
            last_synced_at TEXT NOT NULL,
            mac_last_modified TEXT NOT NULL,
            source_calendar TEXT NOT NULL,
            created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
        );

        CREATE INDEX IF NOT EXISTS idx_google_event_id ON sync_records(google_event_id);
        CREATE INDEX IF NOT EXISTS idx_source_calendar ON sync_records(source_calendar);
        CREATE INDEX IF NOT EXISTS idx_last_synced_at ON sync_records(last_synced_at);
        """

        if sqlite3_exec(db, createTableQuery, nil, nil, nil) != SQLITE_OK {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            print("Error creating table: \(errorMessage)")
        } else {
            print("Sync records table ready")
        }
    }

    // MARK: - Migration from JSON

    private func migrateFromJSONIfNeeded() {
        // Check if JSON file exists
        guard FileManager.default.fileExists(atPath: legacyJSONURL.path) else {
            return
        }

        // Check if we've already migrated (if DB has any records, skip migration)
        let countQuery = "SELECT COUNT(*) FROM sync_records;"
        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, countQuery, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_ROW {
                let count = sqlite3_column_int(statement, 0)
                if count > 0 {
                    sqlite3_finalize(statement)
                    print("Database already has \(count) records, skipping JSON migration")
                    return
                }
            }
        }
        sqlite3_finalize(statement)

        print("Found legacy JSON database, migrating to SQLite...")

        // Load JSON data
        guard let data = try? Data(contentsOf: legacyJSONURL) else {
            print("Could not read JSON file")
            return
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let records = try decoder.decode([SyncRecord].self, from: data)

            print("Migrating \(records.count) records from JSON to SQLite...")

            // Insert all records
            for record in records {
                upsertRecord(
                    macEventID: record.macEventID,
                    googleEventID: record.googleEventID,
                    macLastModified: record.macLastModified,
                    sourceCalendar: record.sourceCalendar
                )
            }

            print("Migration complete! Migrated \(records.count) records")

            // Rename old JSON file to keep as backup
            let backupURL = legacyJSONURL.deletingPathExtension().appendingPathExtension("json.backup")
            try? FileManager.default.moveItem(at: legacyJSONURL, to: backupURL)
            print("Legacy JSON file backed up to: \(backupURL.lastPathComponent)")

        } catch {
            print("Failed to migrate JSON data: \(error)")
        }
    }

    // MARK: - Query Operations

    /// Check if a Mac event has been synced
    func isSynced(macEventID: String) -> Bool {
        return getRecord(macEventID: macEventID) != nil
    }

    /// Get sync record for a Mac event
    func getRecord(macEventID: String) -> SyncRecord? {
        let query = """
        SELECT mac_event_id, google_event_id, last_synced_at, mac_last_modified, source_calendar
        FROM sync_records
        WHERE mac_event_id = ?;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }

        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, (macEventID as NSString).utf8String, -1, nil)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return extractRecord(from: statement)
    }

    /// Get Mac event ID from Google event ID
    func getMacEventID(googleEventID: String) -> String? {
        let query = "SELECT mac_event_id FROM sync_records WHERE google_event_id = ?;"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }

        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, (googleEventID as NSString).utf8String, -1, nil)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return String(cString: sqlite3_column_text(statement, 0))
    }

    /// Get all sync records
    func getAllRecords() -> [SyncRecord] {
        let query = """
        SELECT mac_event_id, google_event_id, last_synced_at, mac_last_modified, source_calendar
        FROM sync_records
        ORDER BY last_synced_at DESC;
        """

        return executeQuery(query)
    }

    /// Get records for specific calendar
    func getRecords(forCalendar calendar: String) -> [SyncRecord] {
        let query = """
        SELECT mac_event_id, google_event_id, last_synced_at, mac_last_modified, source_calendar
        FROM sync_records
        WHERE source_calendar = ?
        ORDER BY last_synced_at DESC;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            return []
        }

        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, (calendar as NSString).utf8String, -1, nil)

        var records: [SyncRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let record = extractRecord(from: statement) {
                records.append(record)
            }
        }

        return records
    }

    // MARK: - Mutation Operations

    /// Add or update a sync record
    func upsertRecord(
        macEventID: String,
        googleEventID: String,
        macLastModified: Date,
        sourceCalendar: String
    ) {
        let query = """
        INSERT INTO sync_records (mac_event_id, google_event_id, last_synced_at, mac_last_modified, source_calendar)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(mac_event_id) DO UPDATE SET
            google_event_id = excluded.google_event_id,
            last_synced_at = excluded.last_synced_at,
            mac_last_modified = excluded.mac_last_modified,
            source_calendar = excluded.source_calendar;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            print("Error preparing upsert: \(errorMessage)")
            return
        }

        defer { sqlite3_finalize(statement) }

        let now = ISO8601DateFormatter().string(from: Date())
        let modifiedStr = ISO8601DateFormatter().string(from: macLastModified)

        sqlite3_bind_text(statement, 1, (macEventID as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, (googleEventID as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 3, (now as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 4, (modifiedStr as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 5, (sourceCalendar as NSString).utf8String, -1, nil)

        if sqlite3_step(statement) != SQLITE_DONE {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            print("Error executing upsert: \(errorMessage)")
        }
    }

    /// Update last synced time
    func updateLastSynced(macEventID: String, macLastModified: Date) {
        let query = """
        UPDATE sync_records
        SET last_synced_at = ?, mac_last_modified = ?
        WHERE mac_event_id = ?;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            return
        }

        defer { sqlite3_finalize(statement) }

        let now = ISO8601DateFormatter().string(from: Date())
        let modifiedStr = ISO8601DateFormatter().string(from: macLastModified)

        sqlite3_bind_text(statement, 1, (now as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, (modifiedStr as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 3, (macEventID as NSString).utf8String, -1, nil)

        sqlite3_step(statement)
    }

    /// Remove a sync record (when event is deleted)
    func removeRecord(macEventID: String) {
        let query = "DELETE FROM sync_records WHERE mac_event_id = ?;"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            return
        }

        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, (macEventID as NSString).utf8String, -1, nil)
        sqlite3_step(statement)
    }

    /// Clear all records (for testing/reset)
    func clearAll() {
        let query = "DELETE FROM sync_records;"
        sqlite3_exec(db, query, nil, nil, nil)
        print("All sync records cleared")
    }

    /// Clean up old records (events older than specified date and not in Mac calendar)
    func cleanupOldRecords(olderThan date: Date) {
        let dateStr = ISO8601DateFormatter().string(from: date)
        let query = """
        DELETE FROM sync_records
        WHERE mac_last_modified < ?;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            return
        }

        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, (dateStr as NSString).utf8String, -1, nil)

        if sqlite3_step(statement) == SQLITE_DONE {
            let deletedCount = sqlite3_changes(db)
            if deletedCount > 0 {
                print("Cleaned up \(deletedCount) old sync records")
            }
        }
    }

    // MARK: - Statistics

    /// Get sync statistics
    func getStatistics() -> (totalRecords: Int, byCalendar: [String: Int]) {
        var totalRecords = 0
        var byCalendar: [String: Int] = [:]

        // Get total count
        let countQuery = "SELECT COUNT(*) FROM sync_records;"
        var countStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, countQuery, -1, &countStatement, nil) == SQLITE_OK {
            if sqlite3_step(countStatement) == SQLITE_ROW {
                totalRecords = Int(sqlite3_column_int(countStatement, 0))
            }
        }
        sqlite3_finalize(countStatement)

        // Get count by calendar
        let calendarQuery = "SELECT source_calendar, COUNT(*) FROM sync_records GROUP BY source_calendar;"
        var calendarStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, calendarQuery, -1, &calendarStatement, nil) == SQLITE_OK {
            while sqlite3_step(calendarStatement) == SQLITE_ROW {
                let calendar = String(cString: sqlite3_column_text(calendarStatement, 0))
                let count = Int(sqlite3_column_int(calendarStatement, 1))
                byCalendar[calendar] = count
            }
        }
        sqlite3_finalize(calendarStatement)

        return (totalRecords, byCalendar)
    }

    // MARK: - Helper Methods

    private func executeQuery(_ query: String) -> [SyncRecord] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            return []
        }

        defer { sqlite3_finalize(statement) }

        var records: [SyncRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let record = extractRecord(from: statement) {
                records.append(record)
            }
        }

        return records
    }

    private func extractRecord(from statement: OpaquePointer?) -> SyncRecord? {
        guard let statement = statement else { return nil }

        let macEventID = String(cString: sqlite3_column_text(statement, 0))
        let googleEventID = String(cString: sqlite3_column_text(statement, 1))
        let lastSyncedAtStr = String(cString: sqlite3_column_text(statement, 2))
        let macLastModifiedStr = String(cString: sqlite3_column_text(statement, 3))
        let sourceCalendar = String(cString: sqlite3_column_text(statement, 4))

        let formatter = ISO8601DateFormatter()
        guard let lastSyncedAt = formatter.date(from: lastSyncedAtStr),
              let macLastModified = formatter.date(from: macLastModifiedStr) else {
            return nil
        }

        return SyncRecord(
            macEventID: macEventID,
            googleEventID: googleEventID,
            lastSyncedAt: lastSyncedAt,
            macLastModified: macLastModified,
            sourceCalendar: sourceCalendar
        )
    }
}
