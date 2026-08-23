import SwiftUI
import SwiftData

@main
struct Slab3App: App {
    @State private var auth = AuthManager()

    var body: some Scene {
        WindowGroup {
            RootView(auth: auth)
                .task { await auth.start() }
        }
        .modelContainer(for: Card.self)
    }
}

struct RootView: View {
    let auth: AuthManager

    var body: some View {
        switch auth.state {
        case .loading:
            ProgressView()
        case .signedOut:
            AuthScreen(auth: auth)
        case .signedIn:
            MainTabs(auth: auth)
        }
    }
}

struct MainTabs: View {
    let auth: AuthManager

    var body: some View {
        TabView {
            ScanScreen()
                .tabItem { Label("Scan", systemImage: "barcode.viewfinder") }
            InventoryScreen()
                .tabItem { Label("Inventory", systemImage: "square.stack.3d.up") }
            SettingsScreen(auth: auth)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

struct SettingsScreen: View {
    let auth: AuthManager

    var body: some View {
        NavigationStack {
            Form {
                if case let .signedIn(_, email) = auth.state {
                    Section("Account") {
                        LabeledContent("Signed in as", value: email ?? "—")
                    }
                }
                Section {
                    Button("Sign out", role: .destructive) {
                        Task { await auth.signOut() }
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
