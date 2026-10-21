import Foundation

/// `OneSpace --headless-check <folder> <query> [db-path] [--search-only]`
/// `OneSpace --reindex-all`
/// `OneSpace --search "<query>"`
///
/// Runs the real indexer, index store, embedding client and search engine without a window,
/// prints the ranking, and exits. Uses a throwaway database unless `db-path` is given.
/// `--search-only` is honored only when a db path is given: skip indexing and rank what's stored.
/// `--reindex-all` indexes every saved folder into the real library database.
/// `--search` prints the top 5 titles and scores from that database.
/// Exit codes: 0 ok, 1 failure, 2 bad arguments.
enum HeadlessCheck {
    static func runIfRequested() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--add-folder"), i + 1 < args.count {
            // Verification helper: bookmark a folder from inside the app so the security scope is valid.
            do {
                let f = try BookmarkStore().add(url: URL(fileURLWithPath: args[i + 1]).standardizedFileURL)
                print("added folder: \(f.name)")
            } catch {
                FileHandle.standardError.write(Data("add-folder failed: \(error.localizedDescription)\n".utf8)); exit(1)
            }
            if !args.contains("--reindex-all") { exit(0) }
        }
        if args.contains("--reindex-all") || args.contains("--search") {
            runLibraryCommands(args)
        }
        guard let flag = args.firstIndex(of: "--headless-check") else { return }
        let rest = Array(args.dropFirst(flag + 1))
        guard rest.count >= 2 else {
            FileHandle.standardError.write(Data("usage: OneSpace --headless-check <folder> <query> [db-path] [--search-only]\n".utf8))
            exit(2)
        }
        let folder = URL(fileURLWithPath: rest[0]).standardizedFileURL
        let query = rest[1]
        let dbURL = rest.count >= 3
            ? URL(fileURLWithPath: rest[2])
            : FileManager.default.temporaryDirectory.appendingPathComponent("onespace-check-\(UUID().uuidString).sqlite")
        let searchOnly = rest.count >= 4 && rest[3] == "--search-only"

        let done = DispatchSemaphore(value: 0)
        let code = LockedBox<Int32>(1)
        Task.detached {
            code.value = await run(folder: folder, query: query, dbURL: dbURL, searchOnly: searchOnly)
            done.signal()
        }
        done.wait()
        exit(code.value)
    }

    private static func run(folder: URL, query: String, dbURL: URL, searchOnly: Bool) async -> Int32 {
        do {
            let client = EmbeddingClient()
            try await client.healthCheck()
            let model = try await client.serverModelID()
            let store = try IndexStore(databaseURL: dbURL)
            print("server model: \(model)")
            print("index db: \(dbURL.path) (previous model: \(try store.indexedModelID() ?? "none"), items: \(try store.itemCount()))")

            if !searchOnly {
                let vision = VisionClient()
                print("vision: \(await vision.isAvailable() ? "available" : "unavailable")")
                let indexer = FolderIndexer(embeddingClient: client, indexStore: store, visionClient: vision)
                let finalState = LockedBox(IndexProgress.idle)
                let firstError = LockedBox<String?>(nil)
                // Stable folder id derived from the path so re-runs on the same db update in place.
                let folderID = UUID(uuidString: stableUUID(folder.path)) ?? UUID()
                await indexer.index(targets: [IndexTarget(folderID: folderID, folderName: folder.lastPathComponent, rootURL: folder)]) { update in
                    finalState.value = update
                    if update.filesFailed > 0, let m = update.message, firstError.value == nil { firstError.value = m }
                    if update.staleItemsCleared > 0, update.phase == .scanning, update.message?.hasPrefix("Embedding model changed") == true {
                        print("model changed -> cleared \(update.staleItemsCleared) stale items before re-indexing")
                    }
                }
                let s = finalState.value
                print("index: phase=\(s.phase.rawValue) files=\(s.filesTotal) embedded=\(s.filesCompleted - s.filesSkipped - s.filesFailed) skipped=\(s.filesSkipped) failed=\(s.filesFailed) staleCleared=\(s.staleItemsCleared)")
                if let m = firstError.value { print("first failure: \(m)") }
                guard s.phase == .finished, s.filesFailed == 0 else { return 1 }
            }

            let items = try store.items()
            let dims = Set(items.compactMap { $0.embedding?.count })
            print("stored items: \(items.count), vector sizes: \(dims.sorted()), index model now: \(try store.indexedModelID() ?? "none")")
            for item in items {
                let dim = item.embedding?.count ?? 0
                let vision = item.visionDescribed.map { $0 ? "yes" : "no" } ?? "unset"
                print("item: \(item.relativePath) kind=\(item.kind.rawValue) chars=\(item.bodyText.count) dim=\(dim) vision=\(vision)")
            }

            let vector = try await client.embedQuery(query)
            print("query: \"\(query)\" -> \(vector.count)-number vector")
            let hits = SearchEngine.rank(query: query, queryEmbedding: vector, items: items, limit: 10)
            for (i, hit) in hits.enumerated() {
                print(String(format: "%2d. %.4f  %@  [%@]", i + 1, Double(hit.score), hit.item.relativePath, hit.item.kind.rawValue))
            }
            return hits.isEmpty ? 1 : 0
        } catch {
            print("headless check failed: \(error.localizedDescription)")
            return 1
        }
    }

    /// `--reindex-all` and/or `--search "query"`. Always exits.
    private static func runLibraryCommands(_ args: [String]) -> Never {
        let reindex = args.contains("--reindex-all")
        let wantsSearch = args.contains("--search")
        let query = searchQuery(in: args)
        if wantsSearch && query == nil {
            FileHandle.standardError.write(Data("usage: OneSpace --search \"query\"\n".utf8))
            exit(2)
        }
        let done = DispatchSemaphore(value: 0)
        let code = LockedBox<Int32>(1)
        Task.detached {
            var status: Int32 = 0
            if reindex {
                status = await reindexAll()
            }
            if status == 0, let query {
                status = await searchSaved(query)
            }
            code.value = status
            done.signal()
        }
        done.wait()
        exit(code.value)
    }

    /// Words after `--search`, stopping at the next flag.
    private static func searchQuery(in args: [String]) -> String? {
        guard let flag = args.firstIndex(of: "--search") else { return nil }
        var words: [String] = []
        var index = flag + 1
        while index < args.count {
            let word = args[index]
            if word.hasPrefix("--") { break }
            words.append(word)
            index += 1
        }
        let query = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? nil : query
    }

    private static func reindexAll() async -> Int32 {
        do {
            let bookmarks = BookmarkStore()
            let folders = bookmarks.folders
            print("saved folders: \(folders.count)")
            if folders.isEmpty {
                print("index: phase=finished files=0 embedded=0 skipped=0 failed=0 staleCleared=0")
                print("vision descriptions: 0")
                return 0
            }

            var accesses: [SecurityScopedAccess] = []
            defer { for access in accesses { access.stop() } }
            var targets: [IndexTarget] = []
            for folder in folders {
                do {
                    let access = try bookmarks.resolve(folder)
                    accesses.append(access)
                    targets.append(IndexTarget(
                        folderID: folder.id,
                        folderName: folder.name,
                        rootURL: access.url,
                        bookmarkData: folder.bookmarkData
                    ))
                } catch {
                    print("couldn't open \(folder.name): \(error.localizedDescription)")
                }
            }
            guard !targets.isEmpty else { return 1 }

            let client = EmbeddingClient()
            try await client.healthCheck()
            let store = try IndexStore()
            let vision = VisionClient()
            print("vision: \(await vision.isAvailable() ? "available" : "unavailable")")
            let indexer = FolderIndexer(embeddingClient: client, indexStore: store, visionClient: vision)
            let finalState = LockedBox(IndexProgress.idle)
            let firstError = LockedBox<String?>(nil)
            await indexer.index(targets: targets) { update in
                finalState.value = update
                if update.filesFailed > 0, let message = update.message, firstError.value == nil {
                    firstError.value = message
                }
                if update.staleItemsCleared > 0, update.phase == .scanning, update.message?.hasPrefix("Embedding model changed") == true {
                    print("model changed -> cleared \(update.staleItemsCleared) stale items before re-indexing")
                }
            }
            let state = finalState.value
            print("index: phase=\(state.phase.rawValue) files=\(state.filesTotal) embedded=\(state.filesCompleted - state.filesSkipped - state.filesFailed) skipped=\(state.filesSkipped) failed=\(state.filesFailed) staleCleared=\(state.staleItemsCleared)")
            if let message = firstError.value { print("first failure: \(message)") }
            let described = try store.items().filter { $0.visionDescribed == true }.count
            print("vision descriptions: \(described)")
            return state.phase == .finished && state.filesFailed == 0 ? 0 : 1
        } catch {
            print("reindex failed: \(error.localizedDescription)")
            return 1
        }
    }

    private static func searchSaved(_ query: String) async -> Int32 {
        do {
            let store = try IndexStore()
            let items = try store.items()
            let client = EmbeddingClient()
            var vector: [Float] = []
            do {
                try await client.healthCheck()
                if let model = try? await client.serverModelID(), try store.isStale(for: model) {
                    print("embedding model changed; keyword matches only until re-index")
                } else {
                    vector = try await client.embedQuery(query)
                }
            } catch {
                print("embedding server unavailable (\(error.localizedDescription)); keyword matches only")
            }
            let hits = SearchEngine.rank(query: query, queryEmbedding: vector, items: items, limit: 5)
            if hits.isEmpty {
                print("no results")
                return 1
            }
            for (index, hit) in hits.enumerated() {
                print(String(format: "%d. %.4f  %@", index + 1, Double(hit.score), hit.item.title))
            }
            return 0
        } catch {
            print("search failed: \(error.localizedDescription)")
            return 1
        }
    }

    private static func stableUUID(_ text: String) -> String {
        var h: UInt64 = 1469598103934665603
        var g: UInt64 = 1099511628211
        for b in text.utf8 { h = (h ^ UInt64(b)) &* 1099511628211; g = (g ^ UInt64(b)) &* 14695981039346656037 }
        let hex = String(format: "%016llx%016llx", h, g)
        let c = Array(hex)
        return "\(String(c[0..<8]))-\(String(c[8..<12]))-\(String(c[12..<16]))-\(String(c[16..<20]))-\(String(c[20..<32]))"
    }
}

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}
