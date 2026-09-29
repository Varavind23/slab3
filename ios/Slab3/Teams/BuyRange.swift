import Foundation

/// A buy range — the lead's rule for which cards a lot will take (owner spec,
/// 2026-09-25; plan §4d). It IS the lot's bucket: there is no band/bucket
/// hierarchy and no rule inheritance. Mirrors `buy_range_templates` /
/// `lot_buy_ranges` in supabase/migrations/20260925000000_teams_lots.sql, and the
/// matching rules here must read the same way the SQL enforces them:
///
///   • value is CL Value, in integer cents; min inclusive, max EXCLUSIVE — so
///     "$0–$100" and "$100–$240" never both claim a $100 card;
///   • grade is grader-agnostic, 1–10, halves allowed; always bounded;
///   • CL confidence (1–5) and year are optional on either side (nil = no limit);
///   • max cards AND a dollar budget are both required — full when either is hit.
struct BuyRange: Identifiable, Equatable, Codable {
    var id: UUID
    var name: String
    var valueMinCents: Int64
    var valueMaxCents: Int64?
    var gradeMin: Double
    var gradeMax: Double
    var clConfMin: Int?
    var clConfMax: Int?
    var yearMin: Int?
    var yearMax: Int?
    var maxCards: Int
    var budgetCents: Int64
    var notes: String?
    /// Lot copies only: where it came from in the library, and its place in the lot.
    var templateId: UUID? = nil
    var sortOrder: Int? = nil
    /// Lot copies only: the band (price group on the lot dashboard) this bucket sits in.
    /// nil is a bucket that stands as its own band.
    var bandId: UUID? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, notes, bandId = "band_id"
        case valueMinCents = "value_min_cents", valueMaxCents = "value_max_cents"
        case gradeMin = "grade_min", gradeMax = "grade_max"
        case clConfMin = "cl_conf_min", clConfMax = "cl_conf_max"
        case yearMin = "year_min", yearMax = "year_max"
        case maxCards = "max_cards", budgetCents = "budget_cents"
        case templateId = "template_id", sortOrder = "sort_order"
    }

    /// The criteria a lot copy or a library save writes — every column the lead
    /// edits, and nothing the server owns.
    var fields: BuyRangeFields {
        BuyRangeFields(name: name, valueMinCents: valueMinCents, valueMaxCents: valueMaxCents,
                       gradeMin: gradeMin, gradeMax: gradeMax, clConfMin: clConfMin, clConfMax: clConfMax,
                       yearMin: yearMin, yearMax: yearMax, maxCards: maxCards,
                       budgetCents: budgetCents, notes: notes)
    }
}

/// The editable columns of a range, encodable straight into an insert/update.
/// Optionals encode as JSON null, which is what clears a bound on update.
struct BuyRangeFields: Equatable, Encodable {
    var name: String
    var valueMinCents: Int64
    var valueMaxCents: Int64?
    var gradeMin: Double
    var gradeMax: Double
    var clConfMin: Int?
    var clConfMax: Int?
    var yearMin: Int?
    var yearMax: Int?
    var maxCards: Int
    var budgetCents: Int64
    var notes: String?

    enum CodingKeys: String, CodingKey {
        case name, notes
        case valueMinCents = "value_min_cents", valueMaxCents = "value_max_cents"
        case gradeMin = "grade_min", gradeMax = "grade_max"
        case clConfMin = "cl_conf_min", clConfMax = "cl_conf_max"
        case yearMin = "year_min", yearMax = "year_max"
        case maxCards = "max_cards", budgetCents = "budget_cents"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(valueMinCents, forKey: .valueMinCents)
        try c.encode(valueMaxCents, forKey: .valueMaxCents)
        try c.encode(gradeMin, forKey: .gradeMin)
        try c.encode(gradeMax, forKey: .gradeMax)
        try c.encode(clConfMin, forKey: .clConfMin)
        try c.encode(clConfMax, forKey: .clConfMax)
        try c.encode(yearMin, forKey: .yearMin)
        try c.encode(yearMax, forKey: .yearMax)
        try c.encode(maxCards, forKey: .maxCards)
        try c.encode(budgetCents, forKey: .budgetCents)
        try c.encode(notes, forKey: .notes)
    }
}

// MARK: - How a range reads on screen

extension BuyRange {
    /// `$0 – $100`, `$240+`. Whole dollars when the bound is whole, because that is
    /// how every lead writes a range.
    var valueLabel: String { BuyRangeText.value(min: valueMinCents, max: valueMaxCents) }

