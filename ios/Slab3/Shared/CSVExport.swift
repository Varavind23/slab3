import Foundation

/// The exported columns, in the order the user picked them.
///
/// Selection order IS column order in the file — that's why the Export chips carry
/// a visible number (reference/component-rules.md § Chip). Columns whose data this
/// build doesn't have yet (outlet and payout provider) export as empty cells.
enum CSVColumn: String, CaseIterable, Identifiable, Hashable {
    case cert, name, year, cardNumber, grade, grader
    case clPrice, clConf, cyPrice, cyConf
    case outlet, payoutPercent, payoutProvider, payoutUsd
    case scannedAt, refreshedAt
    /// Our own figure, not a source's. Off by default (see `defaults`).
    case maxBuy
    /// Who bought the slab, and which of a team lot's buckets it went into. Bucket
    /// is lot-only (teams plan §7.9): offered and emitted only when Export is scoped
    /// to a lot's group. Buyer is on every export since virtual members (V3,
    /// 2026-10-04): a lot slab's claim buyer after credit, else the card's own tag,
    /// else an empty cell.
    case buyer, bucket
    /// What the user paid for the card (`Card.paidCents`). Opt-in: offered
    /// and emitted only while Settings → Track price paid is on.
    case paid

    var isLotOnly: Bool { self == .bucket }

    var id: String { rawValue }

    /// The chip's label.
    var label: String {
        switch self {
        case .cert: return "Cert"
        case .name: return "Name"
        case .year: return "Year"
        case .cardNumber: return "Card #"
        case .grade: return "Grade"
        case .grader: return "Grader"
        case .clPrice: return "CL Price"
        case .clConf: return "CL Conf"
        case .cyPrice: return "CY Price"
        case .cyConf: return "CY Conf"
        case .outlet: return "Outlet"
        case .payoutPercent: return "Payout %"
        case .payoutProvider: return "Payout provider"
        case .payoutUsd: return "Payout $"
        case .scannedAt: return "Scanned at"
        case .refreshedAt: return "Refreshed at"
        case .maxBuy: return "Max buy"
        case .buyer: return "Buyer"
        case .bucket: return "Bucket"
        case .paid: return "Paid"
        }
    }

    /// The header cell written into the file.
    var header: String {
        switch self {
        case .cert: return "cert"
        case .name: return "name"
        case .year: return "year"
        case .cardNumber: return "card_number"
        case .grade: return "grade"
        case .grader: return "grader"
        case .clPrice: return "cl_price"
        case .clConf: return "cl_conf"
        case .cyPrice: return "cy_price"
        case .cyConf: return "cy_conf"
        case .outlet: return "outlet"
        case .payoutPercent: return "payout_pct"
        case .payoutProvider: return "payout_provider"
        case .payoutUsd: return "payout_usd"
        case .scannedAt: return "scanned_at"
        case .refreshedAt: return "refreshed_at"
        case .maxBuy: return "max_buy_price"
        case .buyer: return "buyer"
        case .bucket: return "bucket"
        case .paid: return "paid_usd"
        }
    }

    /// Source-owned columns take that source's hue, in the chip grid and in the
    /// preview's header row.
    var source: PriceSource? {
        switch self {
        case .clPrice, .clConf: return .cl
        case .cyPrice, .cyConf: return .cy
        default: return nil
        }
    }

    /// What a fresh install exports until the user reorders it. Max buy is
    /// deliberately absent: the CSV is the part of this app a buyer actually sees,
    /// and a column stating the most you were willing to pay is not something to
    /// switch on for anyone by default.
    static let defaults: [CSVColumn] = [.cert, .name, .year, .grade, .grader, .clPrice, .cyPrice]

    /// The columns a build may show and emit, applied at BOTH ends — the chip grid
    /// and the file — so a lot-only column cannot ride along outside a lot, and the
    /// paid column cannot keep exporting after its Settings toggle is turned off.
    static func available(lot: Bool = false, tracksPaid: Bool = false) -> [CSVColumn] {
        allCases.filter { (!$0.isLotOnly || lot) && ($0 != .paid || tracksPaid) }
    }
}

/// Writes the current scope to a CSV in a temp file and returns its URL for the
/// share sheet — the CSV is usually the only part of this app a buyer ever sees.
enum CSVExport {

