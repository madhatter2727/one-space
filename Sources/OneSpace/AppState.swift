import AppKit
import Combine
import Foundation

enum EmbeddingStatus: Equatable, Sendable {
    case unknown
    case checking
    case ready
    case unavailable(String)
}

/// App-wide state for folders, the index, embedding health, and search.
@MainActor
final class AppState: ObservableObject {
    @Published private(set) var folders: [BookmarkedFolder] = []
    @Published private(set) var items: [IndexedItem] = []
    @Published private(set) var embeddingStatus: EmbeddingStatus = .unknown
    @Published private(set) var indexProgress: IndexProgress = .idle
    @Published var searchQuery: String = ""
    @Published private(set) var searchResults: [SearchResult] = []
    @Published private(set) var lastError: String?
    @Published private(set) var storeReady: Bool = false
    /// Model id reported by the embedding server (e.g. `embeddinggemma2`).
    @Published private(set) var serverModelID: String?

    let bookmarkStore: BookmarkStore
    let indexStore: IndexStore
    let embeddingClient: EmbeddingClient
    let searchEngine: SearchEngine
    let folderIndexer: FolderIndexer
    let thumbnailCache: ThumbnailCache

    private var scopedRoots: [UUID: SecurityScopedAccess] = [:]
    private var indexTask: Task<Void, Never>?
    /// A folder was added while a pass was running. Start another pass when this one ends.
    private var indexAgainWhenDone = false
    /// Cancel stays cancelled for this launch. The next launch can auto-index again.
    private var suppressAutoIndex = false
    private static let keywordOnlyNote = "Only exact-word matching is available until the local model is running."
    private var searchTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private let searchLimit = 40
    private let healthInterval: UInt64 = 15_000_000_000

    init(
        bookmarkStore: BookmarkStore = BookmarkStore(),
        embeddingClient: EmbeddingClient = EmbeddingClient(),
        searchEngine: SearchEngine = SearchEngine(resultLimit: 40),
        thumbnailCache: ThumbnailCache = ThumbnailCache()
    ) {
        self.bookmarkStore = bookmarkStore
        self.embeddingClient = embeddingClient
        self.searchEngine = searchEngine
        self.thumbnailCache = thumbnailCache

        do {
            let store = try IndexStore()
            self.indexStore = store
            self.folderIndexer = FolderIndexer(embeddingClient: embeddingClient, indexStore: store)
            self.storeReady = true
        } catch {
            // Fall back to a temp DB so the UI still opens.
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("OneSpace-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            let fallbackURL = temp.appendingPathComponent("index.sqlite")
            // IndexStore.init always throws or succeeds — use try!
            let store = try! IndexStore(databaseURL: fallbackURL)
            self.indexStore = store
            self.folderIndexer = FolderIndexer(embeddingClient: embeddingClient, indexStore: store)
            self.lastError = "Using a temporary index: \(error.localizedDescription)"
            self.storeReady = true
        }

        folders = bookmarkStore.folders
        activateAccess()
        Task { await reloadItems() }
        startHealthLoop()
    }

    /// Presents `NSOpenPanel` for one or more folders and stores security-scoped bookmarks.
    func addFolder() {
        let panel = NSOpenPanel()
        panel.title = "Add Folder"
        panel.prompt = "Add"
        panel.message = "Choose folders for One Space to index."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK else { return }

        var addedCount = 0
        var errors: [String] = []
        for url in panel.urls {
            do {
                _ = try bookmarkStore.add(url: url)
                addedCount += 1
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        folders = bookmarkStore.folders
        activateAccess()
        lastError = errors.isEmpty ? nil : errors.joined(separator: " ")
        if addedCount > 0, embeddingStatus == .ready {
            if indexTask != nil {
                indexAgainWhenDone = true
            } else {
                startIndexing()
            }
        }
    }

    func removeFolder(id: UUID) {
        scopedRoots[id]?.stop()
        scopedRoots[id] = nil
        bookmarkStore.remove(id: id)
        Task {
            try? indexStore.deleteItems(folderId: id.uuidString)
            await reloadItems()
        }
        folders = bookmarkStore.folders
        if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            search()
        }
    }

    func startIndexing() {
        if indexTask != nil {
            if indexProgress.phase == .paused {
                folderIndexer.resume()
            }
            return
        }
        suppressAutoIndex = false

        activateAccess()
        let targets: [IndexTarget] = folders.compactMap { folder in
            guard let root = scopedRoots[folder.id]?.url else { return nil }
            return IndexTarget(folderID: folder.id, folderName: folder.name, rootURL: root, bookmarkData: folder.bookmarkData)
        }
        if targets.isEmpty, !folders.isEmpty {
            lastError = "Couldn't open the saved folders. Add them again to restore access."
        }

        indexProgress = IndexProgress(
            phase: .scanning,
            filesDiscovered: 0,
            filesCompleted: 0,
            filesTotal: 0,
            filesSkipped: 0,
            filesFailed: 0,
            currentRelativePath: nil,
            folderID: targets.first?.folderID,
            folderName: targets.first?.folderName,
            message: "Starting"
        )

        let indexer = folderIndexer
        indexTask = Task { [weak self] in
            await indexer.index(targets: targets) { update in
                Task { @MainActor in
                    guard let self else { return }
                    self.indexProgress = update
                    if update.filesCompleted > 0, update.filesCompleted % 8 == 0 {
                        await self.reloadItems()
                    }
                }
            }
            await self?.reloadItems()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.indexTask = nil
                if !self.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.search()
                }
                if self.indexAgainWhenDone {
                    self.indexAgainWhenDone = false
                    self.startIndexing()
                }
            }
        }
    }