    /// The criteria line under a range's name, in the Caliper label voice:
    /// `GRADE 7–10 · CONF 4+ · 1999–2026`. Grade is always there (every range bounds
    /// it); confidence and year only when the lead set them.
    var criteriaLine: String {
        BuyRangeText.criteria(gradeMin: gradeMin, gradeMax: gradeMax, confMin: clConfMin, confMax: clConfMax,
                              yearMin: yearMin, yearMax: yearMax)
    }

    /// `400 cards · $45,100`
    var capsLine: String { "\(maxCards) cards · \(Money.dollars(budgetCents))" }
}

enum BuyRangeText {
    static func value(min: Int64, max: Int64?) -> String {
        guard let max else { return "\(Money.dollars(min))+" }
        return "\(Money.dollars(min)) – \(Money.dollars(max))"
    }

    static func criteria(gradeMin: Double, gradeMax: Double, confMin: Int?, confMax: Int?,
                         yearMin: Int?, yearMax: Int?) -> String {
        var parts = ["GRADE " + span(grade(gradeMin), grade(gradeMax), same: gradeMin == gradeMax)]
        if let s = bounded(confMin.map(String.init), confMax.map(String.init)) { parts.append("CONF " + s) }
        if let s = bounded(yearMin.map(String.init), yearMax.map(String.init)) { parts.append(s) }
        return parts.joined(separator: " · ")
    }

    static func grade(_ g: Double) -> String {
        g.rounded() == g ? String(Int(g)) : String(format: "%.1f", g)
    }

    private static func span(_ a: String, _ b: String, same: Bool) -> String { same ? a : "\(a)–\(b)" }

    private static func bounded(_ lo: String?, _ hi: String?) -> String? {
        switch (lo, hi) {
        case let (lo?, hi?): return lo == hi ? lo : "\(lo)–\(hi)"
        case let (lo?, nil): return "\(lo)+"
        case let (nil, hi?): return "≤\(hi)"
        case (nil, nil): return nil
        }
    }
}

// MARK: - Money in, money out — integer cents, never a float

enum Money {
    /// Parse what a lead types into a dollar field. `45,100`, `$45,100.50`, `99.9`
    /// → cents. Decimal all the way: a Double would turn $0.29 into 28 cents.
    /// nil for anything that is not a non-negative amount with at most two places.
    static func cents(fromDollars typed: String) -> Int64? {
        let cleaned = typed.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
        guard !cleaned.isEmpty,
              cleaned.range(of: #"^\d+(\.\d{1,2})?$"#, options: .regularExpression) != nil,
              let value = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX"))
        else { return nil }
        var scaled = value * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        return Int64(truncating: rounded as NSDecimalNumber)
    }

    /// `$45,100` for whole dollars, `$45,100.50` otherwise.
    static func dollars(_ cents: Int64) -> String {
        let whole = cents / 100, frac = cents % 100
        let grouped = whole.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
        return frac == 0 ? "$\(grouped)" : "$\(grouped).\(String(format: "%02lld", frac))"
    }

    /// The inverse, for putting a stored bound back into an edit field.
    static func field(_ cents: Int64?) -> String {
        guard let cents else { return "" }
        return cents % 100 == 0 ? String(cents / 100) : String(format: "%lld.%02lld", cents / 100, cents % 100)
    }
}

// MARK: - The editor's draft, and what the server would refuse

/// Exactly what the range editor holds — strings, because that is what fields
/// hold — and the rules the migration's CHECK constraints enforce, run BEFORE the
/// request so the lead sees which field is wrong instead of a 400.
struct BuyRangeDraft: Equatable {
    var name = ""
    var valueMin = "0"
    var valueMax = ""
    var gradeMin = "1"
    var gradeMax = "10"
    var confMin = ""
    var confMax = ""
    var yearMin = ""
    var yearMax = ""
    var maxCards = ""
    var budget = ""
    var notes = ""

    init() {}

    init(_ range: BuyRange) {
        name = range.name
        valueMin = Money.field(range.valueMinCents)
        valueMax = Money.field(range.valueMaxCents)
        gradeMin = BuyRangeText.grade(range.gradeMin)
        gradeMax = BuyRangeText.grade(range.gradeMax)
        confMin = range.clConfMin.map(String.init) ?? ""
        confMax = range.clConfMax.map(String.init) ?? ""
        yearMin = range.yearMin.map(String.init) ?? ""
        yearMax = range.yearMax.map(String.init) ?? ""
        maxCards = String(range.maxCards)
        budget = Money.field(range.budgetCents)
        notes = range.notes ?? ""
    }

