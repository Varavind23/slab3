import Foundation

/// How lots read. Deadlines render in LOCAL time — a card show is somewhere, and
/// the lead set the deadline in their own clock.
enum LotText {
    static func statusTitle(_ status: LotStatus) -> String {
        switch status {
        case .active: "Open"
        case .draft: "Drafts · only leads see these"
        case .closed: "Closed"
        }
    }

    static func statusLine(_ lot: Lot) -> String {
        switch lot.status {
        case .draft: "Draft · buyers can't see it yet"
        case .active: "Open · buyers are filing into it"
        case .closed: "Closed · takes no more cards"
        }
    }

    /// `Due Sep 26 · 17:00 · 3 ranges`
    static func summary(_ lot: Lot, rangeCount: Int) -> String {
        var parts: [String] = []
        if let d = lot.deadline { parts.append("Due " + deadline(d)) }
        parts.append(rangeCount == 1 ? "1 range" : "\(rangeCount) ranges")
        return parts.joined(separator: " · ")
    }

    static func deadline(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day()) + " · "
            + date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    /// Five o'clock, three days out — somewhere plausible to start the picker.
    static func defaultDeadline(from now: Date = Date()) -> Date {
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: 3, to: now) ?? now
        return cal.date(bySettingHour: 17, minute: 0, second: 0, of: day) ?? day
    }
}