    /// A lot export's extra knowledge (teams plan §7.9). For this phone's own cards:
    /// who bought each (this user) and its bucket. For a LEAD, `teammates` adds
    /// every other slab claimed into the lot — from the server's record, frozen at
    /// claim time — so the file is the whole lot, not one phone's share of it.
    struct LotExport {
        struct Teammate {
            let claim: TeamClaim
            let buyer: String
            let bucket: String?
        }
        var buyerByCard: [UUID: String] = [:]
        var bucketByCard: [UUID: String] = [:]
        var teammates: [Teammate] = []
    }

    /// `inventory_2026-08-19.csv`, or `inventory_buyer1_2026-08-19.csv` when a group
    /// is active. The filename carries the scope because it is the only label the
    /// buyer receives with the file.
    static func filename(scope: String?, date: Date = Date()) -> String {
        let day = date.formatted(.iso8601.year().month().day().dateSeparator(.dash))
        let slug = scope.map { "_" + safe($0) } ?? ""
        return "inventory\(slug)_\(day).csv"
    }

    /// `buyers`: the Buyer cell per card (CardTagging.buyerName), on any export.
    /// `tracksPaid` is passed rather than read for the same reason as `maxBuyCents`.
    /// Off, the paid column is dropped and payout ignores any stored value.
    static func rows(_ cards: [Card], columns: [CSVColumn], payoutPercent: Double?,
                     maxBuyCents: [UUID: Int] = [:], buyers: [UUID: String] = [:],
                     lot: LotExport? = nil, tracksPaid: Bool = false) -> [String] {
        // Lot-only columns never reach a file that is not a lot export.
        var columns = lot == nil ? columns.filter { !$0.isLotOnly } : columns
        if !tracksPaid { columns.removeAll { $0 == .paid } }
        var out = [columns.map(\.header).joined(separator: ",")]
        for card in cards {
            out.append(columns.map { cell(card, $0, payoutPercent, maxBuyCents, buyers, lot, tracksPaid) }.joined(separator: ","))
        }
        for mate in lot?.teammates ?? [] {
            out.append(columns.map { cell(mate, $0, payoutPercent) }.joined(separator: ","))
        }
        return out
    }

    static func write(_ cards: [Card], columns: [CSVColumn], scope: String?, payoutPercent: Double?,
                      maxBuyCents: [UUID: Int] = [:], buyers: [UUID: String] = [:],
                      lot: LotExport? = nil, tracksPaid: Bool = false) -> URL? {
        let text = rows(cards, columns: columns, payoutPercent: payoutPercent,
                        maxBuyCents: maxBuyCents, buyers: buyers, lot: lot,
                        tracksPaid: tracksPaid).joined(separator: "\n")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename(scope: scope))
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    // MARK: Cells

    /// `maxBuyCents` is passed in rather than computed: the figure lives behind a
    /// main-actor memo, and isolating this file to reach it would isolate the whole
    /// CSV layer along with it. A card absent from the map has no max buy, which
    /// renders as an empty cell — never "0.00".
    private static func cell(_ c: Card, _ column: CSVColumn, _ payoutPercent: Double?,
                             _ maxBuyCents: [UUID: Int], _ buyers: [UUID: String], _ lot: LotExport?,
                             _ tracksPaid: Bool) -> String {
        let paid = tracksPaid ? c.paidCents : nil
        switch column {
        case .cert: return c.certNumber
        case .name: return quoted(c.name)
        case .year: return c.year.map(String.init) ?? ""
        case .cardNumber: return quoted(c.cardNumber)
        case .grade: return quoted(c.grade)
        case .grader: return c.grader.rawValue.uppercased()
        case .clPrice: return dollars(c.cardLadderPriceCents)
        case .clConf: return String(c.cardLadderConfidence)
        case .cyPrice: return dollars(c.courtyardPriceCents)
        case .cyConf: return String(c.courtyardConfidence)
        case .outlet, .payoutProvider: return "" // no data source (README open Qs 3–4)
        case .payoutPercent: return payoutPercent.map { $0.formatted(posix.precision(.fractionLength(1))) } ?? ""
        case .payoutUsd:
            // What was actually paid IS the payout; the rate only estimates it.
            if let paid { return dollars(paid) }
            guard let pct = payoutPercent, let gross = c.prices.best(preferring: .cl) else { return "" }
            return dollars(Int((Double(gross) * pct / 100).rounded()))
        case .paid: return dollars(paid)
        case .scannedAt: return iso(c.scannedAt)
        case .refreshedAt: return iso(c.lastPricedAt)
        // Empty, never "0.00", when no comps can price this card — the same rule
        // the price columns follow, and the same rule the panel follows on screen.
        case .maxBuy: return dollars(maxBuyCents[c.localId])
        case .buyer: return quoted(buyers[c.localId] ?? lot?.buyerByCard[c.localId])
        case .bucket: return quoted(lot?.bucketByCard[c.localId])
        }
    }