    enum Field: Hashable { case name, value, grade, confidence, year, maxCards, budget }

    enum Validation: Equatable {
        case valid(BuyRangeFields)
        /// Which fields are wrong and why (first problem per field).
        case invalid([Field: String])

        var fields: BuyRangeFields? { if case let .valid(f) = self { return f }; return nil }
        var issues: [Field: String] { if case let .invalid(i) = self { return i }; return [:] }
    }

    func validated() -> Validation {
        var issues: [Field: String] = [:]
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty { issues[.name] = "Name the range." }

        let vMin = valueMin.trimmingCharacters(in: .whitespaces).isEmpty ? 0 : Money.cents(fromDollars: valueMin)
        let vMax = optionalCents(valueMax)
        if vMin == nil || vMax == .invalid { issues[.value] = "Enter dollar amounts." }
        else if case let .value(max?) = vMax, let vMin, max <= vMin { issues[.value] = "Max must be above min." }

        let gMin = Double(gradeMin.trimmingCharacters(in: .whitespaces))
        let gMax = Double(gradeMax.trimmingCharacters(in: .whitespaces))
        if let gMin, let gMax, isGrade(gMin), isGrade(gMax) {
            if gMax < gMin { issues[.grade] = "Max grade is below min." }
        } else { issues[.grade] = "Grades run 1 to 10, halves allowed." }

        let cMin = optionalInt(confMin), cMax = optionalInt(confMax)
        if cMin == .invalid || cMax == .invalid || !inRange(cMin, 1...5) || !inRange(cMax, 1...5) {
            issues[.confidence] = "Card Ladder confidence runs 1 to 5."
        } else if case let (.value(lo?), .value(hi?)) = (cMin, cMax), hi < lo {
            issues[.confidence] = "Max is below min."
        }

        let yMin = optionalInt(yearMin), yMax = optionalInt(yearMax)
        if yMin == .invalid || yMax == .invalid || !inRange(yMin, 1900...2100) || !inRange(yMax, 1900...2100) {
            issues[.year] = "Enter four-digit years."
        } else if case let (.value(lo?), .value(hi?)) = (yMin, yMax), hi < lo {
            issues[.year] = "Max year is before min."
        }

        let cards = Int(maxCards.trimmingCharacters(in: .whitespaces))
        if cards == nil || cards! <= 0 { issues[.maxCards] = "Set how many cards this range takes." }
        let budgetCents = Money.cents(fromDollars: budget)
        if budgetCents == nil || budgetCents! <= 0 { issues[.budget] = "Set the dollar budget." }

        guard issues.isEmpty, let vMin, let gMin, let gMax, let cards, let budgetCents,
              case let .value(vMaxValue) = vMax,
              case let .value(cMinV) = cMin, case let .value(cMaxV) = cMax,
              case let .value(yMinV) = yMin, case let .value(yMaxV) = yMax
        else { return .invalid(issues) }

        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return .valid(BuyRangeFields(
            name: trimmedName, valueMinCents: vMin, valueMaxCents: vMaxValue,
            gradeMin: gMin, gradeMax: gMax, clConfMin: cMinV, clConfMax: cMaxV,
            yearMin: yMinV, yearMax: yMaxV, maxCards: cards, budgetCents: budgetCents,
            notes: trimmedNotes.isEmpty ? nil : trimmedNotes))
    }

    private enum Parsed<T: Equatable>: Equatable { case value(T?), invalid }

    private func optionalCents(_ s: String) -> Parsed<Int64> {
        if s.trimmingCharacters(in: .whitespaces).isEmpty { return .value(nil) }
        return Money.cents(fromDollars: s).map { .value($0) } ?? .invalid
    }

    private func optionalInt(_ s: String) -> Parsed<Int> {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return .value(nil) }
        return Int(t).map { .value($0) } ?? .invalid
    }

    private func inRange(_ p: Parsed<Int>, _ r: ClosedRange<Int>) -> Bool {
        if case let .value(v?) = p { return r.contains(v) }
        return true
    }

    private func isGrade(_ g: Double) -> Bool { (1...10).contains(g) && (g * 2).rounded() == g * 2 }
}
