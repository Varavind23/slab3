import Foundation

/// Queries Courtyard's Algolia search directly (public search key, no server,
/// no Cloudflare — see spike/README.md §2 and worker/src/sources/courtyard-algolia).
/// Mirrors the worker adapter so client and server agree.
///
/// Records carry both a price (estimatedValueUsd) and card metadata, so a match
/// yields the Courtyard price AND enough to auto-fill name/set/grade/year.
struct CourtyardClient {
    private static let app = "Y8TL3M06QA"
    private static let key = "3b3ed18284ca0baee9a496aea5f093d6" // public search-only
    private static let index = "marketplace_prod_recently_listed"

    struct Match {
        let priceCents: Int
        let objectID: String
        let confidence: Confidence
        // Metadata for auto-fill (present when Courtyard has the card).
        let name: String?
        let set: String?
        let year: Int?
        let grade: String?
    }
    enum Confidence { case exact, probable, fuzzy }

    /// Look up a card's Courtyard price. Uses name+set when known, else the cert
    /// number (finds the exact slab if it's vaulted on Courtyard).
    func lookup(grader: Grader, certNumber: String, name: String?, set: String?, grade: String?) async -> Match? {
        let queryText = [name, set].compactMap { $0 }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let query = queryText.isEmpty ? certNumber : queryText
        guard let result = try? await search(query: query, grader: grader) else { return nil }
        guard !result.hits.isEmpty else { return nil }

        let gnum = Self.gradeNumber(grade)
        let byCert = result.hits.first { $0.certification?.number == certNumber }
        let byGrade = gnum == nil ? nil : result.hits.first {
            Self.gradeNumber($0.certification?.grade ?? $0.metadata?.values["Grade"]) == gnum
        }
        let hit = byCert ?? byGrade ?? result.hits[0]
        let confidence: Confidence = byCert != nil ? .exact : byGrade != nil ? .probable : .fuzzy

        let usd = hit.estimatedValueUsd ?? hit.latestListing?.price?.amount?.usd
        guard let usd else { return nil }

        let meta = hit.metadata?.values ?? [:]
        return Match(
            priceCents: Int((usd * 100).rounded()),
            objectID: hit.objectID,
            confidence: confidence,
            name: meta["Title/Subject"] ?? hit.title,
            set: meta["Set"],
            year: meta["Year"].flatMap { Int($0) },
            grade: hit.certification?.grade ?? meta["Grade"]
        )
    }

    // MARK: Algolia request

    private func search(query: String, grader: Grader) async throws -> AlgoliaResult {
        var req = URLRequest(url: URL(string: "https://\(Self.app.lowercased())-dsn.algolia.net/1/indexes/\(Self.index)/query")!)
        req.httpMethod = "POST"
        req.setValue(Self.app, forHTTPHeaderField: "X-Algolia-Application-Id")
        req.setValue(Self.key, forHTTPHeaderField: "X-Algolia-API-Key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "query": query,
            "hitsPerPage": 10,
            "facetFilters": [["metadata.Grader:\(grader.rawValue.uppercased())"]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(AlgoliaResult.self, from: data)
    }

    /// "10 GEM MINT" / "PSA 9" / "9.5" → "10" / "9" / "9.5". Leading number only.
    static func gradeNumber(_ grade: String?) -> String? {
        guard let grade else { return nil }
        var out = ""
        for ch in grade {
            if ch.isNumber || (ch == "." && !out.isEmpty) {
                out.append(ch)
            } else if !out.isEmpty {
                break
            }
        }
        return out.isEmpty ? nil : out
    }
}

// MARK: - Algolia response models

private struct AlgoliaResult: Decodable {
    let hits: [Hit]
}
private struct Hit: Decodable {
    let objectID: String
    let title: String?
    let estimatedValueUsd: Double?
    let certification: Cert?
    let metadata: LenientStringDict?
    let latestListing: Listing?
}

/// Decodes an object keeping only its string-valued entries (Algolia metadata is
/// string-valued in practice, but this never throws on an unexpected type).
private struct LenientStringDict: Decodable {
    let values: [String: String]
    private struct Key: CodingKey {
        var stringValue: String; init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }; init?(intValue: Int) { nil }
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        var out: [String: String] = [:]
        for k in c.allKeys { if let s = try? c.decode(String.self, forKey: k) { out[k.stringValue] = s } }
        values = out
    }
}
private struct Cert: Decodable {
    let number: String?
    let grade: String?
}
private struct Listing: Decodable {
    let price: PriceBox?
}
private struct PriceBox: Decodable {
    let amount: AmountBox?
}
private struct AmountBox: Decodable {
    let usd: Double?
}
