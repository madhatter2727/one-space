import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import os

/// One folder the indexer is allowed to walk. Access is held by the caller for the whole run.
struct IndexTarget: Sendable, Hashable {
    var folderID: UUID
    var folderName: String
    var rootURL: URL
    /// Security-scoped bookmark bytes, stored in the index's `folders` table.
    var bookmarkData: Data? = nil
}

struct IndexProgress: Equatable, Sendable {
    enum Phase: String, Equatable, Sendable {
        case idle
        case scanning
        case indexing
        case paused
        case finished
        case cancelled
        case failed
    }

    var phase: Phase
    var filesDiscovered: Int
    var filesCompleted: Int
    var filesTotal: Int
    var filesSkipped: Int
    var filesFailed: Int
    var currentRelativePath: String?
    var folderID: UUID?
    var folderName: String?
    var message: String?
    /// Shown as the phase title while set, for example "Reading photos 3/20".
    var activity: String? = nil
    /// Items deleted at the start of this run because they came from a different embedding model.
    var staleItemsCleared: Int = 0

    var fraction: Double {
        switch phase {
        case .finished:
            return 1
        case .scanning, .idle:
            return 0
        case .indexing, .paused, .cancelled, .failed:
            guard filesTotal > 0 else { return 0 }
            return min(1, Double(filesCompleted) / Double(filesTotal))
        }
    }

    static let idle = IndexProgress(
        phase: .idle,
        filesDiscovered: 0,
        filesCompleted: 0,
        filesTotal: 0,
        filesSkipped: 0,
        filesFailed: 0,
        currentRelativePath: nil,
        folderID: nil,
        folderName: nil,
        message: nil
    )
}

