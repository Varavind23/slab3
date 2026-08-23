import SwiftUI
import SwiftData

@main
struct Slab3App: App {
    @State private var auth = AuthManager()
    @State private var showSplash = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView(auth: auth)
                    .task { await auth.start() }
                if showSplash {
                    SplashView().transition(.opacity)
                }
            }
            .task {
                try? await Task.sleep(for: .seconds(1.1))
                withAnimation(.easeOut(duration: 0.35)) { showSplash = false }
            }
            .modifier(AppearanceModifier())
        }
        .modelContainer(for: [Card.self, Folder.self])
    }
}

struct RootView: View {
    let auth: AuthManager

    var body: some View {
        switch auth.state {
        case .loading:
            ZStack { Palette.bg.ignoresSafeArea() }
        case .signedOut:
            AuthScreen(auth: auth)
        case .signedIn:
            MainTabs(auth: auth)
        }
    }
}

/// design.md §5: three tabs — Home, Scanner, Folders. Settings is NOT a tab —
/// it's a hamburger, top-right, revealed from within the tabs.
struct MainTabs: View {
    let auth: AuthManager

    var body: some View {
        TabView {
            HomeScreen(auth: auth)
                .tabItem { Label("Home", systemImage: "house") }
            ScanScreen()
                .tabItem { Label("Scanner", systemImage: "barcode.viewfinder") }
            FoldersScreen(auth: auth)
                .tabItem { Label("Folders", systemImage: "folder") }
        }
        .tint(Palette.textPrimary) // no accent color — selected tab is just primary ink
    }
}
