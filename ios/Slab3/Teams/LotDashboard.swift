import Foundation

/// The lot dashboard's numbers, derived and nothing else (plan §8).
///
/// Laid out like the allocation screen the team already uses daily (owner, 2026-09-25:
/// "as similar as possible so there's less of a learning curve") — so the words
/// are that screen's words: `$0 – $100`, `$20,123.87 / $86,725`, `CONF 4+ · 7+
/// CERTS`, `23% used`, `3 buckets`. Colours stay Caliper's (owner decision).
///
/// Everything a band shows is DERIVED from its buckets — its price span, its rules,
/// its allocation, its usage — so a band can never disagree with what it contains.
/// "Used" is what THIS TEAM has bought (confirmed claims, CL Value at claim time);
/// it is never mixed with what the buyer's own system reports (§8: two numbers,
/// never merged).
enum LotDashboard {
    struct Bucket: Identifiable, Equatable {
        let range: BuyRange
        let usedCents: Int64
        let cards: Int
        var id: UUID { range.id }
        var allocatedCents: Int64 { range.budgetCents }
        var valueLabel: String { range.valueLabel }
        /// `7+ certs` — the bucket's own rules, lower-case as the detail line has them.
        var ruleText: String { LotDashboard.rules([range]).lowercased() }
        var fraction: Double { LotDashboard.fraction(usedCents, of: allocatedCents) }
    }

    struct Band: Identifiable, Equatable {
        /// The band's id, or the lone bucket's id for a bucket with no band.
        let id: UUID
        let buckets: [Bucket]
        let valueMinCents: Int64
        let valueMaxCents: Int64?
        /// Only rules EVERY bucket shares; empty when they differ.
        let rules: String

        var usedCents: Int64 { buckets.reduce(0) { $0 + $1.usedCents } }
        var allocatedCents: Int64 { buckets.reduce(0) { $0 + $1.allocatedCents } }
        var cards: Int { buckets.reduce(0) { $0 + $1.cards } }
        var fraction: Double { LotDashboard.fraction(usedCents, of: allocatedCents) }
        /// Unclamped and in integer cents: an over-spent band says 111%, not 100%.
        var percentUsed: Int { allocatedCents > 0 ? Int(usedCents * 100 / allocatedCents) : 0 }
        var valueLabel: String { BuyRangeText.value(min: valueMinCents, max: valueMaxCents) }
        var bucketCountLabel: String { buckets.count == 1 ? "1 bucket" : "\(buckets.count) buckets" }
    }

    /// `SLABS · GRADE 7+` — the lowest grade any bucket in the lot takes.
    static func gradeLine(_ ranges: [BuyRange]) -> String {
        "SLABS · GRADE \(BuyRangeText.grade(ranges.map(\.gradeMin).min() ?? 1))+"
    }

    /// Bands by price. Buckets carrying the same band label (trimmed, any case)
    /// group into one band, named by its first bucket; a bucket with no label
    /// stands as a band of one (teams-first plan, D11 — the label only groups;
    /// the band's span and totals are derived here, so it can never disagree with
    /// what it contains).
    static func build(ranges: [BuyRange], usage: [UUID: RangeUsage]) -> [Band] {
        let bucket = { (r: BuyRange) in
            Bucket(range: r, usedCents: usage[r.id]?.usedCents ?? 0, cards: usage[r.id]?.cards ?? 0)
        }
        var groups: [String: [BuyRange]] = [:]
        var order: [String] = []
        var bands: [Band] = []
        for range in ranges {
            guard let label = range.band?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else {
                bands.append(band(id: range.id, [bucket(range)]))
                continue
            }
            let key = label.lowercased()
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(range)
        }
        for key in order {
            let members = (groups[key] ?? []).sorted { $0.valueMinCents < $1.valueMinCents }
            bands.append(band(id: members[0].id, members.map(bucket)))
        }
        return bands.sorted { $0.valueMinCents < $1.valueMinCents }
    }

    /// The band labels a lot already uses, first spelling of each — the range
    /// editor's one-tap suggestions.
    static func bandLabels(_ ranges: [BuyRange]) -> [String] {
        var seen: Set<String> = [], out: [String] = []
        for label in ranges.compactMap({ $0.band?.trimmingCharacters(in: .whitespacesAndNewlines) })
        where !label.isEmpty && seen.insert(label.lowercased()).inserted { out.append(label) }
        return out
    }

    private static func band(id: UUID, _ buckets: [Bucket]) -> Band {
        let mins = buckets.map(\.range.valueMinCents)
        let maxes = buckets.map(\.range.valueMaxCents)
        return Band(id: id, buckets: buckets,
                    valueMinCents: mins.min() ?? 0,
                    // Open-ended if any bucket is.
                    valueMaxCents: maxes.contains(nil) ? nil : maxes.compactMap { $0 }.max(),
                    rules: rules(buckets.map(\.range)))
    }

