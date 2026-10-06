import Foundation
import SwiftData

struct PsaClient {
    struct Cert: Decodable {
        let subject: String?
        let set: String?
        let year: Int?
        let grade: String?
        /// PSA's assembled heading, e.g. "2000 POKEMON ROCKET #12 DARK
        /// SLOWBRO-HOLO" — parsed from the cert page <h1>, which is the only
        /// place it exists.
        let title: String?
        let cardNumber: String?
        /// Present ONLY for certs with SecureScan imagery, which is a minority;
        /// most PSA cert pages carry no picture of the card at all. This is why
        /// PSA cannot be the app's image source on its own.
        let imageUrl: URL?
    }

    enum Outcome {
        case found(Cert)
        case notFound
        case unavailable
    }

    func lookup(certNumber: String) async -> Outcome {
        struct Body: Encodable { let certNumber: String }
        struct Reply: Decodable {
            let status: String
            let subject: String?
            let set: String?
            let year: Int?
            let grade: String?
            let title: String?
            let cardNumber: String?
            let imageUrl: URL?
        }
        do {
            let reply: Reply = try await Backend.client.functions.invoke(
                "psa-cert",
                options: .init(body: Body(certNumber: certNumber))
            )
            switch reply.status {
            case "ok":
                return .found(.init(
                    subject: reply.subject, set: reply.set, year: reply.year, grade: reply.grade,
                    title: reply.title, cardNumber: reply.cardNumber, imageUrl: reply.imageUrl
                ))
            case "not_found": return .notFound
            default: return .unavailable
            }
        } catch {
            return .unavailable
        }
    }
}

enum PsaDisplayName {
    private static let preserved = Set(["EX", "GX", "V", "VMAX", "VSTAR", "LV.X"])

    static func format(_ raw: String) -> String {
        let words = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ").map(String.init)
        return words.enumerated().map { index, word in
            let upper = word.uppercased()
            if index == 0 && upper == "M" { return "Mega" }
            if preserved.contains(upper) { return upper }
            return word.lowercased().split(separator: "-", omittingEmptySubsequences: false)
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }.joined(separator: " ")
    }
}

@MainActor
enum PsaIdentityService {
    private static let client = PsaClient()

    static func enrich(_ card: Card) async {
        guard card.grader == .psa else { return }
        let answer = await client.lookup(certNumber: card.certNumber)
        // Up to a minute later: the card may have been deleted meanwhile.
        guard PriceService.isAlive(card) else { return }
        switch answer {
        case .found(let cert):
            card.setIdentity(
                name: cert.subject.map(PsaDisplayName.format),
                title: cert.title.map(PsaDisplayName.format),
                set: cert.set,
                year: cert.year,
                grade: GradeText.normalized(cert.grade),
                cardNumber: cert.cardNumber,
                from: .psa
            )
            if card.name == nil, card.title == nil { card.lookupStatus = .needsConfirm }

            // Preserve whatever picture the card already has unless an official
            // PSA image actually downloads and decodes.
            if let url = cert.imageUrl,
               let (data, response) = try? await URLSession.shared.data(from: url),
               (response as? HTTPURLResponse)?.statusCode == 200,
               !data.isEmpty, PriceService.isAlive(card) {
                card.setImage(data, url: url, from: .psa)
            }
        case .notFound:
            // Only while nothing else has named the card: a PSA miss must not
            // turn a card CL or Courtyard already identified into "not found".
            if card.lookupStatus == .pending { card.lookupStatus = .notFound }
        case .unavailable:
            // Say so. This used to `break`, so a blocked or down source was
            // indistinguishable from one still loading — which is exactly how a
            // PSA-side change went unnoticed until someone asked why no card
            // ever got a name.
            if card.lookupStatus == .pending { card.lookupStatus = .unavailable }
        }
    }
}
