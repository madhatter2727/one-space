import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Local vision model on an OpenAI-compatible llama-server (`http://127.0.0.1:8093`).
///
/// Descriptions are cached in Application Support so a second index does not call the model again.
actor VisionClient {
    static let defaultBaseURL = URL(string: "http://127.0.0.1:8093")!
    static let describePrompt = "Describe this image in 2-3 sentences for search: main subjects, setting, objects, colors. Then on a new line starting 'TEXT:' write any readable text in the image verbatim (or 'TEXT: none')."
    static let maxPixel = 1024

    private let baseURL: URL
    private let session: URLSession
    private let healthSession: URLSession
    private let cacheURL: URL
    private var cache: [String: String] = [:]
    private var cacheLoaded = false
    /// Health result for the current index run. Nil until `isAvailable()` probes.
    private var availability: Bool?

    init(baseURL: URL = VisionClient.defaultBaseURL, cacheURL: URL? = nil) {
        self.baseURL = baseURL
        self.session = Self.makeSession(requestTimeout: 120, resourceTimeout: 120)
        self.healthSession = Self.makeSession(requestTimeout: 2, resourceTimeout: 2)
        self.cacheURL = cacheURL ?? Self.defaultCacheURL()
    }

    /// Drops the cached health result so the next index run probes `/health` once.
    func beginIndexRun() {
        availability = nil
    }

    /// GET /health with a 2 second timeout. The result is reused until `beginIndexRun()`.
    func isAvailable() async -> Bool {
        if let availability { return availability }
        let ok = await probeHealth()
        availability = ok
        return ok
    }

    /// Cached description for this path and modification time, if one was stored.
    func cachedDescription(absolutePath: String, mtime: Date) -> String? {
        loadCacheIfNeeded()
        guard let stored = cache[Self.cacheKey(absolutePath: absolutePath, mtime: mtime)], !stored.isEmpty else {
            return nil
        }
        return stored
    }

    /// Describes an image file (JPEG, PNG, HEIC, WebP). Uses the cache when the mtime matches.
    func describe(absolutePath: String, mtime: Date, imageAt url: URL) async throws -> String {
        let key = Self.cacheKey(absolutePath: absolutePath, mtime: mtime)
        loadCacheIfNeeded()
        if let stored = cache[key], !stored.isEmpty { return stored }
        let jpeg = try Self.downscaledJPEG(from: url, maxPixel: Self.maxPixel)
        let text = try await complete(jpeg: jpeg)
        remember(text, for: key)
        return text
    }

    /// Describes JPEG/PNG bytes, typically a rendered PDF page. Same cache key as a file.
    func describe(absolutePath: String, mtime: Date, imageData: Data) async throws -> String {
        let key = Self.cacheKey(absolutePath: absolutePath, mtime: mtime)
        loadCacheIfNeeded()
        if let stored = cache[key], !stored.isEmpty { return stored }
        let jpeg = try Self.downscaledJPEG(from: imageData, maxPixel: Self.maxPixel)
        let text = try await complete(jpeg: jpeg)
        remember(text, for: key)
        return text
    }

    /// `absolutePath|mtimeSeconds`, mtime rounded to whole seconds.
    static func cacheKey(absolutePath: String, mtime: Date) -> String {
        let seconds = Int64(mtime.timeIntervalSince1970.rounded())
        return "\(absolutePath)|\(seconds)"
    }

    /// Removes closed `<think>` blocks, then drops an unclosed trailing think block.
    static func stripThinking(_ text: String) -> String {
        var result = text
        if let regex = try? NSRegularExpression(pattern: "<think>[\\s\\S]*?</think>", options: [.caseInsensitive]) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }
        if let open = result.range(of: "<think>", options: [.caseInsensitive]) {
            result = String(result[..<open.lowerBound])
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Cache

    private static func defaultCacheURL() -> URL {
        if let directory = try? OneSpaceSupport.directory() {
            return directory.appendingPathComponent("vision-cache.json")
        }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("onespace-vision-cache.json")
    }

    private func loadCacheIfNeeded() {
        guard !cacheLoaded else { return }
        cacheLoaded = true
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return
        }
        cache = decoded
    }

    private func remember(_ description: String, for key: String) {
        cache[key] = description
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(cache) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    // MARK: - HTTP

    private func probeHealth() async -> Bool {
        var request = URLRequest(url: baseURL.appending(path: "health"))
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (_, response) = try await healthSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200...299).contains(http.statusCode)
        } catch {
            return false
        }
    }

    private func complete(jpeg: Data) async throws -> String {
        let payload = try Self.requestBody(jpegBase64: jpeg.base64EncodedString())
        var request = URLRequest(url: baseURL.appending(path: "v1/chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = payload

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw VisionClientError.requestFailed("non-HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw VisionClientError.requestFailed("HTTP \(http.statusCode) \(Self.preview(data))")
        }
        let cleaned = Self.stripThinking(try Self.parseContent(data))
        guard !cleaned.isEmpty else { throw VisionClientError.emptyDescription }
        return cleaned
    }

    private static func requestBody(jpegBase64: String) throws -> Data {
        let body: [String: Any] = [
            "model": "local",
            "temperature": 0.1,
            "max_tokens": 300,
            "stream": false,
            "chat_template_kwargs": ["enable_thinking": false],
            "messages": [
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": describePrompt],
                        [
                            "type": "image_url",
                            "image_url": ["url": "data:image/jpeg;base64,\(jpegBase64)"]
                        ]
                    ]
                ]
            ]
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// OpenAI chat content is a string, or a list of `{type, text}` parts.
    private static func parseContent(_ data: Data) throws -> String {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw VisionClientError.requestFailed(preview(data))
        }
        guard let object = json as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw VisionClientError.requestFailed(preview(data))
        }
        if let text = message["content"] as? String {
            return text
        }
        if let parts = message["content"] as? [[String: Any]] {
            let text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            if !text.isEmpty { return text }
        }
        throw VisionClientError.requestFailed(preview(data))
    }

    private static func preview(_ data: Data) -> String {
        let text = String(data: data.prefix(180), encoding: .utf8) ?? "\(data.count) bytes"
        return text.replacingOccurrences(of: "\n", with: " ")
    }

    private static func makeSession(requestTimeout: TimeInterval, resourceTimeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }

    // MARK: - ImageIO

    private static func downscaledJPEG(from url: URL, maxPixel: Int) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw VisionClientError.unreadableImage
        }
        return try downscaledJPEG(from: source, maxPixel: maxPixel)
    }

    private static func downscaledJPEG(from data: Data, maxPixel: Int) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw VisionClientError.unreadableImage
        }
        return try downscaledJPEG(from: source, maxPixel: maxPixel)
    }

    /// Longest side at most `maxPixel`. HEIC orientation is applied. Works for HEIC, JPEG, PNG, and WebP.
    private static func downscaledJPEG(from source: CGImageSource, maxPixel: Int) throws -> Data {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw VisionClientError.unreadableImage
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw VisionClientError.unreadableImage
        }
        let destinationOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.82
        ]
        CGImageDestinationAddImage(destination, image, destinationOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw VisionClientError.unreadableImage
        }
        return data as Data
    }
}

enum VisionClientError: Error, LocalizedError, Sendable {
    case unreadableImage
    case emptyDescription
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadableImage:
            return "Couldn't read the image."
        case .emptyDescription:
            return "Vision model returned an empty description."
        case .requestFailed(let detail):
            return "Vision server request failed (\(detail))."
        }
    }
}
