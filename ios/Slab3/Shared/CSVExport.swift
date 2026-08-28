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

    /// What a fresh install exports until the user reorders it.
    static let defaults: [CSVColumn] = [.cert, .name, .year, .grade, .grader, .clPrice, .cyPrice]
}

/// Writes the current scope to a CSV in a temp file and returns its URL for the
/// share sheet — the CSV is usually the only part of this app a buyer ever sees.
enum CSVExport {

    /// `inventory_2026-08-19.csv`, or `inventory_pete_2026-08-19.csv` when a group
    /// is active. The filename carries the scope because it is the only label the
    /// buyer receives with the file.
    static func filename(scope: String?, date: Date = Date()) -> String {
        let day = date.formatted(.iso8601.year().month().day().dateSeparator(.dash))
        let slug = scope.map { "_" + safe($0) } ?? ""
        return "inventory\(slug)_\(day).csv"
    }

    static func rows(_ cards: [Card], columns: [CSVColumn], payoutPercent: Double?) -> [String] {
        var out = [columns.map(\.header).joined(separator: ",")]
        for card in cards {
            out.append(columns.map { cell(card, $0, payoutPercent) }.joined(separator: ","))
        }
        return out
    }

    static func write(_ cards: [Card], columns: [CSVColumn], scope: String?, payoutPercent: Double?) -> URL? {
        let text = rows(cards, columns: columns, payoutPercent: payoutPercent).joined(separator: "\n")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename(scope: scope))
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    // MARK: Cells

    private static func cell(_ c: Card, _ column: CSVColumn, _ payoutPercent: Double?) -> String {
        switch column {
        case .cert: return c.certNumber
        case .name: return quoted(c.name)
        case .year: return c.year.map(String.init) ?? ""
        case .cardNumber: return quoted(c.set) // no card-number field yet; set is the closest thing we hold
        case .grade: return quoted(c.grade)
        case .grader: return c.grader.rawValue.uppercased()
        case .clPrice: return dollars(c.cardLadderPriceCents)
        case .clConf: return String(c.cardLadderConfidence)
        case .cyPrice: return dollars(c.courtyardPriceCents)
        case .cyConf: return String(c.courtyardConfidence)
        case .outlet, .payoutProvider: return "" // no data source (README open Qs 3–4)
        case .payoutPercent: return payoutPercent.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? ""
        case .payoutUsd:
            guard let pct = payoutPercent, let gross = c.prices.best(preferring: .cl) else { return "" }
            return dollars(Int((Double(gross) * pct / 100).rounded()))
        case .scannedAt: return iso(c.scannedAt)
        case .refreshedAt: return iso(c.lastPricedAt)
        }
    }

    private static func iso(_ d: Date?) -> String {
        guard let d else { return "" }
        return d.formatted(.iso8601.year().month().day().dateSeparator(.dash))
    }

    private static func dollars(_ cents: Int?) -> String {
        guard let cents else { return "" } // empty, never 0 — the card has no price
        return (Double(cents) / 100).formatted(.number.precision(.fractionLength(2)).grouping(.never))
    }

    private static func safe(_ v: String) -> String {
        v.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
    }

    /// Quote a field if it contains a comma/quote/newline (RFC 4180).
    private static func quoted(_ v: String?) -> String {
        guard let v, !v.isEmpty else { return "" }
        if v.contains(where: { ",\"\n".contains($0) }) {
            return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return v
    }
}