    func pauseIndexing() {
        guard indexTask != nil else { return }
        folderIndexer.pause()
    }

    func resumeIndexing() {
        guard indexTask != nil else { return }
        folderIndexer.resume()
    }

    func cancelIndexing() {
        guard indexTask != nil else { return }
        suppressAutoIndex = true
        folderIndexer.cancel()
        indexTask?.cancel()
    }

    /// Ranks `searchQuery` against the current index. An empty query clears results.
    /// When the embedding server is down, results are exact-word matches only.
    func search() {
        searchTask?.cancel()
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            if lastError == Self.keywordOnlyNote { lastError = nil }
            return
        }

        // Don't compare a query from one model against vectors from another.
        if embeddingStatus == .ready,
           let model = serverModelID,
           (try? indexStore.isStale(for: model)) == true {
            searchResults = []
            lastError = "The embedding model changed to \(model). One Space is re-indexing; search again when it finishes."
            if indexTask == nil, !folders.isEmpty { startIndexing() }
            return
        }

        let corpus = items
        let client = embeddingClient
        let engine = searchEngine
        let serverReady = embeddingStatus == .ready
        searchTask = Task { [weak self] in
            do {
                let vector: [Float]
                let keywordOnly: Bool
                if serverReady {
                    vector = try await client.embedQuery(query)
                    keywordOnly = false
                } else {
                    // Exact words still rank. Semantic stays 0 until the model answers.
                    vector = []
                    keywordOnly = true
                }
                try Task.checkCancellation()
                let ranked = engine.rank(query: query, queryEmbedding: vector, items: corpus)
                // With no query vector every stored embedding scores 0. Keep the word hits.
                let hits = keywordOnly ? ranked.filter { $0.score > 0 } : ranked
                await MainActor.run {
                    guard let self else { return }
                    self.searchResults = hits
                    self.lastError = keywordOnly ? Self.keywordOnlyNote : nil
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    func revealInFinder(_ item: IndexedItem) {
        guard let fileURL = url(for: item) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    func openItem(_ item: IndexedItem) {
        guard let fileURL = url(for: item) else { return }
        NSWorkspace.shared.open(fileURL)
    }

    static let photoReaderAppURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Applications/Photo Reader.app", isDirectory: true)

    /// Photos and PDFs, and only when Photo Reader is installed.
    func canOpenInPhotoReader(_ item: IndexedItem) -> Bool {
        switch item.kind {
        case .image:
            break
        case .document:
            let path = item.relativePath.isEmpty ? item.absolutePath : item.relativePath
            guard path.lowercased().hasSuffix(".pdf") else { return false }
        case .note:
            return false
        }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: Self.photoReaderAppURL.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    func openInPhotoReader(_ item: IndexedItem) {
        guard canOpenInPhotoReader(item), let fileURL = url(for: item) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([fileURL], withApplicationAt: Self.photoReaderAppURL, configuration: configuration)
    }

    func url(for item: IndexedItem) -> URL? {
        guard let folderUUID = UUID(uuidString: item.folderId),
              let root = scopedRoots[folderUUID]?.url else {
            // Fall back to absolute path if still valid.
            let fallback = URL(fileURLWithPath: item.absolutePath)
            return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
        }
        var url = root
        for part in item.relativePath.split(separator: "/") where part != "." && part != ".." {
            url.appendPathComponent(String(part))
        }
        return url
    }

    func thumbnail(for item: IndexedItem, maxPixelSize: CGFloat = 320) -> NSImage? {
        guard item.kind == .image, let fileURL = url(for: item) else { return nil }
        return thumbnailCache.thumbnail(for: fileURL, maxPixelSize: maxPixelSize)
    }

    func recheckEmbeddings() {
        Task { await refreshEmbeddingHealth() }
    }

    // MARK: - Health

    private func startHealthLoop() {
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshEmbeddingHealth()
                try? await Task.sleep(nanoseconds: self?.healthInterval ?? 15_000_000_000)
            }
        }
    }

    private func refreshEmbeddingHealth() async {
        if embeddingStatus == .unknown || embeddingStatus == .checking {
            embeddingStatus = .checking
        }
        do {
            try await embeddingClient.healthCheck()
            embeddingStatus = .ready
            if let model = try? await embeddingClient.serverModelID() {
                serverModelID = model
                // Model switched since the last index (e.g. 300m -> EmbeddingGemma 2):
                // re-index automatically. The indexer clears the old vectors first.
                if indexTask == nil, !folders.isEmpty, (try? indexStore.isStale(for: model)) == true {
                    searchResults = []
                    lastError = "Embedding model changed to \(model). Re-indexing your folders."
                    startIndexing()
                }
            }
            // Folders added before the model was up have no row, or a nil lastIndexed.
            if indexTask == nil, !suppressAutoIndex, folders.contains(where: { folder in
                let stored = try? indexStore.folder(id: folder.id.uuidString)
                return stored?.lastIndexed == nil
            }) {
                startIndexing()
            }
        } catch {
            embeddingStatus = .unavailable(error.localizedDescription)
        }
    }

    // MARK: - Index access

    private func reloadItems() async {
        do {
            items = try indexStore.items()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func activateAccess() {
        let current = Set(folders.map(\.id))
        for id in Array(scopedRoots.keys) where !current.contains(id) {
            scopedRoots[id]?.stop()
            scopedRoots[id] = nil
        }
        for folder in folders where scopedRoots[folder.id] == nil {
            do {
                scopedRoots[folder.id] = try bookmarkStore.resolve(folder)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }
}