    /// A teammate's slab. Only what the server froze at claim time: both sources'
    /// values (Courtyard's since 0.9 — a claim from before has none) and identity.
    /// Anything the claim does not carry is EMPTY, never 0 — this phone never priced
    /// that card, and a blank is the honest cell. Before 2026-10-06 the CY columns
    /// were always blank, which left a CY lot's whole-lot file without its values.
    private static func cell(_ m: LotExport.Teammate, _ column: CSVColumn, _ payoutPercent: Double?) -> String {
        let c = m.claim
        switch column {
        case .cert: return c.cert
        case .name: return quoted(c.player ?? c.label)
        case .year: return quoted(c.cardYear)
        case .cardNumber: return quoted(c.cardNumber)
        case .grade: return quoted(c.gradeLabel)
        case .grader: return c.grader.uppercased()
        case .clPrice: return dollars(c.priceCents)
        case .clConf: return c.clConfidence.map(String.init) ?? ""
        case .cyPrice: return dollars(c.cyPriceCents)
        case .cyConf: return c.cyConfidence.map(String.init) ?? ""
        // Paid is this phone's own entry — the server holds none for a teammate.
        case .outlet, .payoutProvider, .refreshedAt, .maxBuy, .paid: return ""
        case .payoutPercent: return payoutPercent.map { $0.formatted(posix.precision(.fractionLength(1))) } ?? ""
        case .payoutUsd:
            guard let pct = payoutPercent, let gross = c.priceCents else { return "" }
            return dollars(Int((Double(gross) * pct / 100).rounded()))
        case .scannedAt: return iso(c.scannedDate)
        case .buyer: return quoted(m.buyer)
        case .bucket: return quoted(m.bucket)
        }
    }

    // MARK: Total

    /// Export's footer figure for this phone's cards: price paid where the user
    /// entered one (and the feature is on), otherwise the leading source's value.
    /// `paidCount` lets the footer say how much of the figure is real cost.
    static func total(_ cards: [Card], preferring source: PriceSource,
                      tracksPaid: Bool) -> (cents: Int, paidCount: Int) {
        var cents = 0, paidCount = 0
        for card in cards {
            if tracksPaid, let paid = card.paidCents {
                cents += paid
                paidCount += 1
            } else if let value = card.prices.best(preferring: source) {
                cents += value
            }
        }
        return (cents, paidCount)
    }

    /// A teammate's slab in Export's footer: the same rule as this phone's own cards
    /// (`PriceSet.best`) — the leading source, else whichever value the claim has.
    static func teammateValue(_ claim: TeamClaim, preferring source: PriceSource) -> Int? {
        PriceSet(cl: claim.priceCents, cy: claim.cyPriceCents).best(preferring: source)
    }

    private static func iso(_ d: Date?) -> String {
        guard let d else { return "" }
        return d.formatted(.iso8601.year().month().day().dateSeparator(.dash))
    }

    private static func dollars(_ cents: Int?) -> String {
        guard let cents else { return "" } // empty, never 0 — the card has no price
        return (Double(cents) / 100).formatted(posix.precision(.fractionLength(2)).grouping(.never))
    }

    /// Fixed "50.80" whatever the device region: a comma-decimal locale would write
    /// `50,80` unquoted and shift every later column.
    private static let posix = FloatingPointFormatStyle<Double>.number.locale(Locale(identifier: "en_US_POSIX"))

    private static func safe(_ v: String) -> String {
        v.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
    }

    /// Quote a field if it contains a comma/quote/newline (RFC 4180). A text cell
    /// that starts like a formula (`=`, `+`, `-`, `@`, tab, CR) gets a leading `'`
    /// so Excel/Sheets show it rather than run it — buyer names are typed by
    /// teammates, and the file is opened by someone else.
    private static func quoted(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        let v = raw.first.map { "=+-@\t\r".contains($0) } == true ? "'" + raw : raw
        if v.contains(where: { ",\"\n\r".contains($0) }) {
            return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return v
    }
}