/// Walks bookmarked folders, embeds documents, notes, and photos, and upserts `IndexStore`.
/// Unchanged files (same content hash and mtime) are skipped. Filename-only images are
/// described once a vision server is available.
final class FolderIndexer: @unchecked Sendable {
    static let junkNames: Set<String> = [".ds_store", "node_modules", ".git", "__macosx"]
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "webp"]
    /// Office, PDF, and markup. `.pages` is a package and is not supported.
    static let documentExtensions: Set<String> = [
        "pdf", "docx", "doc", "rtf", "rtfd", "odt", "html", "htm", "webarchive"
    ]
    static let noteExtensions: Set<String> = [
        "txt", "md", "markdown", "csv", "tsv", "json",
        "py", "js", "ts", "tsx", "jsx", "swift", "java", "kt",
        "c", "h", "cpp", "hpp", "m", "go", "rs", "rb", "php",
        "sh", "zsh", "bash", "sql", "xml", "yaml", "yml", "toml",
        "ini", "cfg", "conf", "log", "tex", "css", "scss"
    ]
    /// Files larger than this are not indexed.
    static let maxFileBytes: Int64 = 50 * 1024 * 1024

    private let embeddingClient: EmbeddingClient
    private let indexStore: IndexStore
    private let visionClient: VisionClient
    private struct Control {
        var pauseRequested = false
        var cancelRequested = false
        var running = false
    }
    private let control = OSAllocatedUnfairLock(initialState: Control())

    init(
        embeddingClient: EmbeddingClient,
        indexStore: IndexStore,
        visionClient: VisionClient = VisionClient()
    ) {
        self.embeddingClient = embeddingClient
        self.indexStore = indexStore
        self.visionClient = visionClient
    }

    func pause() {
        control.withLock { $0.pauseRequested = true }
    }

    func resume() {
        control.withLock { $0.pauseRequested = false }
    }

    func cancel() {
        control.withLock {
            $0.cancelRequested = true
            $0.pauseRequested = false
        }
    }

    func index(
        targets: [IndexTarget],
        progress: @escaping @Sendable (IndexProgress) -> Void
    ) async {
        let shouldRun = control.withLock { state -> Bool in
            if state.running { return false }
            state.running = true
            state.pauseRequested = false
            state.cancelRequested = false
            return true
        }
        guard shouldRun else { return }
        defer {
            control.withLock { $0.running = false }
        }
        await visionClient.beginIndexRun()

        var state = IndexProgress.idle
        state.phase = .scanning
        state.message = "Scanning"
        progress(state)

        do {
            // Never mix vectors from two models: if the server's model differs from the one
            // that built the index, wipe the old vectors and re-embed everything.
            let modelID = try await embeddingClient.serverModelID()
            let cleared = try indexStore.adoptModel(modelID)
            if cleared > 0 {
                state.staleItemsCleared = cleared
                state.message = "Embedding model changed to \(modelID). Re-indexing everything."
                progress(state)
            }

            // Items reference folders(id) with a foreign key, so each folder row must exist first.
            for target in targets {
                let id = target.folderID.uuidString
                let previous = try indexStore.folder(id: id)
                try indexStore.upsertFolder(FolderBookmark(
                    id: id,
                    displayName: target.folderName,
                    bookmarkData: target.bookmarkData ?? previous?.bookmarkData ?? Data(target.rootURL.path.utf8),
                    lastIndexed: previous?.lastIndexed
                ))
            }

            var discovered: [DiscoveredFile] = []
            for target in targets {
                state.folderID = target.folderID
                state.folderName = target.folderName
                state.message = "Scanning \(target.folderName)"
                progress(state)
                try await collect(target: target, into: &discovered, state: &state, progress: progress)
            }

            state.filesTotal = discovered.count
            state.phase = .indexing
            state.message = nil
            state.activity = nil
            progress(state)

            let visionAvailable = await visionClient.isAvailable()
            var imageOrdinal = 0
            let imageTotal = discovered.reduce(0) { $0 + ($1.kind == .image ? 1 : 0) }

            var existingByID: [String: IndexedItem] = [:]
            for item in try indexStore.items() {
                existingByID[item.id] = item
            }

            for file in discovered {
                try await checkpoint(activePhase: .indexing, state: &state, progress: progress)
                state.folderID = file.target.folderID
                state.folderName = file.target.folderName
                state.currentRelativePath = file.relativePath
                state.activity = nil
                if file.kind == .image {
                    imageOrdinal += 1
                }
                do {
                    let outcome = try await indexFile(
                        file,
                        existingByID: &existingByID,
                        visionAvailable: visionAvailable,
                        imageOrdinal: imageOrdinal,
                        imageTotal: imageTotal,
                        snapshot: state,
                        emit: progress
                    )
                    if outcome == .skipped {
                        state.filesSkipped += 1
                    }
                    state.message = nil
                } catch {
                    if isCancellation(error) { throw CancellationError() }
                    state.filesFailed += 1
                    state.message = "\(file.relativePath): \(error.localizedDescription)"
                }
                state.filesCompleted += 1
                progress(state)
            }

            for target in targets {
                try? indexStore.updateFolderIndexed(id: target.folderID.uuidString)
            }
            state.phase = .finished
            state.currentRelativePath = nil
            state.message = nil
            progress(state)
        } catch {
            if isCancellation(error) {
                state.phase = .cancelled
                state.message = "Cancelled"
            } else {
                state.phase = .failed
                state.message = error.localizedDescription
            }
            progress(state)
        }
    }

    // MARK: - Walk

    private struct DiscoveredFile {
        var target: IndexTarget
        var url: URL
        var relativePath: String
        var kind: ItemKind
    }

    private enum IndexOutcome {
        case indexed
        case skipped
    }

    private func collect(
        target: IndexTarget,
        into discovered: inout [DiscoveredFile],
        state: inout IndexProgress,
        progress: @escaping @Sendable (IndexProgress) -> Void
    ) async throws {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: target.rootURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants]
        ) else { return }

        var collectedURLs: [URL] = []
        while let next = enumerator.nextObject() as? URL {
            collectedURLs.append(next)
        }
        for url in collectedURLs {
            try await checkpoint(activePhase: .scanning, state: &state, progress: progress)
            let name = url.lastPathComponent.lowercased()
            if Self.junkNames.contains(name) {
                enumerator.skipDescendants()
                continue
            }

            let ext = url.pathExtension.lowercased()
            let values = try? url.resourceValues(forKeys: keys)
            let isDirectory = values?.isDirectory == true
            // .rtfd is a directory package. skipsPackageDescendants hides its children,
            // so the package URL itself is the document.
            let isRTFD = isDirectory && ext == "rtfd"
            if isDirectory && !isRTFD {
                continue
            }
            if !isRTFD && values?.isRegularFile != true {
                continue
            }

            let byteSize: Int64 = isRTFD ? packageByteSize(url) : Int64(values?.fileSize ?? 0)
            if byteSize > Self.maxFileBytes {
                continue
            }
            guard let kind = Self.kind(forExtension: ext) else { continue }

            guard let relative = relativePath(from: target.rootURL, to: url) else { continue }
            discovered.append(DiscoveredFile(target: target, url: url, relativePath: relative, kind: kind))
            state.filesDiscovered = discovered.count
            if discovered.count % 25 == 0 {
                progress(state)
            }
        }
    }

    private func indexFile(
        _ file: DiscoveredFile,
        existingByID: inout [String: IndexedItem],
        visionAvailable: Bool,
        imageOrdinal: Int,
        imageTotal: Int,
        snapshot: IndexProgress,
        emit: @escaping @Sendable (IndexProgress) -> Void
    ) async throws -> IndexOutcome {
        let fingerprint = try fileFingerprint(file.url)
        let id = Self.itemID(folderID: file.target.folderID, relativePath: file.relativePath)
        if shouldSkip(
            existing: existingByID[id],
            fingerprint: fingerprint,
            file: file,
            visionAvailable: visionAvailable
        ) {
            return .skipped
        }

        let title = file.url.deletingPathExtension().lastPathComponent
        let embedding: [Float]
        let snippet: String
        let bodyText: String
        let visionDescribed: Bool?
        switch file.kind {
        case .image:
            if visionAvailable,
               let description = try await imageDescription(
                absolutePath: file.url.path,
                mtime: fingerprint.mtime,
                imageAt: file.url,
                activity: "Reading photos \(imageOrdinal)/\(max(imageTotal, 1))",
                snapshot: snapshot,
                emit: emit
               ) {
                let stored = String(description.prefix(60_000))
                let document = "\(file.url.lastPathComponent)\n\(file.relativePath)\n\(stored)"
                embedding = try await embedPossiblyChunked(title: title, text: document)
                snippet = String(stored.prefix(240))
                bodyText = stored
                visionDescribed = true
            } else {
                let document = "\(file.url.lastPathComponent)\n\(file.relativePath)"
                embedding = try await embeddingClient.embedDocument(title: title, text: document)
                snippet = file.relativePath
                bodyText = ""
                visionDescribed = false
            }
        case .note, .document:
            let normalized = try extractText(from: file.url, kind: file.kind)
            let ext = file.url.pathExtension.lowercased()
            if ext == "pdf", normalized.count < 40, visionAvailable,
               let description = try await pdfDescription(
                file: file,
                mtime: fingerprint.mtime,
                snapshot: snapshot,
                emit: emit
               ) {
                let stored = String(description.prefix(60_000))
                let document = "\(file.url.lastPathComponent)\n\(file.relativePath)\n\(stored)"
                embedding = try await embedPossiblyChunked(title: title, text: document)
                snippet = String(stored.prefix(240))
                bodyText = stored
                visionDescribed = true
            } else if normalized.isEmpty {
                snippet = "No readable text (filename only)"
                let document = "\(file.url.lastPathComponent)\n\(file.relativePath)"
                embedding = try await embeddingClient.embedDocument(title: title, text: document)
                bodyText = ""
                visionDescribed = ext == "pdf" ? false : nil
            } else {
                bodyText = String(normalized.prefix(60_000))
                snippet = String(normalized.prefix(240))
                // Model context is 2048 tokens. Four 3000-character chunks stay inside it.
                embedding = try await embedChunked(title: title, text: normalized)
                visionDescribed = nil
            }
        }
        let item = IndexedItem(
            id: id,
            folderId: file.target.folderID.uuidString,
            relativePath: file.relativePath,
            absolutePath: file.url.path,
            kind: file.kind,
            title: file.url.lastPathComponent,
            snippet: snippet,
            bodyText: bodyText,
            mtime: fingerprint.mtime,
            size: fingerprint.byteSize,
            contentHash: fingerprint.hash,
            embeddingDim: embedding.count,
            embedding: embedding,
            visionDescribed: visionDescribed
        )
        try indexStore.upsertItem(item)
        existingByID[id] = item
        return .indexed
    }

    /// Unchanged rows with a vector are skipped. Filename-only images and textless PDFs are not,
    /// once the vision server is up, so they can be described.
    private func shouldSkip(
        existing: IndexedItem?,
        fingerprint: Fingerprint,
        file: DiscoveredFile,
        visionAvailable: Bool
    ) -> Bool {
        guard let existing,
              existing.contentHash == fingerprint.hash,
              abs(existing.mtime.timeIntervalSince(fingerprint.mtime)) < 1,
              let embedding = existing.embedding, !embedding.isEmpty else {
            return false
        }
        guard visionAvailable, existing.visionDescribed != true else { return true }
        switch file.kind {
        case .image:
            return false
        case .document:
            return !(file.url.pathExtension.lowercased() == "pdf" && existing.bodyText.count < 40)
        case .note:
            return true
        }
    }

    private func imageDescription(
        absolutePath: String,
        mtime: Date,
        imageAt url: URL,
        activity: String,
        snapshot: IndexProgress,
        emit: @escaping @Sendable (IndexProgress) -> Void
    ) async throws -> String? {
        if let cached = await visionClient.cachedDescription(absolutePath: absolutePath, mtime: mtime) {
            return cached
        }
        var next = snapshot
        next.activity = activity
        emit(next)
        do {
            return try await visionClient.describe(absolutePath: absolutePath, mtime: mtime, imageAt: url)
        } catch {
            if isCancellation(error) { throw error }
            return nil
        }
    }

    private func pdfDescription(
        file: DiscoveredFile,
        mtime: Date,
        snapshot: IndexProgress,
        emit: @escaping @Sendable (IndexProgress) -> Void
    ) async throws -> String? {
        let path = file.url.path
        if let cached = await visionClient.cachedDescription(absolutePath: path, mtime: mtime) {
            return cached
        }
        guard let jpeg = pdfFirstPageJPEG(url: file.url) else { return nil }
        var next = snapshot
        next.activity = "Reading document"
        emit(next)
        do {
            return try await visionClient.describe(absolutePath: path, mtime: mtime, imageData: jpeg)
        } catch {
            if isCancellation(error) { throw error }
            return nil
        }
    }

    /// Page 1 of a PDF, as JPEG, longest side at most 1024px. Nil when the page can't be drawn.
    private func pdfFirstPageJPEG(url: URL) -> Data? {
        guard let document = PDFDocument(url: url), let page = document.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        let maxPixel: CGFloat = 1024
        let scale = min(1, maxPixel / max(bounds.width, bounds.height))
        let width = max(1, Int((bounds.width * scale).rounded()))
        let height = max(1, Int((bounds.height * scale).rounded()))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()
        guard let image = context.makeImage() else { return nil }
        return Self.jpegData(from: image)
    }

    private static func jpegData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.82
        ]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private func embedPossiblyChunked(title: String, text: String) async throws -> [Float] {
        if text.count > 3_000 {
            return try await embedChunked(title: title, text: text)
        }
        return try await embeddingClient.embedDocument(title: title, text: text)
    }

    // MARK: - Pause / cancel

    private func checkpoint(
        activePhase: IndexProgress.Phase,
        state: inout IndexProgress,
        progress: @escaping @Sendable (IndexProgress) -> Void
    ) async throws {
        try throwIfCancelled()
        var announced = false
        while isPauseRequested() {
            try throwIfCancelled()
            if !announced {
                state.phase = .paused
                progress(state)
                announced = true
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        if announced {
            state.phase = activePhase
            progress(state)
        }
        try Task.checkCancellation()
    }

    private func isPauseRequested() -> Bool {
        control.withLock { $0.pauseRequested }
    }

    private func throwIfCancelled() throws {
        let cancelled = control.withLock { $0.cancelRequested }
        if cancelled || Task.isCancelled {
            throw CancellationError()
        }
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    // MARK: - Files

    private struct Fingerprint {
        var hash: String
        var mtime: Date
        var byteSize: Int64
    }

    private func fileFingerprint(_ url: URL) throws -> Fingerprint {
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey])
        let mtime = values.contentModificationDate ?? .distantPast
        if values.isDirectory == true {
            return try packageFingerprint(url, mtime: mtime)
        }
        let byteSize = Int64(values.fileSize ?? 0)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024)
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return Fingerprint(hash: hash, mtime: mtime, byteSize: byteSize)
    }

    /// `.rtfd` is a directory. Hash the files inside so unchanged packages still skip.
    private func packageFingerprint(_ url: URL, mtime: Date) throws -> Fingerprint {
        var hasher = SHA256()
        var total: Int64 = 0
        let root = url.resolvingSymlinksInPath().standardizedFileURL.path
        if let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) {
            while let next = enumerator.nextObject() as? URL {
                let fileValues = try next.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard fileValues.isRegularFile == true else { continue }
                total += Int64(fileValues.fileSize ?? 0)
                let path = next.resolvingSymlinksInPath().standardizedFileURL.path
                let relative = path.hasPrefix(root) ? String(path.dropFirst(root.count)) : next.lastPathComponent
                hasher.update(data: Data(relative.utf8))
                let handle = try FileHandle(forReadingFrom: next)
                defer { try? handle.close() }
                while true {
                    let piece = try handle.read(upToCount: 1024 * 1024)
                    guard let piece, !piece.isEmpty else { break }
                    hasher.update(data: piece)
                }
            }
        }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return Fingerprint(hash: hash, mtime: mtime, byteSize: total)
    }

    private func packageByteSize(_ url: URL) -> Int64 {
        var total: Int64 = 0
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) else { return 0 }
        while let next = enumerator.nextObject() as? URL {
            let fileValues = try? next.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard fileValues?.isRegularFile == true else { continue }
            total += Int64(fileValues?.fileSize ?? 0)
            if total > Self.maxFileBytes { break }
        }
        return total
    }

    /// `.pages` is intentionally absent. Other plain-text UTTypes fall through to `.note`.
    static func kind(forExtension ext: String) -> ItemKind? {
        if ext == "pages" || ext.isEmpty { return nil }
        if imageExtensions.contains(ext) { return .image }
        if documentExtensions.contains(ext) { return .document }
        if noteExtensions.contains(ext) { return .note }
        guard let type = UTType(filenameExtension: ext) else { return nil }
        if type.conforms(to: .image) || type.conforms(to: .pdf) { return nil }
        if type.conforms(to: .text) || type.conforms(to: .sourceCode) { return .note }
        return nil
    }

    private func extractText(from url: URL, kind: ItemKind) throws -> String {
        let ext = url.pathExtension.lowercased()
        let raw: String
        switch kind {
        case .image:
            raw = ""
        case .note, .document:
            switch ext {
            case "pdf":
                guard let pdf = PDFDocument(url: url) else {
                    throw TextExtractionError(message: "Couldn't open PDF")
                }
                raw = pdf.string ?? ""
            case "docx", "doc", "rtf", "rtfd", "odt", "webarchive":
                raw = try attributedPlainText(from: url, ext: ext)
            case "html", "htm", "xml":
                // HTML via NSAttributedString needs the main thread. Read and strip instead.
                let text = try readText(from: url, encodings: [.utf8, .isoLatin1], rejectNUL: false)
                raw = stripMarkup(text)
            default:
                raw = try readText(from: url, encodings: [.utf8, .utf16, .isoLatin1], rejectNUL: true)
            }
        }
        return normalizeWhitespace(raw)
    }

    private func attributedPlainText(from url: URL, ext: String) throws -> String {
        let documentType: NSAttributedString.DocumentType
        switch ext {
        case "docx":
            documentType = .officeOpenXML
        case "doc":
            documentType = .docFormat
        case "rtf":
            documentType = .rtf
        case "rtfd":
            documentType = .rtfd
        case "odt":
            documentType = .openDocument
        case "webarchive":
            documentType = .webArchive
        default:
            throw TextExtractionError(message: "Unsupported document .\(ext)")
        }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: documentType
        ]
        let attributed = try NSAttributedString(url: url, options: options, documentAttributes: nil)
        return attributed.string
    }

    /// Plain text and code. A NUL in the first 4096 bytes means the file is binary.
    private func readText(from url: URL, encodings: [String.Encoding], rejectNUL: Bool) throws -> String {
        let data = try Data(contentsOf: url)
        if rejectNUL, data.prefix(4096).contains(0) {
            return ""
        }
        for encoding in encodings {
            if let text = String(data: data, encoding: encoding) {
                return text
            }
        }
        return ""
    }

    private func stripMarkup(_ text: String) -> String {
        var result = text
        let patterns = [
            "(?is)<script\\b[^>]*>.*?</script>",
            "(?is)<style\\b[^>]*>.*?</style>",
            "(?is)<[^>]+>"
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        // `&amp;` last so a single pass does not turn `&amp;lt;` into `<`.
        let entities = [
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&nbsp;", " "),
            ("&amp;", "&")
        ]
        for (entity, value) in entities {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        return result
    }

    private func normalizeWhitespace(_ text: String) -> String {
        let collapsed = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Splits on the last space before `size` when one exists. At most `maxCount` chunks.
    private static func textChunks(_ text: String, size: Int, maxCount: Int) -> [String] {
        guard size > 0, maxCount > 0, !text.isEmpty else { return [] }
        var chunks: [String] = []
        var start = text.startIndex
        while start < text.endIndex && chunks.count < maxCount {
            let limit = text.index(start, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            var end = limit
            if limit < text.endIndex {
                let window = text[start..<limit]
                if let space = window.lastIndex(of: " "), space > start {
                    end = space
                }
            }
            if end <= start { break }
            chunks.append(String(text[start..<end]))
            let next = (end < text.endIndex && text[end] == " ") ? text.index(after: end) : end
            if next <= start { break }
            start = next
        }
        return chunks
    }

    private static func firstHalf(_ text: String) -> String {
        let count = text.count / 2
        guard count > 0 else { return "" }
        return String(text.prefix(count))
    }

    private static func l2Normalized(_ vector: [Float]) -> [Float] {
        var sumSquares: Float = 0
        for value in vector {
            sumSquares += value * value
        }
        let norm = sumSquares.squareRoot()
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    private static func meanVector(_ vectors: [[Float]]) -> [Float] {
        guard let width = vectors.first?.count, width > 0 else { return [] }
        var sum = [Float](repeating: 0, count: width)
        var used = 0
        for vector in vectors where vector.count == width {
            for index in 0..<width {
                sum[index] += vector[index]
            }
            used += 1
        }
        guard used > 0 else { return [] }
        let scale = Float(used)
        return sum.map { $0 / scale }
    }

    private func embedChunked(title: String, text: String) async throws -> [Float] {
        let chunks = Self.textChunks(text, size: 3_000, maxCount: 4)
        var vectors: [[Float]] = []
        var lastError: Error?
        for chunk in chunks {
            let embedded: [Float]?
            do {
                embedded = try await embeddingClient.embedDocument(title: title, text: chunk)
            } catch {
                if isCancellation(error) { throw error }
                lastError = error
                embedded = try await embedHalf(of: chunk, title: title, lastError: &lastError)
            }
            guard let embedded else { continue }
            let normalized = Self.l2Normalized(embedded)
            if let expected = vectors.first?.count, normalized.count != expected {
                continue
            }
            vectors.append(normalized)
        }
        guard !vectors.isEmpty else {
            throw lastError ?? TextExtractionError(message: "Couldn't embed document text")
        }
        return Self.l2Normalized(Self.meanVector(vectors))
    }

    /// One retry with the first half of a chunk that failed for a non-cancellation error.
    private func embedHalf(of chunk: String, title: String, lastError: inout Error?) async throws -> [Float]? {
        let half = Self.firstHalf(chunk)
        guard !half.isEmpty, half.count < chunk.count else { return nil }
        do {
            return try await embeddingClient.embedDocument(title: title, text: half)
        } catch {
            if isCancellation(error) { throw error }
            lastError = error
            return nil
        }
    }

    private func relativePath(from root: URL, to file: URL) -> String? {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let filePath = file.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard filePath.hasPrefix(prefix) else { return nil }
        return String(filePath.dropFirst(prefix.count))
    }

    static func itemID(folderID: UUID, relativePath: String) -> String {
        "\(folderID.uuidString)::\(relativePath)"
    }
}

private struct TextExtractionError: LocalizedError, Sendable {
    var message: String
    var errorDescription: String? { message }
}
