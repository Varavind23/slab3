import SwiftUI

/// Settings (design.md §5): a hamburger sheet, not a tab. Dark/light toggle and
/// account. Muted throughout.
struct SettingsSheet: View {
    let auth: AuthManager
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appearance") private var appearance = "system"

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $appearance) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .pickerStyle(.segmented)
                }
                if case let .signedIn(_, email) = auth.state {
                    Section("Account") {
                        LabeledContent("Signed in", value: email ?? "—")
                    }
                }
                Section {
                    Button("Sign out", role: .destructive) {
                        Task { await auth.signOut(); dismiss() }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.tint(Palette.textPrimary)
                }
            }
        }
    }
}

/// Applies the stored appearance preference to a view tree.
struct AppearanceModifier: ViewModifier {
    @AppStorage("appearance") private var appearance = "system"
    func body(content: Content) -> some View {
        content.preferredColorScheme(
            appearance == "light" ? .light : appearance == "dark" ? .dark : nil
        )
    }
}
