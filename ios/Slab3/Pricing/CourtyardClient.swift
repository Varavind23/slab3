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
        /// Courtyard's listing headline, e.g. "2021 Celebrations - Classic
        /// Collection #4 Charizard - Base Set Holo (PSA 10 GEM MINT)". Display
        /// only — `name` is the short one that feeds card_key.
        let title: String?
        let set: String?
        let year: Int?
        let grade: String?
        let cardNumber: String?
        /// Courtyard's own render of the graded card, keyed by cert
        /// (.../graded-cards-renders/PSA%2098881872/nft_image.jpg), plus a
        /// ~90-byte inline preview that can be shown before the fetch lands.
        let imageUrl: URL?
        let lqipBase64: String?
    }
    enum Confidence { case exact, probable, fuzzy }

    /// Why a lookup produced no price. `notListed` (the search worked, Courtyard
    /// has nothing for this card) and `failed` (offline, Algolia error, bad
    /// response) used to both come back as `nil`, so the caller cleared a good
    /// price whenever the network hiccuped. They are separate answers now.
    enum Outcome {
        case match(Match)
        case notListed
        case failed
    }

    /// Look up a card's Courtyard price. Tries the strongest query we have
    /// (name + set) and falls back to the cert number, because the index is
    /// `recently_listed`: a card that matched by name last week can drop out of
    /// it, while the exact vaulted slab still resolves by cert.
    func lookup(grader: Grader, certNumber: String, name: String?, set: String?, grade: String?) async -> Outcome {
        let named = [name, set].compactMap { $0 }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        // Deduped, in priority order: identity first, cert as the fallback.
        let queries = named.isEmpty ? [certNumber] : [named, certNumber]

        var sawFailure = false
        for query in queries {
            do {
                let result = try await search(query: query, grader: grader)
                if let match = bestMatch(in: result.hits, certNumber: certNumber, grade: grade) {
                    return .match(match)
                }
            } catch {
                sawFailure = true
            }
        }
        // Every query that ran came back empty → Courtyard genuinely has nothing.
        // If any of them errored, we don't actually know that.
        return sawFailure ? .failed : .notListed
    }

    /// Pick the best hit that actually carries a price. Ranking a priceless hit
    /// first used to sink the whole lookup even when a good hit sat behind it.
    private func bestMatch(in hits: [Hit], certNumber: String, grade: String?) -> Match? {
        let priced = hits.filter { Self.usd($0) != nil }
        guard !priced.isEmpty else { return nil }

        let gnum = Self.gradeNumber(grade)
        let byCert = priced.first { $0.certification?.number == certNumber }
        let byGrade = gnum == nil ? nil : priced.first {
            Self.gradeNumber($0.certification?.grade ?? $0.metadata?.values["Grade"]) == gnum
        }
        let hit = byCert ?? byGrade ?? priced[0]
        let confidence: Confidence = byCert != nil ? .exact : byGrade != nil ? .probable : .fuzzy
        guard let usd = Self.usd(hit) else { return nil }

        let meta = hit.metadata?.values ?? [:]
        return Match(
            priceCents: Int((usd * 100).rounded()),
            objectID: hit.objectID,
            confidence: confidence,
            name: Self.shortName(in: meta),
            title: hit.title,
            set: meta["Set"],
            year: meta["Year"].flatMap { Int($0) },
            grade: hit.certification?.grade ?? meta["Grade"],
            cardNumber: meta["Card Number"],
            imageUrl: hit.imageUrl.flatMap(URL.init(string:)),
            lqipBase64: hit.lqipBase64
        )
    }

    /// The card's short name out of Courtyard's metadata.
    ///
    /// The key is CATEGORY-dependent: Pokémon records use `Title/PKMN`, others
    /// `Title/Subject`. This used to read only `"Title/Subject"` and fall back to
    /// the listing headline, so for Pokémon — the app's main category — it always
    /// took the long headline instead, which then fed `card_key` through `name`.
    /// Matching the prefix is what actually finds it. Sorted for determinism;
    /// real records carry exactly one `Title/` key.
    static func shortName(in meta: [String: String]) -> String? {
        meta.keys.sorted().first { $0.hasPrefix("Title/") }.flatMap { meta[$0] }
    }

    private static func usd(_ hit: Hit) -> Double? {
        hit.estimatedValueUsd ?? hit.latestListing?.price?.amount?.usd
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
        req.timeoutInterval = 12
        let (data, response) = try await URLSession.shared.data(for: req)
        // A 4xx/5xx from Algolia is a failure, not "no results" — decoding it
        // would otherwise throw and read the same as an empty index.
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
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
    let imageUrl: String?
    let lqipBase64: String?
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
