import Foundation

/// Talks to a local OpenAI-compatible embedding server.
///
/// If the server is down or the body is not a real vector, every method throws.
/// This type never invents, zeros, or randomizes an embedding.
actor EmbeddingClient {
    static let defaultBaseURL = URL(string: "http://127.0.0.1:8081")!

    /// EmbeddingGemma 2 search-query prompt ("SearchQuery" in the model's sentence-transformers config).
    static func prefixedQuery(_ query: String) -> String {
        "task: search result | query: \(query)"
    }

    /// EmbeddingGemma 2 document prompt: `title: {title | none} | text: {content}`.
    static func prefixedDocument(title: String, text: String) -> String {
        "title: \(title) | text: \(text)"
    }

    let baseURL: URL
    var model: String
    private let session: URLSession

    init(
        baseURL: URL = EmbeddingClient.defaultBaseURL,
        model: String = "embeddinggemma2",
        session: URLSession? = nil
    ) {
        self.baseURL = baseURL
        self.model = model
        self.session = session ?? Self.makeSession()
    }

    /// GET /health, then /v1/models, then the server root. Throws when none respond 2xx.
    func healthCheck() async throws {
        let probes = ["health", "v1/models", ""]
        var failures: [String] = []
        for probe in probes {
            do {
                let status = try await get(path: probe, timeout: 4)
                if (200...299).contains(status) {
                    return
                }
                failures.append("\(Self.displayPath(probe)) HTTP \(status)")
            } catch {
                failures.append("\(Self.displayPath(probe)) \(error.localizedDescription)")
            }
        }
        throw EmbeddingClientError.serverUnavailable(Self.summarize(failures))
    }

    /// The id of the model the server has loaded (first entry of GET /v1/models), e.g. `embeddinggemma2`.
    /// The index stores this so vectors from different models are never mixed.
    func serverModelID() async throws -> String {
        let (data, response) = try await session.data(
            for: request(path: "v1/models", method: "GET", body: nil, timeout: 4)
        )
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw EmbeddingClientError.serverUnavailable("v1/models did not answer")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EmbeddingClientError.unexpectedResponse(Self.preview(data))
        }
        if let list = json["data"] as? [[String: Any]], let id = list.first?["id"] as? String, !id.isEmpty {
            return id
        }
        if let list = json["models"] as? [[String: Any]], let id = list.first?["model"] as? String, !id.isEmpty {
            return id
        }
        throw EmbeddingClientError.unexpectedResponse(Self.preview(data))
    }

    /// Embeds `text` exactly as given. Tries POST /v1/embeddings, then POST /embeddings.
    func embedText(_ text: String) async throws -> [Float] {
        let openAI = try Self.jsonBody(["input": text, "model": model])
        let content = try Self.jsonBody(["content": text, "model": model])
        let attempts: [(String, Data)] = [
            ("v1/embeddings", openAI),
            ("embeddings", openAI),
            ("embeddings", content),
        ]

        var failures: [String] = []
        for (path, body) in attempts {
            do {
                let (data, status) = try await post(path: path, body: body)
                guard (200...299).contains(status) else {
                    failures.append("\(path) HTTP \(status) \(Self.preview(data))")
                    continue
                }
                let vector = try Self.parseEmbedding(from: data)
                guard !vector.isEmpty else {
                    throw EmbeddingClientError.emptyEmbedding
                }
                return vector
            } catch EmbeddingClientError.emptyEmbedding {
                throw EmbeddingClientError.emptyEmbedding
            } catch let error as EmbeddingClientError {
                failures.append("\(path) \(error.localizedDescription)")
            } catch {
                failures.append("\(path) \(error.localizedDescription)")
            }
        }

        throw EmbeddingClientError.serverUnavailable(Self.summarize(failures))
    }

    /// Prefixes `query` with `task: search result | query: ` and embeds it.
    func embedQuery(_ query: String) async throws -> [Float] {
        try await embedText(Self.prefixedQuery(query))
    }

    /// Prefixes the document with `title: … | text: …` and embeds it.
    func embedDocument(title: String, text: String) async throws -> [Float] {
        try await embedText(Self.prefixedDocument(title: title, text: text))
    }

    // MARK: - HTTP

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }

    private func get(path: String, timeout: TimeInterval) async throws -> Int {
        let ( _, response) = try await session.data(for: request(path: path, method: "GET", body: nil, timeout: timeout))
        guard let http = response as? HTTPURLResponse else {
            throw EmbeddingClientError.serverUnavailable("non-HTTP response from \(Self.displayPath(path))")
        }
        return http.statusCode
    }

    private func post(path: String, body: Data) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request(path: path, method: "POST", body: body, timeout: 60))
        guard let http = response as? HTTPURLResponse else {
            throw EmbeddingClientError.serverUnavailable("non-HTTP response from \(path)")
        }
        return (data, http.statusCode)
    }

    private func request(path: String, method: String, body: Data?, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func url(for path: String) -> URL {
        guard !path.isEmpty else { return baseURL }
        return baseURL.appending(path: path)
    }

    private static func displayPath(_ path: String) -> String {
        path.isEmpty ? "/" : path
    }

    private static func jsonBody(_ object: [String: String]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [])
    }

    private static func summarize(_ failures: [String]) -> String {
        if failures.isEmpty {
            return "embedding server did not respond"
        }
        return failures.joined(separator: "; ")
    }

    private static func preview(_ data: Data) -> String {
        let text = String(data: data.prefix(180), encoding: .utf8) ?? "\(data.count) bytes"
        return text.replacingOccurrences(of: "\n", with: " ")
    }

    // MARK: - Response parsing

    /// Accepts OpenAI `{data:[{embedding:[...]}]}`, `{embedding:[...]}`, and `{embeddings:[[...]]}`.
    private static func parseEmbedding(from data: Data) throws -> [Float] {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw EmbeddingClientError.unexpectedResponse(preview(data))
        }
        guard let vector = firstVector(in: json) else {
            throw EmbeddingClientError.unexpectedResponse(preview(data))
        }
        return vector
    }

    private static func firstVector(in json: Any) -> [Float]? {
        if let array = json as? [Any] {
            if let floats = asFloats(array), !floats.isEmpty {
                return floats
            }
            for element in array {
                if let found = firstVector(in: element) {
                    return found
                }
            }
            return nil
        }
        guard let object = json as? [String: Any] else { return nil }
        if let raw = object["embedding"], let found = vectorValue(raw) {
            return found
        }
        if let raw = object["embeddings"], let found = firstVector(in: raw) {
            return found
        }
        if let raw = object["data"], let found = firstVector(in: raw) {
            return found
        }
        return nil
    }

    private static func vectorValue(_ raw: Any) -> [Float]? {
        if let array = raw as? [Any], let floats = asFloats(array) {
            return floats
        }
        return firstVector(in: raw)
    }

    private static func asFloats(_ array: [Any]) -> [Float]? {
        var floats: [Float] = []
        floats.reserveCapacity(array.count)
        for value in array {
            guard let number = value as? NSNumber else { return nil }
            floats.append(number.floatValue)
        }
        return floats
    }
}

enum EmbeddingClientError: Error, Sendable, LocalizedError, CustomStringConvertible {
    /// Connection failed, or every embeddings route returned a non-vector response.
    case serverUnavailable(String)
    /// The server answered with an empty vector. No substitute is returned.
    case emptyEmbedding
    case unexpectedResponse(String)

    var errorDescription: String? { description }

    var description: String {
        switch self {
        case .serverUnavailable(let detail):
            return "Embedding server is down or rejected the request (\(detail)). No vector was invented."
        case .emptyEmbedding:
            return "Embedding server returned an empty vector."
        case .unexpectedResponse(let detail):
            return "Embedding server returned an unreadable body (\(detail))."
        }
    }
}
