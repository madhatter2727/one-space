import Foundation

/// Application Support root shared by OneSpace persistence.
enum OneSpaceSupport {
    static func directory() throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = root.appendingPathComponent("OneSpace", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// A user-chosen folder, persisted as a security-scoped bookmark.
struct BookmarkedFolder: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: UUID
    var name: String
    var bookmarkData: Data
    var addedAt: Date
}

enum BookmarkStoreError: LocalizedError, Equatable {
    case bookmarkFailed(String)
    case resolveFailed(String)
    case notAFolder(String)
    case storageUnavailable

    var errorDescription: String? {
        switch self {
        case .bookmarkFailed(let name):
            return "Couldn't bookmark \(name)."
        case .resolveFailed(let name):
            return "Couldn't open \(name). Choose the folder again to restore access."
        case .notAFolder(let name):
            return "\(name) is not a folder."
        case .storageUnavailable:
            return "Application Support isn't available."
        }
    }
}

/// Live access to a resolved security-scoped folder URL.
/// `stop()` is balanced with `startAccessingSecurityScopedResource` and is safe to call more than once.
final class SecurityScopedAccess: @unchecked Sendable {
    let url: URL
    private let started: Bool
    private let lock = NSLock()
    private var stopped = false

    init(url: URL, started: Bool) {
        self.url = url
        self.started = started
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard started, !stopped else { return }
        stopped = true
        url.stopAccessingSecurityScopedResource()
    }

    deinit {
        stop()
    }
}

/// Persists security-scoped folder bookmarks as JSON in Application Support.
final class BookmarkStore: @unchecked Sendable {
    private let lock = NSLock()
    private var foldersStorage: [BookmarkedFolder] = []
    private let fileURL: URL?

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init() {
        let url = try? OneSpaceSupport.directory().appendingPathComponent("bookmarks.json")
        fileURL = url
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            foldersStorage = try Self.decoder.decode([BookmarkedFolder].self, from: data)
        } catch {
            let bad = url.deletingLastPathComponent().appendingPathComponent("bookmarks.json.bad")
            try? FileManager.default.removeItem(at: bad)
            try? FileManager.default.moveItem(at: url, to: bad)
            foldersStorage = []
        }
    }

    var folders: [BookmarkedFolder] {
        snapshot()
    }

    /// Creates a security-scoped bookmark for `url` and stores it. Returns the existing record when the folder is already saved.
    @discardableResult
    func add(url: URL) throws -> BookmarkedFolder {
        let started = url.startAccessingSecurityScopedResource()
        defer {
            if started { url.stopAccessingSecurityScopedResource() }
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw BookmarkStoreError.notAFolder(url.lastPathComponent)
        }

        let canonical = url.standardizedFileURL.resolvingSymlinksInPath().path
        for existing in snapshot() {
            if let access = try? resolve(existing) {
                defer { access.stop() }
                if access.url.standardizedFileURL.resolvingSymlinksInPath().path == canonical {
                    return existing
                }
            }
        }

        let data: Data
        do {
            data = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw BookmarkStoreError.bookmarkFailed(url.lastPathComponent)
        }

        let folder = BookmarkedFolder(
            id: UUID(),
            name: url.lastPathComponent,
            bookmarkData: data,
            addedAt: Date()
        )
        var next = snapshot()
        next.append(folder)
        try write(next)
        replace(next)
        return folder
    }

    func remove(id: UUID) {
        var next = snapshot()
        next.removeAll { $0.id == id }
        replace(next)
        try? write(next)
    }

    /// Resolves the bookmark and calls `startAccessingSecurityScopedResource`.
    /// Caller must `stop()` the returned access (or let it deinit).
    func resolve(_ folder: BookmarkedFolder) throws -> SecurityScopedAccess {
        var isStale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: folder.bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw BookmarkStoreError.resolveFailed(folder.name)
        }

        let started = url.startAccessingSecurityScopedResource()
        var isDir: ObjCBool = false
        let readable = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        guard readable else {
            if started { url.stopAccessingSecurityScopedResource() }
            throw BookmarkStoreError.resolveFailed(folder.name)
        }

        if isStale,
           let data = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
           ) {
            updateBookmark(id: folder.id, data: data)
        }

        return SecurityScopedAccess(url: url, started: started)
    }

    private func updateBookmark(id: UUID, data: Data) {
        var next = snapshot()
        guard let index = next.firstIndex(where: { $0.id == id }) else { return }
        next[index].bookmarkData = data
        guard (try? write(next)) != nil else { return }
        replace(next)
    }

    private func snapshot() -> [BookmarkedFolder] {
        lock.lock()
        defer { lock.unlock() }
        return foldersStorage
    }

    private func replace(_ folders: [BookmarkedFolder]) {
        lock.lock()
        foldersStorage = folders
        lock.unlock()
    }

    private func write(_ folders: [BookmarkedFolder]) throws {
        guard let fileURL else { throw BookmarkStoreError.storageUnavailable }
        let data = try Self.encoder.encode(folders)
        try data.write(to: fileURL, options: .atomic)
    }
}
