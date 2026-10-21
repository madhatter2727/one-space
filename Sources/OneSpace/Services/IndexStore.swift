import Foundation
import SQLite3

/// SQLite index at `~/Library/Application Support/OneSpace/index.sqlite`.
///
/// Embeddings are stored as native little-endian float32 blobs. Access is serialized by the actor.
final class IndexStore: @unchecked Sendable {
    private let lock = NSLock()
    let databaseURL: URL

    private let box = SQLiteBox()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(databaseURL: URL? = nil) throws {
        let url = try databaseURL ?? Self.defaultDatabaseURL()
        self.databaseURL = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 \(rc)"
            if let handle { sqlite3_close(handle) }
            throw IndexStoreError.open(message)
        }
        box.handle = handle
        sqlite3_busy_timeout(handle, 3_000)
        try migrate()
    }

    static func defaultDatabaseURL() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupport
            .appending(path: "OneSpace", directoryHint: .isDirectory)
            .appending(path: "index.sqlite", directoryHint: .notDirectory)
    }

    // MARK: - Folders

    func upsertFolder(_ folder: FolderBookmark) throws {
        let sql = """
        INSERT INTO folders (id, display_name, bookmark_data, last_indexed)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            display_name = excluded.display_name,
            bookmark_data = excluded.bookmark_data,
            last_indexed = excluded.last_indexed
        """
        try run(sql) { stmt in
            try bind(text: folder.id, to: stmt, at: 1)
            try bind(text: folder.displayName, to: stmt, at: 2)
            try bind(blob: folder.bookmarkData, to: stmt, at: 3)
            try bind(date: folder.lastIndexed, to: stmt, at: 4)
        }
    }

    func folder(id: String) throws -> FolderBookmark? {
        try queryRows(
            "SELECT id, display_name, bookmark_data, last_indexed FROM folders WHERE id = ?",
            bind: { stmt in try bind(text: id, to: stmt, at: 1) },
            map: readFolder
        ).first
    }

    func folders() throws -> [FolderBookmark] {
        try queryRows(
            "SELECT id, display_name, bookmark_data, last_indexed FROM folders ORDER BY display_name COLLATE NOCASE",
            bind: { _ in },
            map: readFolder
        )
    }

    func updateFolderIndexed(id: String, at date: Date = Date()) throws {
        try run("UPDATE folders SET last_indexed = ? WHERE id = ?") { stmt in
            try bind(date: date, to: stmt, at: 1)
            try bind(text: id, to: stmt, at: 2)
        }
    }

    /// Deletes the folder and, via foreign key cascade, its items.
    func deleteFolder(id: String) throws {
        try run("DELETE FROM folders WHERE id = ?") { stmt in
            try bind(text: id, to: stmt, at: 1)
        }
    }

    // MARK: - Items

    func upsertItem(_ item: IndexedItem) throws {
        let sql = """
        INSERT INTO items (
            id, folder_id, relative_path, absolute_path, kind, title, snippet,
            mtime, size, content_hash, embedding_dim, embedding, body_text, vision_described
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            folder_id = excluded.folder_id,
            relative_path = excluded.relative_path,
            absolute_path = excluded.absolute_path,
            kind = excluded.kind,
            title = excluded.title,
            snippet = excluded.snippet,
            mtime = excluded.mtime,
            size = excluded.size,
            content_hash = excluded.content_hash,
            embedding_dim = excluded.embedding_dim,
            embedding = excluded.embedding,
            body_text = excluded.body_text,
            vision_described = excluded.vision_described
        """
        try run(sql) { stmt in
            try bindItem(item, to: stmt)
        }
    }

    func upsertItems(_ items: [IndexedItem]) throws {
        try transaction {
            for item in items {
                try upsertItem(item)
            }
        }
    }

    func updateEmbedding(itemId: String, embedding: [Float]) throws {
        try run("UPDATE items SET embedding = ?, embedding_dim = ? WHERE id = ?") { stmt in
            try bind(blob: Self.float32Blob(embedding), to: stmt, at: 1)
            try bind(int64: Int64(embedding.count), to: stmt, at: 2)
            try bind(text: itemId, to: stmt, at: 3)
        }
    }

    func item(id: String) throws -> IndexedItem? {
        try queryRows(
            "SELECT \(Self.itemColumns) FROM items WHERE id = ?",
            bind: { stmt in try bind(text: id, to: stmt, at: 1) },
            map: readItem
        ).first
    }

    func item(folderId: String, relativePath: String) throws -> IndexedItem? {
        try queryRows(
            "SELECT \(Self.itemColumns) FROM items WHERE folder_id = ? AND relative_path = ?",
            bind: { stmt in
                try bind(text: folderId, to: stmt, at: 1)
                try bind(text: relativePath, to: stmt, at: 2)
            },
            map: readItem
        ).first
    }

    func items(folderId: String) throws -> [IndexedItem] {
        try queryRows(
            "SELECT \(Self.itemColumns) FROM items WHERE folder_id = ? ORDER BY relative_path",
            bind: { stmt in try bind(text: folderId, to: stmt, at: 1) },
            map: readItem
        )
    }

    func items() throws -> [IndexedItem] {
        try queryRows(
            "SELECT \(Self.itemColumns) FROM items ORDER BY folder_id, relative_path",
            bind: { _ in },
            map: readItem
        )
    }

    func deleteItem(id: String) throws {
        try run("DELETE FROM items WHERE id = ?") { stmt in
            try bind(text: id, to: stmt, at: 1)
        }
    }

    func deleteItems(folderId: String) throws {
        try run("DELETE FROM items WHERE folder_id = ?") { stmt in
            try bind(text: folderId, to: stmt, at: 1)
        }
    }

    func removeAll() throws {
        try transaction {
            try exec("DELETE FROM items")
            try exec("DELETE FROM folders")
        }
    }

    // MARK: - Embedding model identity

    static let embeddingModelKey = "embedding_model"
    /// Stored with the model id so a schema change re-embeds existing installs.
    static let schemaVersion = "schema-3-documents"

    func metaValue(forKey key: String) throws -> String? {
        try queryRows(
            "SELECT value FROM meta WHERE key = ?",
            bind: { stmt in try bind(text: key, to: stmt, at: 1) },
            map: { stmt in columnText(stmt, 0) }
        ).first
    }

    func setMeta(_ value: String, forKey key: String) throws {
        try run("INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value") { stmt in
            try bind(text: key, to: stmt, at: 1)
            try bind(text: value, to: stmt, at: 2)
        }
    }

    func itemCount() throws -> Int {
        try queryRows("SELECT COUNT(*) FROM items", bind: { _ in }, map: { stmt in Int(sqlite3_column_int64(stmt, 0)) }).first ?? 0
    }

    /// The model that produced the stored vectors, or nil for an empty / pre-tracking index.
    func indexedModelID() throws -> String? {
        try metaValue(forKey: Self.embeddingModelKey)
    }

    /// Model id plus schema version. Existing installs stored the bare model id, so they count as stale.
    private func identity(for modelID: String) -> String {
        "\(modelID)|\(Self.schemaVersion)"
    }

    /// True when stored vectors came from a different model or schema (or an untracked older index) than `modelID`.
    /// An empty index is not stale.
    func isStale(for modelID: String) throws -> Bool {
        guard try itemCount() > 0 else { return false }
        return try indexedModelID() != identity(for: modelID)
    }

    /// Makes the index belong to `modelID` and the current schema. If vectors from another model,
    /// another schema, or an untracked older index are stored, every item is deleted so the next
    /// index run re-embeds from scratch. Folders are kept. Returns the number of stale items removed.
    @discardableResult
    func adoptModel(_ modelID: String) throws -> Int {
        var removed = 0
        let nextIdentity = identity(for: modelID)
        try transaction {
            let count = try itemCount()
            let stored = try indexedModelID()
            if count > 0 && stored != nextIdentity {
                removed = count
                try exec("DELETE FROM items")
            }
            try setMeta(nextIdentity, forKey: Self.embeddingModelKey)
        }
        return removed
    }

    // MARK: - Schema

    private static let itemColumns = """
    id, folder_id, relative_path, absolute_path, kind, title, snippet, mtime, size, content_hash, embedding_dim, embedding, body_text, vision_described
    """

    private func migrate() throws {
        try exec("PRAGMA foreign_keys = ON")
        try exec("PRAGMA journal_mode = WAL")
        try exec(
            """
            CREATE TABLE IF NOT EXISTS folders (
                id TEXT PRIMARY KEY NOT NULL,
                display_name TEXT NOT NULL,
                bookmark_data BLOB NOT NULL,
                last_indexed REAL
            )
            """
        )
        try exec(
            """
            CREATE TABLE IF NOT EXISTS items (
                id TEXT PRIMARY KEY NOT NULL,
                folder_id TEXT NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
                relative_path TEXT NOT NULL,
                absolute_path TEXT NOT NULL,
                kind TEXT NOT NULL,
                title TEXT NOT NULL,
                snippet TEXT NOT NULL,
                mtime REAL NOT NULL,
                size INTEGER NOT NULL,
                content_hash TEXT NOT NULL,
                embedding_dim INTEGER,
                embedding BLOB,
                body_text TEXT NOT NULL DEFAULT '',
                vision_described INTEGER
            )
            """
        )
        let columnNames = try queryRows("PRAGMA table_info(items)", bind: { _ in }, map: { stmt in
            columnText(stmt, 1)
        })
        if !columnNames.contains("body_text") {
            try exec("ALTER TABLE items ADD COLUMN body_text TEXT NOT NULL DEFAULT ''")
        }
        if !columnNames.contains("vision_described") {
            // Nullable so filename-only rows from older builds stay and get described later.
            try exec("ALTER TABLE items ADD COLUMN vision_described INTEGER")
        }
        try exec("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)")
        try exec("CREATE INDEX IF NOT EXISTS idx_items_folder ON items(folder_id)")
        try exec("CREATE INDEX IF NOT EXISTS idx_items_folder_path ON items(folder_id, relative_path)")
    }

    // MARK: - SQLite helpers

    private func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func exec(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(box.handle, sql, nil, nil, &errorPointer)
        guard rc == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? errMsg()
            sqlite3_free(errorPointer)
            throw IndexStoreError.sqlite(message)
        }
    }

    private func run(_ sql: String, bind: (OpaquePointer) throws -> Void) throws {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bind(stmt)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else {
            throw IndexStoreError.sqlite(errMsg())
        }
    }

    private func queryRows<T>(
        _ sql: String,
        bind: (OpaquePointer) throws -> Void,
        map: (OpaquePointer) throws -> T
    ) throws -> [T] {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bind(stmt)
        var rows: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                rows.append(try map(stmt))
            } else if rc == SQLITE_DONE {
                return rows
            } else {
                throw IndexStoreError.sqlite(errMsg())
            }
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(box.handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw IndexStoreError.sqlite(errMsg())
        }
        return stmt
    }

    private func errMsg() -> String {
        guard let handle = box.handle else { return "index database is closed" }
        return String(cString: sqlite3_errmsg(handle))
    }

    private func bind(text: String, to stmt: OpaquePointer, at index: Int32) throws {
        let rc = text.withCString { sqlite3_bind_text(stmt, index, $0, -1, transient) }
        guard rc == SQLITE_OK else { throw IndexStoreError.sqlite("bind text: \(errMsg())") }
    }

    private func bind(blob: Data, to stmt: OpaquePointer, at index: Int32) throws {
        let rc: Int32 = blob.withUnsafeBytes { raw in
            sqlite3_bind_blob(stmt, index, raw.baseAddress, Int32(blob.count), transient)
        }
        guard rc == SQLITE_OK else { throw IndexStoreError.sqlite("bind blob: \(errMsg())") }
    }

    private func bind(date: Date?, to stmt: OpaquePointer, at index: Int32) throws {
        if let date {
            let rc = sqlite3_bind_double(stmt, index, date.timeIntervalSince1970)
            guard rc == SQLITE_OK else { throw IndexStoreError.sqlite("bind date: \(errMsg())") }
        } else {
            let rc = sqlite3_bind_null(stmt, index)
            guard rc == SQLITE_OK else { throw IndexStoreError.sqlite("bind null: \(errMsg())") }
        }
    }

    private func bind(int64: Int64, to stmt: OpaquePointer, at index: Int32) throws {
        let rc = sqlite3_bind_int64(stmt, index, int64)
        guard rc == SQLITE_OK else { throw IndexStoreError.sqlite("bind int: \(errMsg())") }
    }

    private func bindItem(_ item: IndexedItem, to stmt: OpaquePointer) throws {
        let embedding = item.embedding
        let dim = embedding?.count ?? item.embeddingDim
        try bind(text: item.id, to: stmt, at: 1)
        try bind(text: item.folderId, to: stmt, at: 2)
        try bind(text: item.relativePath, to: stmt, at: 3)
        try bind(text: item.absolutePath, to: stmt, at: 4)
        try bind(text: item.kind.rawValue, to: stmt, at: 5)
        try bind(text: item.title, to: stmt, at: 6)
        try bind(text: item.snippet, to: stmt, at: 7)
        try bind(date: item.mtime, to: stmt, at: 8)
        try bind(int64: item.size, to: stmt, at: 9)
        try bind(text: item.contentHash, to: stmt, at: 10)
        if let embedding {
            try bind(int64: Int64(dim), to: stmt, at: 11)
            try bind(blob: Self.float32Blob(embedding), to: stmt, at: 12)
        } else if item.embeddingDim > 0 {
            try bind(int64: Int64(item.embeddingDim), to: stmt, at: 11)
            let rc = sqlite3_bind_null(stmt, 12)
            guard rc == SQLITE_OK else { throw IndexStoreError.sqlite(errMsg()) }
        } else {
            let dimRC = sqlite3_bind_null(stmt, 11)
            let blobRC = sqlite3_bind_null(stmt, 12)
            guard dimRC == SQLITE_OK, blobRC == SQLITE_OK else {
                throw IndexStoreError.sqlite(errMsg())
            }
        }
        try bind(text: item.bodyText, to: stmt, at: 13)
        if let visionDescribed = item.visionDescribed {
            try bind(int64: visionDescribed ? 1 : 0, to: stmt, at: 14)
        } else {
            let rc = sqlite3_bind_null(stmt, 14)
            guard rc == SQLITE_OK else { throw IndexStoreError.sqlite(errMsg()) }
        }
    }

    private func readFolder(_ stmt: OpaquePointer) throws -> FolderBookmark {
        guard let bookmark = columnBlob(stmt, 2) else {
            throw IndexStoreError.sqlite("folder \(columnText(stmt, 0)) is missing bookmark data")
        }
        return FolderBookmark(
            id: columnText(stmt, 0),
            displayName: columnText(stmt, 1),
            bookmarkData: bookmark,
            lastIndexed: columnDate(stmt, 3)
        )
    }

    private func readItem(_ stmt: OpaquePointer) throws -> IndexedItem {
        let kindRaw = columnText(stmt, 4)
        guard let kind = ItemKind(rawValue: kindRaw) else {
            throw IndexStoreError.sqlite("unknown item kind '\(kindRaw)'")
        }
        let embedding = columnEmbedding(stmt, 11)
        let storedDim = sqlite3_column_type(stmt, 10) == SQLITE_NULL ? 0 : Int(sqlite3_column_int(stmt, 10))
        let visionDescribed: Bool?
        if sqlite3_column_type(stmt, 13) == SQLITE_NULL {
            visionDescribed = nil
        } else {
            visionDescribed = sqlite3_column_int(stmt, 13) != 0
        }
        return IndexedItem(
            id: columnText(stmt, 0),
            folderId: columnText(stmt, 1),
            relativePath: columnText(stmt, 2),
            absolutePath: columnText(stmt, 3),
            kind: kind,
            title: columnText(stmt, 5),
            snippet: columnText(stmt, 6),
            bodyText: columnText(stmt, 12),
            mtime: columnDate(stmt, 7) ?? Date(timeIntervalSince1970: 0),
            size: sqlite3_column_int64(stmt, 8),
            contentHash: columnText(stmt, 9),
            embeddingDim: storedDim,
            embedding: embedding,
            visionDescribed: visionDescribed
        )
    }

    private func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String {
        guard let raw = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: raw)
    }

    private func columnDate(_ stmt: OpaquePointer, _ index: Int32) -> Date? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(stmt, index))
    }

    private func columnBlob(_ stmt: OpaquePointer, _ index: Int32) -> Data? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, index))
        guard count > 0, let pointer = sqlite3_column_blob(stmt, index) else { return nil }
        return Data(bytes: pointer, count: count)
    }

    /// Copies the blob into `[Float]`. The SQLite pointer is not assumed to be float-aligned.
    private func columnEmbedding(_ stmt: OpaquePointer, _ index: Int32) -> [Float]? {
        guard let data = columnBlob(stmt, index) else { return nil }
        let width = MemoryLayout<Float>.size
        guard data.count >= width, data.count % width == 0 else { return nil }
        var floats = [Float](repeating: 0, count: data.count / width)
        _ = floats.withUnsafeMutableBytes { destination in
            data.copyBytes(to: destination)
        }
        return floats
    }

    private static func float32Blob(_ values: [Float]) -> Data {
        let copy = values
        return copy.withUnsafeBytes { Data($0) }
    }
}

enum IndexStoreError: Error, Sendable, LocalizedError {
    case open(String)
    case sqlite(String)

    var errorDescription: String? {
        switch self {
        case .open(let message):
            return "Unable to open OneSpace index: \(message)"
        case .sqlite(let message):
            return message
        }
    }
}

private final class SQLiteBox: @unchecked Sendable {
    var handle: OpaquePointer?

    deinit {
        if let handle {
            sqlite3_close_v2(handle)
        }
    }
}