    /// The rule chips, in that screen's order and words: `CONF 4+ · 7+ CERTS`.
    /// Only rules every range here shares; a grade bound that is the default 1–10
    /// is not a rule and says nothing.
    static func rules(_ ranges: [BuyRange]) -> String {
        guard let first = ranges.first else { return "" }
        var parts: [String] = []
        if let conf = first.clConfMin, ranges.allSatisfy({ $0.clConfMin == conf && $0.clConfMax == first.clConfMax }) {
            parts.append(first.clConfMax.map { "CONF \(conf)–\($0)" } ?? "CONF \(conf)+")
        }
        if ranges.allSatisfy({ $0.yearMin == first.yearMin && $0.yearMax == first.yearMax }),
           first.yearMin != nil || first.yearMax != nil {
            switch (first.yearMin, first.yearMax) {
            case let (lo?, hi?): parts.append("\(lo)–\(hi)")
            case let (lo?, nil): parts.append("\(lo)+")
            case let (nil, hi?): parts.append("≤\(hi)")
            default: break
            }
        }
        if ranges.allSatisfy({ $0.gradeMin == first.gradeMin && $0.gradeMax == first.gradeMax }),
           !(first.gradeMin == 1 && first.gradeMax == 10) {
            let lo = BuyRangeText.grade(first.gradeMin), hi = BuyRangeText.grade(first.gradeMax)
            parts.append(first.gradeMax == 10 ? "\(lo)+ CERTS" : "\(lo)–\(hi) CERTS")
        }
        return parts.joined(separator: " · ")
    }

    /// Clamped 0…1 for drawing. Over-allocation still reads truthfully in the text
    /// (`$50,100 / $45,100`, `111% used`); only the bar stops at full.
    static func fraction(_ used: Int64, of allocated: Int64) -> Double {
        guard allocated > 0 else { return 0 }
        return min(1, max(0, Double(used) / Double(allocated)))
    }

    /// `$20,123.87 / $86,725`
    static func usedOfAllocated(_ used: Int64, _ allocated: Int64) -> String {
        "\(Money.dollars(used)) / \(Money.dollars(allocated))"
    }

    /// What the lot's buyer has reported accepting for a set of buckets, beside
    /// what the team bought — two numbers, never merged (teams.md §8).
    struct Reported: Equatable {
        let usedCents: Int64
        let cards: Int?
        /// The OLDEST of the reports summed — a band is only as current as its
        /// stalest bucket, and that is the date that tells the lead to re-check.
        let asOf: Date?
        /// Team-bought minus reported. Positive: bought more than accepted.
        let gapCents: Int64
        /// The gap is big enough to say out loud.
        let gapMatters: Bool
    }

    /// nil when no bucket here has a report yet. A gap matters at $50 or 2% of the
    /// allocation, whichever is larger — below that it is rounding and timing, not
    /// a rejected submission.
    static func reported(_ buckets: [Bucket], reports: [UUID: RangeReport]) -> Reported? {
        let rows = buckets.compactMap { reports[$0.id] }
        guard !rows.isEmpty else { return nil }
        let used = rows.reduce(Int64(0)) { $0 + $1.usedCents }
        let cards = rows.allSatisfy { $0.cardCount != nil } ? rows.reduce(0) { $0 + ($1.cardCount ?? 0) } : nil
        // Both sides of the gap, and its threshold, over the REPORTED buckets only —
        // a band with one bucket reported must not measure that bucket's gap against
        // the allocation of six it says nothing about.
        let reported = buckets.filter { reports[$0.id] != nil }
        let bought = reported.reduce(Int64(0)) { $0 + $1.usedCents }
        let allocated = reported.reduce(Int64(0)) { $0 + $1.allocatedCents }
        let gap = bought - used
        return Reported(usedCents: used, cards: cards, asOf: rows.compactMap(\.reportedDate).min(),
                        gapCents: gap, gapMatters: abs(gap) >= max(5_000, allocated / 50))
    }

    /// `REPORTED SEP 24 · 09:12 · $16,900 · 224 CARDS`, and `GAP $432` when it matters.
    static func reportedLine(_ r: Reported) -> String {
        var parts = ["Reported" + (r.asOf.map { " " + LotText.deadline($0) } ?? "")]
        parts.append(Money.dollars(r.usedCents))
        if let cards = r.cards { parts.append("\(cards) cards") }
        return parts.joined(separator: " · ")
    }

    /// `4d 23:17:34`; `23:17:34` inside a day; nil once the deadline has passed.
    static func countdown(to deadline: Date, now: Date) -> String? {
        let total = Int(deadline.timeIntervalSince(now))
        guard total > 0 else { return nil }
        let d = total / 86_400, h = (total % 86_400) / 3_600, m = (total % 3_600) / 60, s = total % 60
        let clock = String(format: "%02d:%02d:%02d", h, m, s)
        return d > 0 ? "\(d)d \(clock)" : clock
    }
}
