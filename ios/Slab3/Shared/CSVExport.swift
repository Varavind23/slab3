import Foundation

/// Writes a folder's cards to a CSV in a temp file, returns its URL for the
/// share sheet (design.md §5: the CSV is the actual deliverable to a buyer).
enum CSVExport {
    static func write(folder: Folder) -> URL? {
        var rows = ["grader,cert,name,set,year,grade,courtyard_usd,cardladder_usd,manual_usd"]
        for c in folder.cards.sorted(by: { $0.scannedAt < $1.scannedAt }) {
            rows.append([
                c.grader.rawValue.uppercased(),
                c.certNumber,
                csv(c.name),
                csv(c.set),
                c.year.map(String.init) ?? "",
                csv(c.grade),
                dollars(c.courtyardPriceCents),
                dollars(c.cardLadderPriceCents),
                dollars(c.manualPriceCents),
            ].joined(separator: ","))
        }
        let safeName = folder.name.replacingOccurrences(of: "[^A-Za-z0-9]+", with: "-", options: .regularExpression)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeName).csv")
        do {
            try rows.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    private static func dollars(_ cents: Int?) -> String {
        guard let cents else { return "" }
        return (Double(cents) / 100).formatted(.number.precision(.fractionLength(2)))
    }

    /// Quote a field if it contains a comma/quote/newline (RFC 4180).
    private static func csv(_ v: String?) -> String {
        guard let v, !v.isEmpty else { return "" }
        if v.contains(where: { ",\"\n".contains($0) }) {
            return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return v
    }
}
