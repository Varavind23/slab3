import SwiftUI
import SwiftData

/// One card's detail. For v1 foundation this shows identity + lets the sourcer
/// confirm/enter card data (the CGC degraded path) and a manual price. Live
/// cert lookup and Card Ladder/Courtyard prices wire in here next.
struct CardDetailScreen: View {
    @Bindable var card: Card
    @Environment(\.modelContext) private var context

    var body: some View {
        Form {
            Section("Identity") {
                LabeledContent("Grader", value: card.grader.rawValue.uppercased())
                LabeledContent("Cert", value: card.certNumber)
                LabeledContent("Status", value: card.lookupStatus.rawValue)
            }

            Section("Card details") {
                TextField("Name / subject", text: bind(\.name))
                TextField("Set", text: bind(\.set))
                TextField("Grade", text: bind(\.grade))
                TextField("Year", value: $card.year, format: .number)
                    .keyboardType(.numberPad)
            }

            Section("Price") {
                LabeledContent("Manual price") {
                    TextField("$", value: dollars, format: .currency(code: "USD"))
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.decimalPad)
                }
                Text("Card Ladder (avg) and Courtyard (recent) prices connect here next.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Button("Save details") {
                    card.lookupStatus = .resolved
                    card.refreshCardKey()
                }
            }
        }
        .navigationTitle(card.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Bind an optional String field to a non-optional TextField.
    private func bind(_ keyPath: ReferenceWritableKeyPath<Card, String?>) -> Binding<String> {
        Binding(get: { card[keyPath: keyPath] ?? "" },
                set: { card[keyPath: keyPath] = $0.isEmpty ? nil : $0 })
    }

    /// Manual price in dollars, backed by the integer-cents field.
    private var dollars: Binding<Double?> {
        Binding(
            get: { card.manualPriceCents.map { Double($0) / 100 } },
            set: { card.manualPriceCents = $0.map { Int(($0 * 100).rounded()) } }
        )
    }
}
