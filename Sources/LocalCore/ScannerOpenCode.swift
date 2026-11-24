import Foundation
import SQLite3

extension UsageScanner {
    /// Rows are appended in rowid order and updated when the call finishes, so a read walks
    /// forward from the last rowid minus this overlap to catch later updates.
    static let overlapRows: Int64 = 2000

    /// `inode:size:mtime` with the mtime in whole nanoseconds, so a rewrite shows up even when the
    /// size and the second are the same.
    static func stamp(_ st: Darwin.stat) -> String {
        // A modification time far in the future (or a corrupt one) must not overflow the nanosecond count.
        let (scaled, overflow) = Int64(st.st_mtimespec.tv_sec).multipliedReportingOverflow(by: 1_000_000_000)
        let nanos = overflow ? Int64.max : TokenCounts.saturatingSum(scaled, Int64(st.st_mtimespec.tv_nsec))
        return "\(st.st_ino):\(st.st_size):\(nanos)"
    }

    func readOpenCode(db path: String, prefix: String, _ stat: inout SourceStat) throws {
        if Self.isSpecialPath(path) { return }
        guard let mainInfo = Self.fileInfo(path) else { return }

        // Each file on its own: a sum of two mtimes is the same for different pairs.
        let stamp = Self.stamp(mainInfo) + "|" + (Self.fileInfo(ExternalDB.resolvedPath(path) + "-wal").map(Self.stamp) ?? "-")
        let stampKey = "dbstamp:" + path
        if store.meta(stampKey) == stamp { return }

        let watermarkKey = "watermark:" + path
        let inodeKey = "dbinode:" + path
        var watermark = Int64(store.meta(watermarkKey) ?? "") ?? 0
        let db = try ExternalDB(path: path, immutable: false)

        // A database that was deleted and made again (another file under the same name) or emptied counts its rows from
        // 1 again: reading on from the old watermark would skip every new call until the rowids caught up. The index
        // keeps what it has (keys dedup), so starting over only reads the rows again.
        let inode = String(mainInfo.st_ino)
        var newest: Int64 = 0
        try db.query("SELECT COALESCE(MAX(rowid), 0) FROM message") { row in newest = sqlite3_column_int64(row, 0) }
        if let known = store.meta(inodeKey), known != inode { watermark = 0 }
        if newest < watermark { watermark = 0 }

        var lastRowId = watermark
        var events: [UsageEvent] = []

        let sql = """
        SELECT m.rowid, m.id, m.session_id, m.data, s.directory
        FROM message m LEFT JOIN session s ON s.id = m.session_id
        WHERE m.rowid > ? ORDER BY m.rowid
        """
        let startRowId = max(0, watermark - Self.overlapRows)

        try db.query(sql, bind: [startRowId]) { row in
            if let rowIdText = ExternalDB.text(row, 0), let rowId = Int64(rowIdText) {
                lastRowId = max(lastRowId, rowId)
            }
            guard let id = ExternalDB.text(row, 1),
                  let json = ExternalDB.text(row, 3) else { return }

            let session = ExternalDB.text(row, 2) ?? ""
            let directory = ExternalDB.text(row, 4)
            if let event = OpenCodeParser.event(prefix: prefix, id: id, session: session,
                                                directory: directory, json: json, file: path) {
                events.append(event)
            }
        }

        try store.insertEvents(events)
        try store.setMeta(watermarkKey, String(lastRowId))
        try store.setMeta(inodeKey, inode)
        try store.setMeta(stampKey, stamp)
        stat.filesRead += 1
        stat.events += events.count
    }
}
