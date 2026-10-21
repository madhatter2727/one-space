import Foundation

/// Ranks indexed items by cosine similarity, exact words, or both.
/// Hybrid rank skips an item only when it has no embedding and no keyword match.
struct SearchEngine: Sendable {
    var resultLimit: Int

    init(resultLimit: Int = 20) {
        self.resultLimit = resultLimit
    }

    func rank(queryEmbedding: [Float], items: [IndexedItem]) -> [SearchResult] {
        Self.rank(queryEmbedding: queryEmbedding, items: items, limit: resultLimit)
    }

    func rank(query: String, queryEmbedding: [Float], items: [IndexedItem]) -> [SearchResult] {
        Self.rank(query: query, queryEmbedding: queryEmbedding, items: items, limit: resultLimit)
    }

    static func rank(queryEmbedding: [Float], items: [IndexedItem], limit: Int) -> [SearchResult] {
        guard limit > 0, !queryEmbedding.isEmpty else { return [] }

        var hits: [SearchResult] = []
        hits.reserveCapacity(min(items.count, limit))
        for item in items {
            guard let embedding = item.embedding, embedding.count == queryEmbedding.count else {
                continue
            }
            let score = cosineSimilarity(queryEmbedding, embedding)
            guard score.isFinite else { continue }
            hits.append(SearchResult(item: item, score: score))
        }

        hits.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.item.relativePath < rhs.item.relativePath
        }
        if hits.count > limit {
            hits.removeSubrange(limit...)
        }
        return hits
    }

    /// Hybrid rank. An empty `queryEmbedding` contributes semantic 0 for every item
    /// and still returns keyword matches, instead of returning nothing.
    static func rank(
        query: String,
        queryEmbedding: [Float],
        items: [IndexedItem],
        limit: Int
    ) -> [SearchResult] {
        guard limit > 0 else { return [] }

        let foldedQuery = fold(query).trimmingCharacters(in: .whitespacesAndNewlines)
        let terms = queryTerms(foldedQuery)
        let wantPhrase = terms.count >= 2 && !foldedQuery.isEmpty

        var hits: [SearchResult] = []
        hits.reserveCapacity(min(items.count, limit))
        for item in items {
            let foldedTitle = fold(item.title)
            let haystack = fold(item.title + " " + item.relativePath + " " + item.bodyText)
            let words = tokens(in: haystack)

            var matched = 0
            for term in terms where words.contains(term) {
                matched += 1
            }

            let hasEmbedding = item.embedding?.isEmpty == false
            let semantic: Float
            if hasEmbedding,
               !queryEmbedding.isEmpty,
               let embedding = item.embedding,
               embedding.count == queryEmbedding.count {
                let cosine = cosineSimilarity(queryEmbedding, embedding)
                semantic = cosine.isFinite ? cosine : 0
            } else {
                semantic = 0
            }
            if !hasEmbedding && matched == 0 { continue }

            let keywordFraction: Float = terms.isEmpty ? 0 : Float(matched) / Float(terms.count)
            let phraseBonus: Float = (wantPhrase && haystack.contains(foldedQuery)) ? phraseWeight : 0
            let titleWords = tokens(in: foldedTitle)
            let titleBonus: Float = terms.contains(where: { titleWords.contains($0) }) ? titleWeight : 0
            let final = semantic + (keywordWeight * keywordFraction) + phraseBonus + titleBonus
            guard final.isFinite else { continue }
            // Rank on the raw score; clamp only for the "% match" label.
            hits.append(SearchResult(item: item, score: final))
        }

        hits.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.item.relativePath < rhs.item.relativePath
        }
        if hits.count > limit {
            hits.removeSubrange(limit...)
        }
        return hits.map { SearchResult(item: $0.item, score: min($0.score, Float(1))) }
    }

    /// Cosine similarity. Returns 0 when the vectors differ in length, are empty, or have zero magnitude.
    static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }

        var dot: Float = 0
        var magL: Float = 0
        var magR: Float = 0
        for index in 0..<lhs.count {
            let l = lhs[index]
            let r = rhs[index]
            dot += l * r
            magL += l * l
            magR += r * r
        }
        guard magL > 0, magR > 0 else { return 0 }
        return dot / (magL * magR).squareRoot()
    }

    private static let keywordWeight: Float = 0.45
    private static let phraseWeight: Float = 0.1
    private static let titleWeight: Float = 0.05
    private static let foldLocale = Locale(identifier: "en_US_POSIX")
    private static let stopwords: Set<String> = [
        "a", "an", "the", "and", "or", "of", "to", "in", "on", "for",
        "with", "at", "by", "is", "it", "my", "me", "i", "from", "about",
        "that", "this",
    ]

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: foldLocale)
            .lowercased(with: foldLocale)
    }

    private static func isAlphanumeric(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    private static func tokens(in folded: String) -> Set<String> {
        Set(folded.split(whereSeparator: { !isAlphanumeric($0) }).map(String.init))
    }

    /// `folded` is already lowercased and diacritic-folded.
    private static func queryTerms(_ folded: String) -> [String] {
        let parts = folded.split(whereSeparator: { !isAlphanumeric($0) }).map(String.init)
        let kept = parts.filter { $0.count >= 2 && !stopwords.contains($0) }
        if !kept.isEmpty { return kept }
        return parts.filter { $0.count >= 1 }
    }
}
